import Foundation

/// Actor that recursively scans directories and streams scan results
///
/// Uses URL-based FileManager enumeration for optimal performance (3x faster than string-based).
/// Implements safety measures for symlinks, hard links, and permission errors.
actor FileScanner {

    // MARK: - Properties

    private let fileManager = FileManager.default
    private var visitedInodes = Set<NSNumber>()

    /// Resource keys to fetch during enumeration
    private let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .totalFileAllocatedSizeKey,
        .isSymbolicLinkKey,
        .isAliasFileKey,
        .fileResourceIdentifierKey
    ]

    /// Enumeration options for performance and safety
    private let enumerationOptions: FileManager.DirectoryEnumerationOptions = [
        .skipsHiddenFiles,
        .skipsPackageDescendants
    ]

    // MARK: - Public API

    /// Recursively scans specific paths and streams results via AsyncThrowingStream
    ///
    /// This is optimized for incremental scanning - only scans the exact paths provided,
    /// recursing into directories if needed. Much faster than scanning entire directory trees.
    ///
    /// - Parameter paths: The specific paths to scan (files or directories)
    /// - Returns: An AsyncThrowingStream that yields ScanResult values
    func scanSpecificPaths(_ paths: [URL]) -> AsyncThrowingStream<ScanResult, Error> {
        // Reset state for fresh scan
        visitedInodes.removeAll()

        return AsyncThrowingStream<ScanResult, Error> { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                do {
                    var count = 0

                    for path in paths {
                        // Check if we should skip this URL
                        if await self.shouldSkip(path) {
                            continue
                        }

                        var isDirectory: ObjCBool = false
                        guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                            continue // Skip paths that don't exist
                        }

                        if isDirectory.boolValue {
                            // Recursively scan directory
                            let errorHandler: (URL, Error) -> Bool = { _, _ in true }

                            guard let enumerator = fileManager.enumerator(
                                at: path,
                                includingPropertiesForKeys: Array(resourceKeys),
                                options: enumerationOptions,
                                errorHandler: errorHandler
                            ) else {
                                continue
                            }

                            for case let url as URL in enumerator {
                                if await self.shouldSkip(url) {
                                    continue
                                }

                                if let sizeBytes = await self.getSize(for: url) {
                                    continuation.yield(ScanResult(path: url.path, sizeBytes: sizeBytes))
                                    count += 1
                                    if count % 1000 == 0 {
                                        await Task.yield()
                                    }
                                }
                            }
                        } else {
                            // Single file - just get its size
                            if let sizeBytes = await self.getSize(for: path) {
                                continuation.yield(ScanResult(path: path.path, sizeBytes: sizeBytes))
                                count += 1
                            }
                        }
                    }

                    continuation.finish()

                } catch {
                    continuation.finish(throwing: ScanError.unknown(error))
                }
            }
        }
    }

    /// Recursively scans a directory and streams results via AsyncThrowingStream
    ///
    /// - Parameter rootURL: The root URL to begin scanning from
    /// - Returns: An AsyncThrowingStream that yields ScanResult values
    func scan(_ rootURL: URL) -> AsyncThrowingStream<ScanResult, Error> {
        // Reset state for fresh scan
        visitedInodes.removeAll()

        return AsyncThrowingStream<ScanResult, Error> { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                do {
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
                        // Log permission errors but continue scanning
                        if (error as? CocoaError)?.code == .fileReadNoPermission {
                            // Could yield an error result here if needed
                            return true // Continue enumeration
                        }
                        return true // Continue on other errors too
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
                    for case let url as URL in enumerator {
                        // Check if we should skip this URL
                        if await self.shouldSkip(url) {
                            continue
                        }

                        // Get the file size
                        if let sizeBytes = await self.getSize(for: url) {
                            let result = ScanResult(
                                path: url.path,
                                sizeBytes: sizeBytes
                            )
                            continuation.yield(result)

                            // Yield to prevent blocking every 1000 items
                            count += 1
                            if count % 1000 == 0 {
                                await Task.yield()
                            }
                        }
                    }

                    continuation.finish()

                } catch {
                    continuation.finish(throwing: ScanError.unknown(error))
                }
            }
        }
    }

    // MARK: - Private Helpers

    /// Determines whether a URL should be skipped during scanning
    private func shouldSkip(_ url: URL) -> Bool {
        do {
            let resourceValues = try url.resourceValues(forKeys: resourceKeys)

            // Skip symlinks to prevent infinite loops
            if let isSymbolicLink = resourceValues.isSymbolicLink, isSymbolicLink {
                return true
            }

            // Skip alias files
            if let isAliasFile = resourceValues.isAliasFile, isAliasFile {
                return true
            }

            // Skip if not a regular file (directories are handled by enumerator)
            if let isRegularFile = resourceValues.isRegularFile, !isRegularFile {
                return true
            }

            // Track inodes for hard link deduplication
            if let fileIdentifier = resourceValues.fileResourceIdentifier as? NSNumber {
                if visitedInodes.contains(fileIdentifier) {
                    return true // Already counted this hard link
                }
                visitedInodes.insert(fileIdentifier)
            }

            return false

        } catch {
            // On error, skip this item
            return true
        }
    }

    /// Gets the allocated disk size for a URL
    ///
    /// Uses totalFileAllocatedSizeKey for accurate APFS disk usage.
    /// Falls back to fileAllocatedSizeKey, then fileSizeKey if needed.
    private func getSize(for url: URL) -> Int64? {
        do {
            // Try totalFileAllocatedSizeKey first (most accurate for APFS)
            if let totalSize = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                .totalFileAllocatedSize {
                return Int64(totalSize)
            }

            // Fallback to fileAllocatedSizeKey
            if let allocatedSize = try url.resourceValues(forKeys: [.fileAllocatedSizeKey])
                .fileAllocatedSize {
                return Int64(allocatedSize)
            }

            // Last resort: fileSizeKey (logical size, not disk usage)
            if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey])
                .fileSize {
                return Int64(fileSize)
            }

            return nil

        } catch {
            return nil
        }
    }
}
