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

    /// Tracks whether a scan is currently in progress
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
    }

    // MARK: - Public API

    /// Scans a directory and stores results in a new database snapshot
    ///
    /// - Parameters:
    ///   - path: The file system path to scan
    ///   - trackedPathId: The ID of the TrackedPath this snapshot belongs to
    ///   - progress: Optional callback for progress updates
    /// - Returns: The completed Snapshot with all entries stored
    /// - Throws: ScanError if the path is invalid or scanning fails
    func scan(path: String, trackedPathId: UUID, progress: ((ScanProgress) -> Void)?) async throws -> Snapshot {
        // Check if already scanning
        if await isScanning {
            logger.error("Scan requested while already scanning")
            throw ScanError.unknown(NSError(
                domain: "ScanService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "A scan is already in progress"]
            ))
        }

        // Reset cancellation state
        resetCancellation()

        // Store task handle for cancellation
        let scanTask = Task<Void, Never> {
            // Scan body
        }
        currentScanTask = scanTask

        // Set scanning state
        await MainActor.run {
            isScanning = true
        }

        logger.info("Starting scan for path: \(path)")

        // Ensure scanning state is reset when done
        defer {
            logger.info("Scan cleanup complete")
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

        // Create new snapshot
        logger.debug("Creating new snapshot")
        let snapshot = try await db.createSnapshot(trackedPathId: trackedPathId)
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
        let batchSize = 2000
        var batch: [ScanResult] = []
        var count = 0
        var lastProgressUpdate = Date()
        let progressUpdateInterval: TimeInterval = 0.5 // 500ms between updates

        // Track scan start time for percentage estimation (ISS-033)
        let scanStartTime = Date()

        do {
            // Stream scan results and accumulate into batches
            logger.debug("Starting file enumeration stream")
            let stream = await scanner.scan(url)

            for try await result in stream {
                // Check for cancellation (more frequent check)
                if isCancelled || Task.isCancelled {
                    logger.info("Scan cancelled at item \(count)")
                    throw ScanError.cancelled
                }

                batch.append(result)
                count += 1

                // Insert batch when full
                if batch.count >= batchSize {
                    logger.debug("Inserting batch of \(batch.count) entries (total: \(count))")
                    try await db.addEntries(to: snapshotId, entries: batch)
                    batch.removeAll()

                    // Check cancellation after database write
                    if isCancelled || Task.isCancelled {
                        logger.info("Scan cancelled after batch insert at item \(count)")
                        throw ScanError.cancelled
                    }

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

                        // Minimum progress to show the bar immediately
                        let minimumProgress = min(0.10, Double(count) / 100.0)

                        if elapsed < 1.0 {
                            // First second: show minimum progress (just started)
                            percentage = minimumProgress
                            estimatedTotal = max(100, count * 5) // Rough estimate
                        } else if count < 100 {
                            // Small scan: show progress based on count with minimum floor
                            percentage = min(0.50, minimumProgress)
                            estimatedTotal = max(100, count * 3)
                        } else {
                            // Larger scan: estimate based on scan rate
                            let rate = Double(count) / elapsed
                            // Estimate assuming current rate continues, with 50% buffer
                            let estimated = Double(count) + (rate * 2.0)
                            estimatedTotal = Int(estimated)
                            // Progressive percentage that grows with scan
                            percentage = min(0.95, Double(count) / max(1.0, estimated))
                            // Ensure at least some progress is visible
                            percentage = max(minimumProgress, percentage)
                        }

                        let progressUpdate = ScanProgress(
                            currentPath: result.path,
                            foldersScanned: count,
                            currentSnapshotId: snapshotId,
                            totalFiles: estimatedTotal,
                            percentage: percentage
                        )
                        progress(progressUpdate)
                        logger.debug("Progress update: \(count) files scanned, \(Int(percentage * 100))%")
                    }
                }
            }

            // Insert any remaining entries in partial batch
            if !batch.isEmpty {
                logger.debug("Inserting final batch of \(batch.count) entries")
                try await db.addEntries(to: snapshotId, entries: batch)
            }

            logger.info("Scan completed successfully: \(count) files scanned")
            return snapshot

        } catch {
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

            logger.error("Unknown scan error: \(error.localizedDescription)")
            throw ScanError.unknown(error)
        }
    }
}
