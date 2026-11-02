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

/// Entries a scan skipped because the system denied access (no Full Disk
/// Access, or plain Unix permissions). Their bytes are unknown, not zero.
final class ScanSkipLog: @unchecked Sendable {
    private let paths = OSAllocatedUnfairLock(initialState: [String]())

    var skippedPaths: [String] {
        paths.withLock { $0 }
    }

    var count: Int {
        paths.withLock { $0.count }
    }

    var locationLabels: [String] {
        Array(Set(skippedPaths.map { path in
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        })).sorted()
    }

    func record(_ path: String) {
        paths.withLock { $0.append(path) }
    }
}

final class ScanTraversalState: @unchecked Sendable {
    struct Snapshot {
        let lastProgressAt: TimeInterval
        let currentPath: String
        let isFinished: Bool
        let consumerWaitStartedAt: TimeInterval?
    }

    private struct State {
        var lastProgressAt: TimeInterval
        var currentPath: String
        var isFinished = false
        var consumerWaitStartedAt: TimeInterval?
    }

    static let sleepExcludingUptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private let state: OSAllocatedUnfairLock<State>
    private let uptime: @Sendable () -> TimeInterval

    init(rootPath: String, uptime: @escaping @Sendable () -> TimeInterval = ScanTraversalState.sleepExcludingUptime) {
        self.uptime = uptime
        state = OSAllocatedUnfairLock(initialState: State(lastProgressAt: uptime(), currentPath: rootPath))
    }

    func now() -> TimeInterval {
        uptime()
    }

    func markProgress(path: String) {
        let current = uptime()
        state.withLock {
            $0.lastProgressAt = current
            $0.currentPath = path
        }
    }

    func beginConsumerWait() {
        let current = uptime()
        state.withLock { $0.consumerWaitStartedAt = current }
    }

    func endConsumerWait() {
        let current = uptime()
        state.withLock {
            $0.consumerWaitStartedAt = nil
            $0.lastProgressAt = current
        }
    }

    func markFinished() {
        state.withLock { $0.isFinished = true }
    }

