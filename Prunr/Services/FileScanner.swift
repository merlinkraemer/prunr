import Foundation

/// Actor that recursively scans directories and streams scan results
///
/// Optimized for speed: single resourceValues call per file, skips heavy directories,
/// and minimizes filesystem overhead.
actor FileScanner {

    // MARK: - Properties

    private let fileManager = FileManager.default

    /// Resource keys to fetch in ONE call per file (optimized)
    private let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .totalFileAllocatedSizeKey,
        .isSymbolicLinkKey,
        .isDirectoryKey,
        .nameKey
    ]

    /// Enumeration options for performance and safety
    private let enumerationOptions: FileManager.DirectoryEnumerationOptions = [
        .skipsHiddenFiles,
        .skipsPackageDescendants
    ]

    /// Directories to skip entirely (heavy build artifacts, cache directories)
    private let skipDirectories: Set<String> = [
        "node_modules",
        ".git",
        "build",
        "DerivedData",
        ".build",
        "Pods",
        "Carthage",
        "vendor",
        "__pycache__",
        ".venv",
        "venv",
        ".tox",
        "target",
        "out",
        "dist",
        ".gradle",
        ".idea",
        ".vscode",
        "Library/Caches",
        "Library/Developer/Xcode/DerivedData"
    ]

    // MARK: - Public API

    /// Recursively scans a directory and streams results via AsyncThrowingStream
    ///
    /// - Parameter rootURL: The root URL to begin scanning from
    /// - Returns: An AsyncThrowingStream that yields ScanResult values
    func scan(_ rootURL: URL) -> AsyncThrowingStream<ScanResult, Error> {
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
                    let errorHandler: (URL, Error) -> Bool = { _, _ in
                        true // Continue on errors
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
                        // Process each file with single resourceValues call
                        if let result = await self.processFile(url: url, enumerator: enumerator) {
                            continuation.yield(result)
                            count += 1
                            
                            // Yield less frequently for better throughput
                            if count % 2000 == 0 {
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

    /// Process a single file/directory - returns nil if should skip
    private func processFile(url: URL, enumerator: FileManager.DirectoryEnumerator) -> ScanResult? {
        do {
            // Single resourceValues call for all info
            let resourceValues = try url.resourceValues(forKeys: resourceKeys)

            // Skip symlinks
            if resourceValues.isSymbolicLink == true {
                return nil
            }

            // Handle directories - skip heavy ones
            if resourceValues.isDirectory == true {
                if let name = resourceValues.name, skipDirectories.contains(name) {
                    enumerator.skipDescendants()
                    return nil
                }
                return nil // Don't yield directories
            }

            // Only process regular files
            if resourceValues.isRegularFile != true {
                return nil
            }

            // Get size (try allocated size first, then file size)
            let sizeBytes: Int64
            if let totalSize = resourceValues.totalFileAllocatedSize {
                sizeBytes = Int64(totalSize)
            } else {
                return nil
            }

            return ScanResult(path: url.path, sizeBytes: sizeBytes)

        } catch {
            return nil
        }
    }
}
