import Foundation
import OSLog
import Darwin
import os

/// Thread-safe cancellation token that lets the scan caller signal cancellation
/// directly to the FTS producer, bypassing the stream consumer round-trip.
final class ScanCancellationToken: @unchecked Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }
}

private final class ScanTraversalState: @unchecked Sendable {
    struct Snapshot {
        let lastProgressAt: Date
        let currentPath: String
        let isFinished: Bool
    }

    private struct State {
        var lastProgressAt: Date
        var currentPath: String
        var isFinished = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(rootPath: String) {
        state = OSAllocatedUnfairLock(initialState: State(lastProgressAt: Date(), currentPath: rootPath))
    }

    func markProgress(path: String) {
        state.withLock {
            $0.lastProgressAt = Date()
            $0.currentPath = path
        }
    }

    func markFinished() {
        state.withLock { $0.isFinished = true }
    }

    func snapshot() -> Snapshot {
        state.withLock {
            Snapshot(lastProgressAt: $0.lastProgressAt, currentPath: $0.currentPath, isFinished: $0.isFinished)
        }
    }
}

/// Recursively scans directories and streams scan results.
///
/// Optimized for speed: low-level FTS traversal avoids Foundation URL/resourceValues
/// overhead on every filesystem entry.
final class FileScanner {

    // MARK: - Properties

    private static let logger = Logger(subsystem: "com.prunr.FileScanner", category: "Scanning")
    private static let traversalStallTimeout: TimeInterval = 30
    private static let watchdogInterval: TimeInterval = 5

    /// App-internal paths to avoid recursive self-observation.
    private let internalPathFragments: [String] = [
        "/Library/Application Support/Prunr/",
        "/.build/derivedData/"
    ]

    /// iCloud paths that can hang when accessed
    private let iCloudPathFragments: [String] = [
        "/Library/Mobile Documents/",
        "/.icloud/",
        "/com~apple~"
    ]

    static func diskUsageBytes(for fileStat: stat) -> Int64 {
        let allocatedBytes = Int64(fileStat.st_blocks) * Int64(DEV_BSIZE)
        return allocatedBytes > 0 ? allocatedBytes : Int64(fileStat.st_size)
    }

    // MARK: - Public API

    /// Recursively scans a directory and streams results via AsyncThrowingStream
    ///
    /// - Parameter rootURL: The root URL to begin scanning from
    /// - Returns: An AsyncThrowingStream that yields ScanResult values
    func scan(_ rootURL: URL, ignoredNames: Set<String>, cancellationToken: ScanCancellationToken? = nil) -> AsyncThrowingStream<ScanResult, Error> {
        return AsyncThrowingStream<ScanResult, Error> { continuation in
            let traversalState = ScanTraversalState(rootPath: rootURL.path)
            let watchdogTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.watchdogInterval))
                    guard !Task.isCancelled else { return }

                    let snapshot = traversalState.snapshot()
                    guard !snapshot.isFinished else { return }

                    let stalledFor = Date().timeIntervalSince(snapshot.lastProgressAt)
                    guard stalledFor >= Self.traversalStallTimeout else { continue }

