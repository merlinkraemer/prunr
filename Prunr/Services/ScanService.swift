import Foundation

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

    private init() {}

    /// Cancels the current scan operation
    func cancelScan() {
        isCancelled = true
    }

    /// Resets cancellation state for a new scan
    private func resetCancellation() {
        isCancelled = false
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
            throw ScanError.unknown(NSError(
                domain: "ScanService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "A scan is already in progress"]
            ))
        }

        // Reset cancellation state
        resetCancellation()

        // Set scanning state
        await MainActor.run {
            isScanning = true
        }

        // Ensure scanning state is reset when done
        defer {
            Task { @MainActor in
                isScanning = false
            }
        }

        // Convert path to URL and validate
        let url = URL(fileURLWithPath: path)

        // Check if path exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ScanError.invalidPath
        }

        // Check if it's a directory
        guard isDirectory.boolValue else {
            throw ScanError.invalidPath
        }

        // Create new snapshot
        let snapshot = try await db.createSnapshot(trackedPathId: trackedPathId)
        guard let snapshotId = snapshot.id else {
            throw ScanError.unknown(NSError(
                domain: "ScanService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create snapshot"]
            ))
        }

        // Batch insert configuration
        let batchSize = 2000
        var batch: [ScanResult] = []
        var count = 0

        do {
            // Stream scan results and accumulate into batches
            let stream = await scanner.scan(url)

            for try await result in stream {
                // Check for cancellation
                if isCancelled {
                    throw ScanError.cancelled
                }

                batch.append(result)
                count += 1

                // Insert batch when full
                if batch.count >= batchSize {
                    try await db.addEntries(to: snapshotId, entries: batch)
                    batch.removeAll()
                    await Task.yield()
                }

                // Report progress
                if let progress = progress {
                    let progressUpdate = ScanProgress(
                        currentPath: result.path,
                        foldersScanned: count,
                        currentSnapshotId: snapshotId
                    )
                    progress(progressUpdate)
                }
            }

            // Insert any remaining entries in partial batch
            if !batch.isEmpty {
                try await db.addEntries(to: snapshotId, entries: batch)
            }

            return snapshot

        } catch {
            // Wrap errors appropriately
            if let scanError = error as? ScanError {
                throw scanError
            }

            // Check for permission errors
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
                throw ScanError.permissionDenied(path)
            }

            throw ScanError.unknown(error)
        }
    }
}
