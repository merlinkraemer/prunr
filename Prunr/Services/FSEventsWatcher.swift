import Foundation
import CoreServices
import os

/// Main-actor watcher that manages FSEventStream for file system monitoring with coalesced change detection.
///
/// FSEventsWatcher wraps the low-level FSEventStream API from CoreServices,
/// providing a Swift-async interface with configurable debouncing to prevent
/// spamming callbacks when multiple rapid changes occur.
@MainActor
final class FSEventsWatcher {

    // MARK: - Types

    struct ChangeBatch: Sendable {
        /// Capped set of external file paths. Empty when the batch was classified
        /// as `dirty` or fully filtered.
        let changedPaths: Set<URL>
        /// Dropped/kernel-overflow/root-changed signal. Triggers a fallback rescan.
        let requiresFullRescan: Bool
        /// Set when the batch was too large, directory-heavy, or otherwise unsafe
        /// to enumerate path-by-path. The downstream consumer should mark the
        /// tracked root dirty for a delayed reconciliation instead.
        let dirtyReason: String?
        /// Raw event count delivered by FSEvents (pre-filter), for diagnostics.
        let rawEventCount: Int

        init(
            changedPaths: Set<URL>,
            requiresFullRescan: Bool,
            dirtyReason: String? = nil,
            rawEventCount: Int = 0
        ) {
            self.changedPaths = changedPaths
            self.requiresFullRescan = requiresFullRescan
            self.dirtyReason = dirtyReason
            self.rawEventCount = rawEventCount
        }
    }

    /// Path-count cap before the callback stops collecting paths and flags the
    /// batch as dirty. Keeps the callback's allocation profile bounded.
    private static let maxCollectedPaths = 1_024
    /// Directory-event ratio above which a batch is treated as dirty (bulk move,
    /// tree creation, etc.). Computed only when over `dirHeavyMinEvents`.
    private static let dirHeavyMinEvents = 256
    private static let dirHeavyRatio = 0.5

    /// Opaque pointer to FSEventStream from CoreServices.
    private typealias FSEventStreamRef = OpaquePointer

    // MARK: - Properties

    /// The underlying FSEventStream, if created and started.
    private var stream: FSEventStreamRef?

    /// Coalescing interval in seconds (default: 1.0).
    /// Passed through to the FSEvents stream latency so the system can coalesce
    /// callbacks before they reach the app.
    private let coalescingInterval: TimeInterval

    /// Callback invoked when coalesced changes are detected.
    private var onChange: (@MainActor (ChangeBatch) -> Void)?

    /// Paths being watched by this watcher.
    private(set) var pathsToWatch: [URL]

    /// Whether the stream is currently active.
    private(set) var isRunning = false

    /// Callback context storage - needs to be stored to keep it alive
    private var callbackContext: FSEventStreamContext?
    private var callbackInfoPointer: UnsafeMutableRawPointer?
    // MARK: - Initialization

    /// Creates a new FSEvents watcher for the given paths.
    ///
    /// - Parameters:
    ///   - pathsToWatch: Array of file URLs to monitor for changes
    ///   - coalescingInterval: Seconds to wait before invoking onChange (default: 1.0 for near-realtime)
    init(pathsToWatch: [URL], coalescingInterval: TimeInterval = 1.0) {
        self.pathsToWatch = pathsToWatch
        self.coalescingInterval = coalescingInterval
    }

    // MARK: - Lifecycle

    /// Starts monitoring the configured paths for file system events.
    ///
    /// This creates an FSEventStream, schedules it on the main queue,
    /// and begins receiving notifications for changes.
    func start() {
        guard !isRunning else { return }

        // Convert URLs to path strings for FSEvents
        let paths = pathsToWatch.map { $0.path as CFString }

        // Create context to pass `self` to the C callback.
        // Balanced by releaseCallbackInfoIfNeeded() in stop() / deinit.
        let contextPtr = Unmanaged.passRetained(self).toOpaque()
        callbackInfoPointer = contextPtr

        // Set up the callback context structure
        var context = FSEventStreamContext(
            version: 0,
            info: contextPtr,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        callbackContext = context

        // File-level events give us more reliable roots for incremental rescans.
        // NoDefer ensures events are delivered promptly even after a quiet period,
        // rather than being held until the coalescing interval expires.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer
        )

        // Create the event stream
        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (streamRef, clientCallbackInfo, numEvents, eventPaths, eventFlags, eventIds) in
                guard let info = clientCallbackInfo else { return }

                let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()

                let pathsArray = eventPaths.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
                var changedPaths = Set<URL>()
                var requiresFullRescan = false
                var dirtyReason: String?
                var dirEventCount = 0
                var filteredCount = 0

                let droppedFlags =
                    FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
                let dirFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)

