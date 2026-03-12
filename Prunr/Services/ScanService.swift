import Foundation
import OSLog

/// Actor that orchestrates file scanning and stores results in the database
///
/// Provides a single entry point for scanning operations with batch transaction
/// inserts for high-performance storage (2000 items per batch).
actor ScanService {

    // MARK: - Properties

    /// Shared singleton instance
    static let shared = ScanService()

    /// The file scanner actor
    private let scanner = FileScanner()

    /// Database manager reference
    private let db = DatabaseManager.shared

    /// Tracks whether a scan is currently in progress.
    /// This is the single source of truth for scan state.
    @MainActor var isScanning = false

    /// Cancellation token for stopping in-progress scans
    private var isCancelled = false

    /// Task handle for the current scan (allows immediate cancellation)
    private var currentScanTask: Task<Void, Never>?

    /// Logger for scan operations
    private let logger = Logger(subsystem: "com.prunr.ScanService", category: "Scanning")

    private init() {}

    /// Cancels the current scan operation
    func cancelScan() {
        logger.info("Cancellation requested")
        self.isCancelled = true

        // Also cancel the task if we have a handle to it
        self.currentScanTask?.cancel()

        logger.info("Cancellation signal sent (isCancelled: \(self.isCancelled))")
    }

    /// Resets cancellation state for a new scan
    private func resetCancellation() {
        isCancelled = false
        currentScanTask = nil
        logger.debug("Cancellation state reset")
    }

    private func throwIfCancelled(_ stage: String) throws {
        if isCancelled || Task.isCancelled {
            logger.info("Scan cancelled during \(stage)")
            throw ScanError.cancelled
        }
    }

    // MARK: - Types

    /// Progress updates during a scan operation
    struct ScanProgress: Sendable {
        /// The current path being scanned
        var currentPath: String

        /// Number of folders/files scanned so far
        var foldersScanned: Int

        /// The snapshot ID for this scan
        var currentSnapshotId: Int64?

        /// Estimated total files (time-based estimation for progress bar) (ISS-033)
        var totalFiles: Int

        /// Calculated progress percentage (0.0-1.0) based on time estimation (ISS-033)
        var percentage: Double

        /// Whether the percentage is based on a stable estimate.
        var hasReliableEstimate: Bool
    }

    // MARK: - Public API

    /// Captures the current volume free space using Apple's recommended API
    /// Uses volumeAvailableCapacityForImportantUsageKey for accurate available space
    /// - Returns: Volume free space in bytes, or nil if unavailable
    private static func captureVolumeFreeSpace() -> Int64? {
        let rootURL = URL(fileURLWithPath: "/")
        let resourceKeys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        
        do {
            let resourceValues = try rootURL.resourceValues(forKeys: resourceKeys)
            if let capacity = resourceValues.volumeAvailableCapacityForImportantUsage {
                return Int64(capacity)
            }
        } catch {
            print("[ScanService] Failed to capture volume free space: \(error)")
        }
        return nil
    }

    /// Scans a directory and stores results in a new database snapshot
    ///
    /// - Parameters:
    ///   - path: The file system path to scan
    ///   - trackedPathId: The ID of the TrackedPath this snapshot belongs to
    ///   - ignoredNames: Optional explicit ignore-name set for headless or test runs
    ///   - progress: Optional callback for progress updates
    /// - Returns: The completed Snapshot with all entries stored
    /// - Throws: ScanError if the path is invalid or scanning fails
    func scan(
        path: String,
        trackedPathId: UUID,
        ignoredNames: Set<String>? = nil,
        progress: ((ScanProgress) -> Void)?
    ) async throws -> Snapshot {
        let didAcquireScanState = await MainActor.run { () -> Bool in
            guard !isScanning else { return false }
            isScanning = true
            return true
        }
        guard didAcquireScanState else {
            logger.error("Scan requested while already scanning")
            throw ScanError.unknown(NSError(
                domain: "ScanService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "A scan is already in progress"]
            ))
        }

        // Reset cancellation state
        resetCancellation()

        logger.info("Starting scan for path: \(path)")

        // Ensure scanning state is reset when done
        defer {
            logger.info("Scan cleanup complete")
            currentScanTask = nil
            Task { @MainActor in
                isScanning = false
            }
        }

        // Convert path to URL and validate
        let url = URL(fileURLWithPath: path)

        // Check if path exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            logger.error("Path does not exist: \(path)")
            throw ScanError.invalidPath
        }

        // Check if it's a directory
        guard isDirectory.boolValue else {
            logger.error("Path is not a directory: \(path)")
            throw ScanError.invalidPath
        }

        return try await withTaskCancellationHandler {
            try await self.scanBody(
                path: path,
                url: url,
                trackedPathId: trackedPathId,
                ignoredNames: ignoredNames,
                progress: progress
            )
        } onCancel: {
            Task { await self.cancelScan() }
        }
    }

    /// Inner scan body extracted so it can be wrapped with withTaskCancellationHandler
    private func scanBody(
        path: String,
        url: URL,
        trackedPathId: UUID,
        ignoredNames: Set<String>?,
        progress: ((ScanProgress) -> Void)?
    ) async throws -> Snapshot {
        // Capture volume free space before creating snapshot
        let freeBytes = Self.captureVolumeFreeSpace()
        if let bytes = freeBytes {
            logger.debug("Captured volume free space: \(bytes) bytes")
        } else {
            logger.debug("Could not capture volume free space")
        }

        // Create new snapshot
        logger.debug("Creating new snapshot")
        let snapshot = try await db.createSnapshot(trackedPathId: trackedPathId, freeBytes: freeBytes)
        guard let snapshotId = snapshot.id else {
            logger.error("Failed to create snapshot with ID")
            throw ScanError.unknown(NSError(
                domain: "ScanService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create snapshot"]
            ))
        }
        logger.debug("Created snapshot ID: \(snapshotId)")

        // Batch insert configuration
        let batchSize = 5000 // Increased from 2000 for better throughput
        var batch: [ScanResult] = []
        var count = 0
        var lastProgressUpdate = Date()
        var lastReportedPercentage = 0.03
        let progressUpdateInterval: TimeInterval = 0.25
        let historicalEntryEstimate = await historicalEntryEstimate(for: trackedPathId)
        var categoryTotals: [GrowthCategory: Int64] = [:]
        struct SubcategoryKey: Hashable {
            let category: GrowthCategory
            let subcategory: GrowthSubcategory?
        }
        struct SubcategoryAccumulator {
            var totalBytes: Int64 = 0
            var fileCount = 0
            var topItems: [GrowthItem] = []

            mutating func add(path: String, sizeBytes: Int64, subcategory: GrowthSubcategory?) {
                totalBytes += sizeBytes
                fileCount += 1

                let item = GrowthItem(
                    path: path,
                    growthBytes: sizeBytes,
                    currentSizeBytes: sizeBytes,
                    percentOfParent: 0,
                    subcategory: subcategory
                )

                if topItems.count < SubcategoryGroup.initialLoadLimit {
                    topItems.append(item)
                } else if let smallestIndex = topItems.indices.min(by: {
                    topItems[$0].currentSizeBytes < topItems[$1].currentSizeBytes
                }), sizeBytes > topItems[smallestIndex].currentSizeBytes {
                    topItems[smallestIndex] = item
                }
            }

            func finalized(subcategory: GrowthSubcategory?) -> [GrowthItem] {
                let sorted = topItems.sorted {
                    if $0.currentSizeBytes == $1.currentSizeBytes {
                        return $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    }
                    return $0.currentSizeBytes > $1.currentSizeBytes
                }
                guard totalBytes > 0 else { return sorted }

                return sorted.map { item in
                    GrowthItem(
                        path: item.path,
                        growthBytes: item.currentSizeBytes,
                        currentSizeBytes: item.currentSizeBytes,
                        percentOfParent: Double(item.currentSizeBytes) / Double(totalBytes),
                        subcategory: subcategory
                    )
                }
            }
        }
        var subcategoryTotals: [SubcategoryKey: SubcategoryAccumulator] = [:]

        // Track scan start time for percentage estimation (ISS-033)
        let scanStartTime = Date()

        // Send initial progress update immediately to show progress bar (UAT-001 fix)
        if let progress = progress {
            let initialProgress = ScanProgress(
                currentPath: path,
                foldersScanned: 0,
                currentSnapshotId: snapshotId,
                totalFiles: 100, // Initial estimate
                percentage: 0.03,
                hasReliableEstimate: historicalEntryEstimate != nil
            )
            progress(initialProgress)
            logger.debug("Initial progress update sent")
        }

        do {
            // Stream scan results and accumulate into batches
            logger.debug("Starting file enumeration stream")
            let resolvedIgnoredNames = if let ignoredNames {
                ignoredNames
            } else {
                await MainActor.run { SettingsStore.shared.allScanIgnoreNames }
            }
            let stream = await scanner.scan(url, ignoredNames: resolvedIgnoredNames)

            for try await result in stream {
                // Check for cancellation (more frequent check)
                if isCancelled || Task.isCancelled {
                    logger.info("Scan cancelled at item \(count)")
                    throw ScanError.cancelled
                }

                batch.append(result)
                count += 1
                let category = GrowthCategory.categorize(path: result.path)
                categoryTotals[category, default: 0] += result.sizeBytes
                let subcategory = GrowthCategory.subcategorize(path: result.path)
                let subcategoryKey = SubcategoryKey(category: category, subcategory: subcategory)
                subcategoryTotals[subcategoryKey, default: SubcategoryAccumulator()]
                    .add(path: result.path, sizeBytes: result.sizeBytes, subcategory: subcategory)

                // Insert batch when full
                if batch.count >= batchSize {
                    logger.debug("Inserting batch of \(batch.count) entries (total: \(count))")
                    try throwIfCancelled("batch insert preflight")
                    try await db.addEntries(to: snapshotId, entries: batch)
                    batch.removeAll()

                    // Check cancellation after database write
                    try throwIfCancelled("batch insert completion")

                    // Yield every 2 batches (4000 items) to reduce coordination overhead
                    if count % (batchSize * 2) == 0 {
                        await Task.yield()
                    }
                }

                // Report progress (throttled to every 500ms)
                if let progress = progress {
                    let now = Date()
                    if now.timeIntervalSince(lastProgressUpdate) >= progressUpdateInterval {
                        lastProgressUpdate = now

                        // Progress estimation with minimum visibility (ISS-033)
                        let elapsed = now.timeIntervalSince(scanStartTime)
                        var percentage: Double
                        let estimatedTotal: Int
                        let hasReliableEstimate: Bool
                        let minimumProgressFloor = 0.03
                        let filesPerSecond = Double(count) / max(elapsed, 0.25)

                        if let historicalEntryEstimate, historicalEntryEstimate > 0 {
                            let historicalTarget = Double(historicalEntryEstimate)
                            let growthBuffer = max(
                                historicalTarget * 0.03,
                                filesPerSecond * 1.5,
                                100.0
                            )
                            let bufferedTarget = max(
                                historicalTarget * 1.03,
                                Double(count) + growthBuffer
                            )
                            percentage = min(0.97, Double(count) / max(bufferedTarget, Double(count) + 1))
                            estimatedTotal = Int(bufferedTarget.rounded())
                            hasReliableEstimate = elapsed >= 0.75 && count >= max(100, historicalEntryEstimate / 20)
                        } else if elapsed >= 1.25 && count >= 500 {
                            // First-ever scans have no baseline count. Wait for a real throughput sample,
                            // then estimate using a shorter moving horizon so progress tracks visible work better.
                            let dynamicHorizon = max(3.5, min(7.0, 4.0 + log10(max(10.0, filesPerSecond))))
                            let estimated = Double(count) + (filesPerSecond * dynamicHorizon)
                            percentage = min(0.90, Double(count) / max(estimated, Double(count) + 1))
                            estimatedTotal = Int(estimated.rounded())
                            hasReliableEstimate = elapsed >= 2.5 && count >= 1_500
                        } else {
                            percentage = min(0.08, minimumProgressFloor + (elapsed * 0.012))
                            estimatedTotal = max(100, count)
                            hasReliableEstimate = false
                        }

                        percentage = max(lastReportedPercentage, percentage)
                        lastReportedPercentage = percentage
                        
                        // Log progress for debugging hangs
                        if count % 10000 == 0 {
                            logger.debug("Scan progress: \(Int(percentage * 100))% (\(count) files, \(elapsed)s elapsed)")
                        }

                        let progressUpdate = ScanProgress(
                            currentPath: result.path,
                            foldersScanned: count,
                            currentSnapshotId: snapshotId,
                            totalFiles: estimatedTotal,
                            percentage: percentage,
                            hasReliableEstimate: hasReliableEstimate
                        )
                        progress(progressUpdate)
                    }
                }
            }

            // Insert any remaining entries in partial batch
            if !batch.isEmpty {
                logger.debug("Inserting final batch of \(batch.count) entries")
                try throwIfCancelled("final batch insert preflight")
                try await db.addEntries(to: snapshotId, entries: batch)
            }

            // Persist category totals while scan results are still hot in memory.
            try throwIfCancelled("category snapshot persistence preflight")
            try await db.replaceCategorySnapshots(snapshotId: snapshotId, totals: categoryTotals)
            let storedSubcategories = subcategoryTotals.map { key, accumulator in
                DatabaseManager.StoredSubcategorySnapshot(
                    category: key.category,
                    subcategory: key.subcategory,
                    totalBytes: accumulator.totalBytes,
                    fileCount: accumulator.fileCount,
                    topItems: accumulator.finalized(subcategory: key.subcategory)
                )
            }
            try throwIfCancelled("subcategory snapshot persistence preflight")
            try await db.replaceSubcategorySnapshots(snapshotId: snapshotId, rows: storedSubcategories)

            // Send final progress update at 100% completion (UAT-001 fix)
            if let progress = progress {
                let finalProgress = ScanProgress(
                    currentPath: path,
                    foldersScanned: count,
                    currentSnapshotId: snapshotId,
                    totalFiles: count,
                    percentage: 1.0, // 100% complete
                    hasReliableEstimate: true
                )
                progress(finalProgress)
                logger.debug("Final progress update sent: \(count) files")
            }

            logger.info("Scan completed successfully: \(count) files scanned")

            return snapshot

        } catch {
            // Clean up orphaned snapshot before rethrowing
            do {
                try await db.deleteSnapshot(id: snapshotId)
                logger.info("Deleted incomplete snapshot ID: \(snapshotId)")
            } catch {
                logger.error("Failed to delete incomplete snapshot ID \(snapshotId): \(error.localizedDescription)")
            }

            // Wrap errors appropriately
            if let scanError = error as? ScanError {
                if case .cancelled = scanError {
                    logger.info("Scan was cancelled")
                }
                throw scanError
            }

            // Check for permission errors
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
                logger.error("Permission denied for path: \(path)")
                throw ScanError.permissionDenied(path)
            }

            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
                logger.error("Out of disk space while scanning path: \(path)")
                let wrapped = NSError(
                    domain: "ScanService",
                    code: NSFileWriteOutOfSpaceError,
                    userInfo: [NSLocalizedDescriptionKey: "Out of disk space while writing scan data"]
                )
                throw ScanError.unknown(wrapped)
            }

            logger.error("Unknown scan error domain=\(nsError.domain) code=\(nsError.code): \(error.localizedDescription)")
            throw ScanError.unknown(error)
        }
    }

    private func historicalEntryEstimate(for trackedPathId: UUID) async -> Int? {
        do {
            let snapshots = try await db.fetchRecentSnapshots(trackedPathId: trackedPathId, limit: 2)
            var candidateCounts: [Int] = []

            for snapshot in snapshots {
                guard let snapshotId = snapshot.id else { continue }
                let count = try await db.fetchEntryCount(for: snapshotId)
                if count > 0 {
                    candidateCounts.append(count)
                }
            }

            return candidateCounts.max()
        } catch {
            logger.debug("Could not load historical entry estimate: \(error.localizedDescription)")
            return nil
        }
    }
}
