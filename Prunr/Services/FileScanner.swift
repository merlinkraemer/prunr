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

/// Bounds outstanding scan results between FileScanner's producer and the
/// ScanService DB consumer. Does not drop results (unlike bufferingNewest/Oldest).
actor ScanBackpressureGate {
    private let maxOutstanding: Int
    private var outstanding = 0
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var isClosed = false

    init(maxOutstanding: Int = 20_000) {
        self.maxOutstanding = max(1, maxOutstanding)
    }

    /// Wait until there is capacity, then reserve one outstanding slot.
    /// Returns `false` after `close()` so cancellation cannot deadlock or yield
    /// another result after the consumer has stopped.
    func waitToProduce() async -> Bool {
        guard !isClosed else { return false }
        if outstanding < maxOutstanding {
            outstanding += 1
            return true
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if isClosed {
                continuation.resume(returning: false)
            } else {
                waiters.append(continuation)
            }
        }
    }

    /// Release capacity after the consumer successfully persists a batch.
    func release(_ count: Int) {
        guard count > 0 else { return }
        outstanding = max(0, outstanding - count)
        resumeWaitersIfNeeded()
    }

    /// Unblock any waiting producers on cancel, error, or stream termination.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(returning: false)
        }
    }

    private func resumeWaitersIfNeeded() {
        while outstanding < maxOutstanding, !waiters.isEmpty {
            outstanding += 1
            waiters.removeFirst().resume(returning: true)
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

    /// Dev-only build-output fragments excluded as a defense in depth. Prunr's
    /// real operational state is sourced from `PrunrInternalPaths`.
    private let internalPathFragments: [String] = [
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
    /// - Parameters:
    ///   - rootURL: The root URL to begin scanning from
    ///   - ignoredNames: Directory names to skip
    ///   - cancellationToken: Optional cooperative cancel signal
    ///   - backpressure: Optional gate limiting outstanding unconsumed results
    /// - Returns: An AsyncThrowingStream that yields ScanResult values
    func scan(
        _ rootURL: URL,
        ignoredNames: Set<String>,
        cancellationToken: ScanCancellationToken? = nil,
        backpressure: ScanBackpressureGate? = nil
    ) -> AsyncThrowingStream<ScanResult, Error> {
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
                    await backpressure?.close()
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
                    await backpressure?.close()
                    continuation.finish(throwing: ScanError.invalidPath)
                    return
                }

                guard isDirectory.boolValue else {
                    traversalState.markFinished()
                    await backpressure?.close()
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
                    await backpressure?.close()
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
                    await backpressure?.close()
                    continuation.finish(throwing: ScanError.invalidPath)
                    return
                }

                defer {
                    fts_close(tree)
                    free(duplicatedRoot)
                    pathBuffer.deinitialize(count: 2)
                    pathBuffer.deallocate()
                }

                scanLoop: while let entry = fts_read(tree) {
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
                        guard !PrunrInternalPaths.isInternalPath(path) else { continue }
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
                        if let backpressure {
                            guard await backpressure.waitToProduce() else {
                                break scanLoop
                            }
                            if Task.isCancelled || cancellationToken?.isCancelled == true {
                                break scanLoop
                            }
                        }
                        continuation.yield(result)
                        count += 1

                        if count - lastLogCount >= logInterval {
                            Self.logger.debug("Scanned \(count) files, current: \(path, privacy: .public)")
                            lastLogCount = count
                        }

                    case FTS_DNR, FTS_ERR, FTS_NS:
                        let entryErrno = entry.pointee.fts_errno
                        if entryErrno != 0 {
                            let message = String(cString: strerror(entryErrno))
                            Self.logger.error("FTS error at \(path, privacy: .public): \(message, privacy: .public)")
                        } else {
                            Self.logger.error("FTS error at \(path, privacy: .public)")
                        }

                        if let abortError = Self.abortError(forFTSErrno: entryErrno, path: path) {
                            await backpressure?.close()
                            continuation.finish(throwing: abortError)
                            return
                        }
                        continue

                    case FTS_SL, FTS_SLNONE:
                        continue

                    default:
                        continue
                    }
                }

                Self.logger.debug("Scan complete: \(count) files total")
                await backpressure?.close()
                continuation.finish()
            }

            // Cancel the producer when the stream is terminated (consumer cancelled or dropped)
            continuation.onTermination = { @Sendable _ in
                Task {
                    await backpressure?.close()
                }
                watchdogTask.cancel()
                producerTask.cancel()
            }
        }
    }

    // MARK: - FTS Error Policy

    /// Transient per-entry failures (vanished/stale nodes) continue the scan.
    /// Permission and other systematic errors abort so inventories stay trustworthy.
    static func abortError(forFTSErrno entryErrno: Int32, path: String) -> ScanError? {
        switch entryErrno {
        case ENOENT, ESTALE:
            return nil
        case EACCES, EPERM:
            return .permissionDenied(path)
        default:
            return .traversalFailed(path)
        }
    }

    // MARK: - Private Helpers

    private func shouldSkipDirectory(path: String, name: String, ignoredNames: Set<String>) -> Bool {
        let lowercasedName = name.lowercased()
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path

        if ignoredNames.contains(lowercasedName) {
            return true
        }

        if PrunrInternalPaths.isInternalPath(standardizedPath) {
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