                for i in 0..<numEvents {
                    let flagsForEvent = eventFlags[i]
                    if flagsForEvent & droppedFlags != 0 {
                        requiresFullRescan = true
                        if dirtyReason == nil { dirtyReason = "stream-dropped" }
                    }
                    if flagsForEvent & dirFlag != 0 {
                        dirEventCount += 1
                    }

                    // Skip path collection once a dirty reason has been set —
                    // downstream will reconcile the whole root.
                    if dirtyReason != nil { continue }

                    let pathPtr = pathsArray[i]
                    let cString = pathPtr.assumingMemoryBound(to: CChar.self)
                    guard let pathStr = String(validatingUTF8: cString) else { continue }

                    // Cheap prefix-only filter; FSEventsNoiseFilter handles names,
                    // suffixes, and Prunr-internal paths in one pass.
                    if FSEventsNoiseFilter.shouldIgnore(pathStr) {
                        filteredCount += 1
                        continue
                    }

                    if changedPaths.count >= FSEventsWatcher.maxCollectedPaths {
                        dirtyReason = "path-cap-exceeded"
                        changedPaths.removeAll(keepingCapacity: false)
                        continue
                    }

                    let url = URL(fileURLWithPath: pathStr).standardizedFileURL
                    changedPaths.insert(url)
                }

                // Late dir-heavy check: bulk-move/extract bursts arrive with many
                // directory events. Past the threshold, prefer a delayed root
                // refresh over enumerating thousands of paths.
                if dirtyReason == nil,
                   numEvents >= FSEventsWatcher.dirHeavyMinEvents,
                   Double(dirEventCount) / Double(numEvents) >= FSEventsWatcher.dirHeavyRatio {
                    dirtyReason = "directory-heavy"
                    changedPaths.removeAll(keepingCapacity: false)
                }

                let internalOnly = (filteredCount == numEvents) && dirtyReason == nil && !requiresFullRescan
                if internalOnly {
                    // Don't even hop to main if the entire batch was noise/internal.
                    return
                }

                let rawCount = numEvents
                let collectedPaths = changedPaths
                let finalDirty = dirtyReason
                let finalRescan = requiresFullRescan

                MainActor.assumeIsolated {
                    watcher.emitChangeBatch(
                        collectedPaths,
                        requiresFullRescan: finalRescan,
                        dirtyReason: finalDirty,
                        rawEventCount: rawCount
                    )
                }
            },
            &context,
            paths as CFArray,
            UInt64(kFSEventStreamEventIdSinceNow),
            coalescingInterval,
            flags
        ) else {
            releaseCallbackInfoIfNeeded()
            return
        }

        stream = newStream

        // Schedule on the MAIN queue (critical: FSEvents must be on main runloop to receive events)
        // Use dispatch queue on macOS 13+ to avoid deprecation warning
        if #available(macOS 13.0, *) {
            FSEventStreamSetDispatchQueue(newStream, DispatchQueue.main)
        } else {
            FSEventStreamScheduleWithRunLoop(newStream, CFRunLoopGetMain(), RunLoop.Mode.default.rawValue as CFString)
        }

        // Start the stream
        if FSEventStreamStart(newStream) {
            isRunning = true
        } else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            stream = nil
            releaseCallbackInfoIfNeeded()
        }
    }

    /// Stops monitoring file system events.
    ///
    /// This stops the stream, invalidates it, and cleans up resources.
    func stop() {
        guard let eventStream = stream else {
            isRunning = false
            releaseCallbackInfoIfNeeded()
            return
        }

        isRunning = false
        stream = nil

        // Stop and invalidate the stream
        FSEventStreamStop(eventStream)
        FSEventStreamInvalidate(eventStream)
        FSEventStreamRelease(eventStream)

        releaseCallbackInfoIfNeeded()
        stream = nil
    }

    // MARK: - Callback Management

    /// Sets the callback to be invoked when changes are detected.
    ///
    /// The callback is invoked after the coalescing interval elapses without
    /// additional events, providing the coalesced changed paths and whether
    /// the stream reported a dropped/root-changed condition.
    ///
    /// - Parameter callback: Closure taking a coalesced change batch
    func setOnChange(_ callback: @escaping @MainActor (ChangeBatch) -> Void) {
        onChange = callback
    }

    // MARK: - Private Methods

    /// Emits a single coalesced FSEvents callback to the app.
    private func emitChangeBatch(
        _ paths: Set<URL>,
        requiresFullRescan: Bool = false,
        dirtyReason: String? = nil,
        rawEventCount: Int = 0
    ) {
        guard isRunning else { return }
        if let dirtyReason {
            Logger.fsEvents.notice("FSEvents batch dirty: reason=\(dirtyReason, privacy: .public) raw=\(rawEventCount)")
        } else {
            Logger.fsEvents.debug("FSEvents batch: paths=\(paths.count) raw=\(rawEventCount) rescan=\(requiresFullRescan)")
        }
        onChange?(ChangeBatch(
            changedPaths: paths,
            requiresFullRescan: requiresFullRescan,
            dirtyReason: dirtyReason,
            rawEventCount: rawEventCount
        ))
    }

    // MARK: - Cleanup

    private func releaseCallbackInfoIfNeeded() {
        guard let callbackInfoPointer else { return }
        self.callbackInfoPointer = nil
        callbackContext = nil
        Self.releaseCallbackInfo(callbackInfoPointer)
    }

    private nonisolated static func releaseCallbackInfo(_ callbackInfoPointer: UnsafeMutableRawPointer?) {
        guard let callbackInfoPointer else { return }
        Unmanaged<FSEventsWatcher>.fromOpaque(callbackInfoPointer).release()
    }

    deinit {
        // Clean up stream if still running
        if let eventStream = stream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
        }

        Self.releaseCallbackInfo(callbackInfoPointer)
    }
}
