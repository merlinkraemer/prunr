import Foundation
import CoreServices
import os

/// Actor that manages FSEventStream for file system monitoring with coalesced change detection.
///
/// FSEventsWatcher wraps the low-level FSEventStream API from CoreServices,
/// providing a Swift-async interface with configurable debouncing to prevent
/// spamming callbacks when multiple rapid changes occur.
actor FSEventsWatcher {

    // MARK: - Types

    struct ChangeBatch: Sendable {
        let changedPaths: Set<URL>
        let requiresFullRescan: Bool
    }

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
    private var onChange: ((ChangeBatch) -> Void)?

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
    /// This creates an FSEventStream, schedules it on the main run loop,
    /// and begins receiving notifications for changes.
    func start() {
        guard !isRunning else { return }

        // Convert URLs to path strings for FSEvents
        let paths = pathsToWatch.map { $0.path as CFString }

        // Create context to pass 'self' to the callback
        // Use passRetained to keep self alive for the lifetime of the stream.
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
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot
        )

        // Create the event stream
        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (streamRef, clientCallbackInfo, numEvents, eventPaths, eventFlags, eventIds) in
                Logger.fsEvents.debug("FSEvents callback: \(numEvents) events, fullRescan checking")
                // Extract the watcher instance from context
                guard let info = clientCallbackInfo else { return }

                let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()

                // Collect changed paths - need to do this synchronously from callback
                // FSEvents passes char** (array of C string pointers), not CFString*
                let pathsArray = eventPaths.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
                var changedPaths = Set<URL>()

                var requiresFullRescan = false

                for i in 0..<numEvents {
                    let pathPtr = pathsArray[i]
                    // Treat as C string pointer (char*)
                    let cString = pathPtr.assumingMemoryBound(to: CChar.self)
                    if let pathStr = String(validatingUTF8: cString) {
                        let url = URL(fileURLWithPath: pathStr).standardizedFileURL
                        changedPaths.insert(url)
                    }

                    let flags = eventFlags[i]
                    let droppedFlags =
                        FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
                    if flags & droppedFlags != 0 {
                        requiresFullRescan = true
                    }
                }

                // Trigger coalesced handling
                Task {
                    await watcher.emitChangeBatch(changedPaths, requiresFullRescan: requiresFullRescan)
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
    func setOnChange(_ callback: @escaping (ChangeBatch) -> Void) {
        onChange = callback
    }

    // MARK: - Private Methods

    /// Emits a single coalesced FSEvents callback to the app.
    ///
    /// - Parameters:
    ///   - paths: Set of URLs that changed
    ///   - requiresFullRescan: Whether the stream reported dropped/root-change events
    private func emitChangeBatch(_ paths: Set<URL>, requiresFullRescan: Bool = false) {
        guard isRunning else { return }
        let running = isRunning
        Logger.fsEvents.info("emitChangeBatch: \(paths.count) paths, running=\(running)")
        onChange?(ChangeBatch(changedPaths: paths, requiresFullRescan: requiresFullRescan))
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