    func snapshot() -> Snapshot {
        state.withLock {
            Snapshot(
                lastProgressAt: $0.lastProgressAt,
                currentPath: $0.currentPath,
                isFinished: $0.isFinished,
                consumerWaitStartedAt: $0.consumerWaitStartedAt
            )
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
    static let defaultTraversalStallTimeout: TimeInterval = 30
    static let defaultConsumerStallTimeout: TimeInterval = 900
    static let defaultWatchdogInterval: TimeInterval = 5

    private let traversalStallTimeout: TimeInterval
    private let consumerStallTimeout: TimeInterval
    private let watchdogInterval: TimeInterval

    init(
        traversalStallTimeout: TimeInterval = FileScanner.defaultTraversalStallTimeout,
        consumerStallTimeout: TimeInterval = FileScanner.defaultConsumerStallTimeout,
        watchdogInterval: TimeInterval = FileScanner.defaultWatchdogInterval
    ) {
        self.traversalStallTimeout = traversalStallTimeout
        self.consumerStallTimeout = consumerStallTimeout
        self.watchdogInterval = watchdogInterval
    }

    /// Seconds the scan has been stalled, or nil while healthy. Time spent
    /// waiting for the consumer is not a traversal stall; it only counts
    /// against the much longer consumer timeout.
    static func stalledDuration(
        _ snapshot: ScanTraversalState.Snapshot,
        now: TimeInterval,
        traversalStallTimeout: TimeInterval,
        consumerStallTimeout: TimeInterval
    ) -> TimeInterval? {
        if let waitStartedAt = snapshot.consumerWaitStartedAt {
            let waited = now - waitStartedAt
            return waited >= consumerStallTimeout ? waited : nil
        }
        let stalledFor = now - snapshot.lastProgressAt
        return stalledFor >= traversalStallTimeout ? stalledFor : nil
    }

    static func diskUsageBytes(for fileStat: stat) -> Int64 {
        Int64(fileStat.st_blocks) * Int64(DEV_BSIZE)
    }

    // MARK: - Public API

    /// Recursively scans a directory and streams results via AsyncThrowingStream
    ///
    /// - Parameters:
    ///   - rootURL: The root URL to begin scanning from
    ///   - ignoredNames: Directory names to skip
    ///   - cancellationToken: Optional cooperative cancel signal
    ///   - backpressure: Optional gate limiting outstanding unconsumed results
    ///   - skipLog: Optional record of entries skipped for lack of access
    /// - Returns: An AsyncThrowingStream that yields ScanResult values
    func scan(
        _ rootURL: URL,
        ignoredNames: Set<String>,
        cancellationToken: ScanCancellationToken? = nil,
        backpressure: ScanBackpressureGate? = nil,
        skipLog: ScanSkipLog? = nil
    ) -> AsyncThrowingStream<ScanResult, Error> {
        return AsyncThrowingStream<ScanResult, Error> { continuation in
            let traversalState = ScanTraversalState(rootPath: rootURL.path)
            let traversalStallTimeout = self.traversalStallTimeout
            let consumerStallTimeout = self.consumerStallTimeout
            let watchdogInterval = self.watchdogInterval
            let watchdogTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(watchdogInterval))
                    guard !Task.isCancelled else { return }

                    let snapshot = traversalState.snapshot()
                    guard !snapshot.isFinished else { return }

                    guard let stalledFor = Self.stalledDuration(
                        snapshot,
                        now: traversalState.now(),
                        traversalStallTimeout: traversalStallTimeout,
                        consumerStallTimeout: consumerStallTimeout
                    ) else { continue }

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

                var rootStat = stat()
                guard stat(rootURL.path, &rootStat) == 0 else {
                    await backpressure?.close()
                    continuation.finish(throwing: ScanError.invalidPath)
                    return
                }
                let rootDevice = rootStat.st_dev

                var count = 0
                var lastLogCount = 0
                let logInterval = 5000
                let normalizedIgnoredNames = ScanSkipRules.normalizedIgnoredNames(ignoredNames)
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
                        if level > 0 && ScanSkipRules.shouldSkipDirectory(
                            path: URL(fileURLWithPath: path).standardizedFileURL.path,
                            ignoredNames: normalizedIgnoredNames
                        ) {
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
                            subcategory: subcategory,
                            fileDates: FileDates(stat)
                        )
                        if let backpressure {
                            traversalState.beginConsumerWait()
                            let granted = await backpressure.waitToProduce()
                            traversalState.endConsumerWait()
                            guard granted else {
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

                        if Self.skipsUnreadableEntry(ftsErrno: entryErrno, level: level) {
                            skipLog?.record(path)
                            continue
                        }

                        if let abortError = Self.abortError(forFTSErrno: entryErrno, path: path, level: level) {
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

                if !Task.isCancelled, cancellationToken?.isCancelled != true,
                   !Self.rootIsUnchanged(path: rootPath, device: rootDevice) {
                    Self.logger.error("Scan root vanished or changed device during scan: \(rootPath, privacy: .public)")
                    await backpressure?.close()
                    continuation.finish(throwing: ScanError.invalidPath)
                    return
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

    /// Folders and files below the root that the system will not let us read
    /// are skipped and logged; the scan goes on without them.
    static func skipsUnreadableEntry(ftsErrno entryErrno: Int32, level: Int) -> Bool {
        level > 0 && (entryErrno == EACCES || entryErrno == EPERM)
    }

    /// Transient failures (vanished/stale nodes) below the root continue the scan.
    /// A failing scan root and other systematic errors abort so inventories stay trustworthy.
    static func abortError(forFTSErrno entryErrno: Int32, path: String, level: Int) -> ScanError? {
        switch entryErrno {
        case ENOENT, ESTALE:
            return level == 0 ? .invalidPath : nil
        case EACCES, EPERM:
            return .permissionDenied(path)
        default:
            return .traversalFailed(path)
        }
    }

    static func rootIsUnchanged(path: String, device: dev_t) -> Bool {
        var current = stat()
        return stat(path, &current) == 0 && current.st_dev == device
    }
}

enum ScanSkipRules {
    private static let internalPathFragments: [String] = [
        "/.build/derivedData/"
    ]

    private static let iCloudPathFragments: [String] = [
        "/Library/Mobile Documents/",
        "/.icloud/",
        "/com~apple~"
    ]

    static func normalizedIgnoredNames(_ names: Set<String>) -> Set<String> {
        Set(names.map { $0.lowercased() })
    }

    static func shouldSkipDirectory(path standardizedPath: String, ignoredNames: Set<String>) -> Bool {
        let lowercasedName = (standardizedPath as NSString).lastPathComponent.lowercased()

        if ignoredNames.contains(lowercasedName) {
            return true
        }

        if PrunrInternalPaths.isInternalPath(standardizedPath) {
            return true
        }

        for fragment in internalPathFragments where standardizedPath.contains(fragment) {
            return true
        }

        for fragment in iCloudPathFragments where standardizedPath.contains(fragment) {
            return true
        }

        return shouldSkipProblematicDirectory(path: standardizedPath, lowercasedName: lowercasedName)
    }

    static func shouldSkip(
        path standardizedPath: String,
        isDirectory: Bool,
        belowRoot standardizedRoot: String,
        ignoredNames: Set<String>
    ) -> Bool {
        if PrunrInternalPaths.isInternalPath(standardizedPath) {
            return true
        }
        for fragment in internalPathFragments where standardizedPath.contains(fragment) {
            return true
        }

        let rootPrefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
        guard standardizedPath.hasPrefix(rootPrefix) else { return false }

        let components = standardizedPath.dropFirst(rootPrefix.count).split(separator: "/")
        var current = String(rootPrefix.dropLast())
        for (index, component) in components.enumerated() {
            current += "/" + component
            let isLeaf = index == components.count - 1
            if isLeaf && !isDirectory { break }
            if shouldSkipDirectory(path: current, ignoredNames: ignoredNames) {
                return true
            }
        }
        return false
    }

    private static func shouldSkipProblematicDirectory(path: String, lowercasedName: String) -> Bool {
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