                    Self.logger.error("Traversal watchdog aborting scan after \(stalledFor)s without progress at \(snapshot.currentPath, privacy: .public)")
                    cancellationToken?.cancel()
                    continuation.finish(throwing: ScanError.stalled(snapshot.currentPath))
                    return
                }
            }

            let producerTask = Task { [weak self] in
                guard let self else {
                    traversalState.markFinished()
                    continuation.finish()
                    return
                }

                defer {
                    traversalState.markFinished()
                    watchdogTask.cancel()
                }

                let fileManager = FileManager.default

                // Verify root path exists before enumerating
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
                    traversalState.markFinished()
                    continuation.finish(throwing: ScanError.invalidPath)
                    return
                }

                guard isDirectory.boolValue else {
                    traversalState.markFinished()
                    continuation.finish(throwing: ScanError.invalidPath)
                    return
                }

                var count = 0
                var lastLogCount = 0
                let logInterval = 5000
                let normalizedIgnoredNames = Set(ignoredNames.map { $0.lowercased() })
                let options = FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV
                let rootPath = rootURL.path
                let duplicatedRoot = strdup(rootPath)

                guard let duplicatedRoot else {
                    continuation.finish(throwing: ScanError.invalidPath)
                    return
                }

                let pathBuffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 2)
                pathBuffer.initialize(to: duplicatedRoot)
                pathBuffer.advanced(by: 1).initialize(to: nil)

                guard let tree = fts_open(pathBuffer, options, nil) else {
                    free(duplicatedRoot)
                    pathBuffer.deinitialize(count: 2)
                    pathBuffer.deallocate()
                    continuation.finish(throwing: ScanError.invalidPath)
                    return
                }

                defer {
                    fts_close(tree)
                    free(duplicatedRoot)
                    pathBuffer.deinitialize(count: 2)
                    pathBuffer.deallocate()
                }

                while let entry = fts_read(tree) {
                    if Task.isCancelled || cancellationToken?.isCancelled == true {
                        Self.logger.info("Producer task cancelled after \(count) files")
                        break
                    }

                    let info = Int32(entry.pointee.fts_info)
                    let level = Int(entry.pointee.fts_level)
                    let path = String(cString: entry.pointee.fts_path)
                    traversalState.markProgress(path: path)

                    switch info {
                    case FTS_D:
                        let directoryName = (path as NSString).lastPathComponent
                        if level > 0 && self.shouldSkipDirectory(path: path, name: directoryName, ignoredNames: normalizedIgnoredNames) {
                            fts_set(tree, entry, FTS_SKIP)
                        }

                    case FTS_F:
                        guard let statPointer = entry.pointee.fts_statp else { continue }
                        let stat = statPointer.pointee
                        let sizeBytes = Self.diskUsageBytes(for: stat)
                        let (category, subcategory) = GrowthCategory.classify(path: path)
                        let result = ScanResult(
                            path: path,
                            sizeBytes: sizeBytes,
                            category: category,
                            subcategory: subcategory
                        )
                        continuation.yield(result)
                        count += 1

                        if count - lastLogCount >= logInterval {
                            Self.logger.debug("Scanned \(count) files, current: \(path, privacy: .public)")
                            lastLogCount = count
                        }

                        if count % 10000 == 0 {
                            await Task.yield()
                        }

                    case FTS_DNR, FTS_ERR, FTS_NS:
                        if entry.pointee.fts_errno != 0 {
                            let message = String(cString: strerror(entry.pointee.fts_errno))
                            Self.logger.error("FTS error at \(path, privacy: .public): \(message, privacy: .public)")
                        } else {
                            Self.logger.error("FTS error at \(path, privacy: .public)")
                        }

                    case FTS_SL, FTS_SLNONE:
                        continue

                    default:
                        continue
                    }
                }

                Self.logger.debug("Scan complete: \(count) files total")
                continuation.finish()
            }

            // Cancel the producer when the stream is terminated (consumer cancelled or dropped)
            continuation.onTermination = { @Sendable _ in
                watchdogTask.cancel()
                producerTask.cancel()
            }
        }
    }

    // MARK: - Private Helpers

    private func shouldSkipDirectory(path: String, name: String, ignoredNames: Set<String>) -> Bool {
        let lowercasedName = name.lowercased()
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path

        if ignoredNames.contains(lowercasedName) {
            return true
        }

        for fragment in internalPathFragments where standardizedPath.contains(fragment) {
            return true
        }

        // Skip iCloud directories that can hang
        for fragment in iCloudPathFragments where standardizedPath.contains(fragment) {
            return true
        }

        // Skip known problematic paths that cause FTS stalls
        if shouldSkipProblematicDirectory(path: standardizedPath, lowercasedName: lowercasedName) {
            Self.logger.debug("Skipping problematic directory: \(path, privacy: .public)")
            return true
        }

        return false
    }

    private func shouldSkipProblematicDirectory(path: String, lowercasedName: String) -> Bool {
        if lowercasedName.hasSuffix(".photolibrary") || lowercasedName.hasSuffix(".photoslibrary") {
            return true
        }

        let components = path.split(separator: "/").map { String($0).lowercased() }
        for index in components.indices {
            switch components[index] {
            case "mail" where index > 0 && components[index - 1] == "library":
                return true
            case ".trash", ".mobilebackups":
                return true
            case "saved application state" where index > 0 && components[index - 1] == "library":
                return true
            default:
                continue
            }
        }

        return false
    }
}
