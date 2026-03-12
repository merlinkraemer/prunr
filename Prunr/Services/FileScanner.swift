import Foundation
import OSLog

/// Actor that recursively scans directories and streams scan results
///
/// Optimized for speed: single resourceValues call per file and minimal overhead.
actor FileScanner {

    // MARK: - Properties

    private nonisolated static let logger = Logger(subsystem: "com.prunr.FileScanner", category: "Scanning")

    /// Resource keys to fetch in ONE call per file (optimized)
    private let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .isSymbolicLinkKey,
        .isDirectoryKey,
        .nameKey,
        .isUbiquitousItemKey,  // iCloud file
        .ubiquitousItemDownloadingStatusKey  // iCloud download status
    ]

    /// Enumeration options for performance and safety.
    /// Keep hidden files included because they are often large contributors
    /// in developer environments (.docker, .Trash, cache folders).
    /// Note: We do NOT use .skipsPackageDescendants so that .app bundles and
    /// other packages are traversed to count their file sizes.
    private let enumerationOptions: FileManager.DirectoryEnumerationOptions = []

    /// App-internal paths to avoid recursive self-observation.
    private let internalPathFragments: [String] = [
        "/Library/Application Support/Prunr/",
        "/.build/derivedData/",
        "/dev/projects/prunr/.build/"
    ]

    /// iCloud paths that can hang when accessed
    private let iCloudPathFragments: [String] = [
        "/Library/Mobile Documents/",
        "/.icloud/",
        "/com~apple~"
    ]

    // MARK: - Public API

    /// Recursively scans a directory and streams results via AsyncThrowingStream
    ///
    /// - Parameter rootURL: The root URL to begin scanning from
    /// - Returns: An AsyncThrowingStream that yields ScanResult values
    func scan(_ rootURL: URL, ignoredNames: Set<String>) -> AsyncThrowingStream<ScanResult, Error> {
        return AsyncThrowingStream<ScanResult, Error> { continuation in
            let producerTask = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                let fileManager = FileManager.default

                // Verify root path exists before enumerating
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
                    continuation.finish(throwing: ScanError.invalidPath)
                    return
                }

                guard isDirectory.boolValue else {
                    continuation.finish(throwing: ScanError.invalidPath)
                    return
                }

                // Create the enumerator with proper error handling
                let errorHandler: (URL, Error) -> Bool = { url, error in
                    Self.logger.error("Directory enumerator error at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return true // Continue on errors
                }

                guard let enumerator = fileManager.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: enumerationOptions,
                    errorHandler: errorHandler
                ) else {
                    continuation.finish(throwing: ScanError.invalidPath)
                    return
                }

                var count = 0
                var lastLogCount = 0
                let logInterval = 5000
                let normalizedIgnoredNames = Set(ignoredNames.map { $0.lowercased() })

                for case let url as URL in enumerator {
                    // Stop the filesystem walk when the stream consumer cancels
                    if Task.isCancelled {
                        Self.logger.info("Producer task cancelled after \(count) files")
                        break
                    }

                    let path = url.path

                    // Skip iCloud paths before accessing resourceValues (can hang)
                    if self.iCloudPathFragments.contains(where: { path.contains($0) }) {
                        enumerator.skipDescendants()
                        continue
                    }

                    // Process each file with single resourceValues call
                    if let result = await self.processFile(url: url, enumerator: enumerator, ignoredNames: normalizedIgnoredNames) {
                        continuation.yield(result)
                        count += 1

                        // Log progress every 5000 files to detect hangs
                        if count - lastLogCount >= logInterval {
                            Self.logger.debug("Scanned \(count) files, current: \(path, privacy: .public)")
                            lastLogCount = count
                        }

                        // Yield less frequently for better throughput
                        if count % 2000 == 0 {
                            await Task.yield()
                        }
                    }
                }
                Self.logger.debug("Scan complete: \(count) files total")

                continuation.finish()
            }

            // Cancel the producer when the stream is terminated (consumer cancelled or dropped)
            continuation.onTermination = { @Sendable _ in
                producerTask.cancel()
            }
        }
    }

    // MARK: - Private Helpers

    /// Process a single file/directory - returns nil if should skip
    private func processFile(url: URL, enumerator: FileManager.DirectoryEnumerator, ignoredNames: Set<String>) -> ScanResult? {
        do {
            // Single resourceValues call for all info
            let resourceValues = try url.resourceValues(forKeys: resourceKeys)
            let fileName = (resourceValues.name ?? url.lastPathComponent).lowercased()

            if ignoredNames.contains(fileName) {
                if resourceValues.isDirectory == true {
                    enumerator.skipDescendants()
                }
                return nil
            }

            // Skip symlinks
            if resourceValues.isSymbolicLink == true {
                return nil
            }

            // Handle directories
            if resourceValues.isDirectory == true {
                if shouldSkipDirectory(url: url, ignoredNames: ignoredNames) {
                    enumerator.skipDescendants()
                    return nil
                }
                return nil // Don't yield directories
            }

            // Only process regular files
            if resourceValues.isRegularFile != true {
                return nil
            }

            // Skip iCloud files that are not downloaded locally (avoid hang on download)
            if resourceValues.isUbiquitousItem == true {
                let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus
                if downloadStatus != URLUbiquitousItemDownloadingStatus.current {
                    Self.logger.debug("Skipped non-local iCloud file: \(url.path, privacy: .public)")
                    return nil
                }
            }

            // Get size (try allocated size first, then file size)
            let sizeBytes: Int64
            if let totalSize = resourceValues.totalFileAllocatedSize {
                sizeBytes = Int64(totalSize)
            } else if let fileSize = resourceValues.fileSize {
                sizeBytes = Int64(fileSize)
            } else {
                Self.logger.debug("Skipped file with nil size: \(url.lastPathComponent, privacy: .public)")
                return nil
            }

            return ScanResult(path: url.path, sizeBytes: sizeBytes)

        } catch {
            Self.logger.error("Failed to process path \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func shouldSkipDirectory(url: URL, ignoredNames: Set<String>) -> Bool {
        let path = url.path
        let name = url.lastPathComponent.lowercased()

        if ignoredNames.contains(name) {
            return true
        }

        for fragment in internalPathFragments where path.contains(fragment) {
            return true
        }

        // Skip iCloud directories that can hang
        for fragment in iCloudPathFragments where path.contains(fragment) {
            return true
        }

        return false
    }
}
