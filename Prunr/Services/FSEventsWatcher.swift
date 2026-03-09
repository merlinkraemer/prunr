import Foundation
import CoreServices

/// Actor that manages FSEventStream for file system monitoring with debounced change detection.
///
/// FSEventsWatcher wraps the low-level FSEventStream API from CoreServices,
/// providing a Swift-async interface with configurable debouncing to prevent
/// spamming callbacks when multiple rapid changes occur.
actor FSEventsWatcher {

    // MARK: - Types

    /// Opaque pointer to FSEventStream from CoreServices.
    private typealias FSEventStreamRef = OpaquePointer

    // MARK: - Properties

    /// The underlying FSEventStream, if created and started.
    private var stream: FSEventStreamRef?

    /// Current debounce task for pending changes.
    private var debounceTask: Task<Void, Never>?

    /// Paths accumulated since the debounce window started.
    private var pendingPaths = Set<URL>()

    /// Debounce interval in seconds (default: 3.0)
    private let debounceInterval: TimeInterval

    /// Callback invoked when debounced changes are detected.
    private var onChange: ((Set<URL>) -> Void)?

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
    ///   - debounceInterval: Seconds to wait before invoking onChange (default: 1.0 for near-realtime)
    init(pathsToWatch: [URL], debounceInterval: TimeInterval = 1.0) {
        self.pathsToWatch = pathsToWatch
        self.debounceInterval = debounceInterval
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
        let contextPtr = Unmanaged.passRetained(self as AnyObject).toOpaque()
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
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

        // Create the event stream
        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (streamRef, clientCallbackInfo, numEvents, eventPaths, eventFlags, eventIds) in
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

                // Trigger debounced handling
                Task {
                    await watcher.handleEventPaths(changedPaths, requiresFullRescan: requiresFullRescan)
                }
            },
            &context,
            paths as CFArray,
            UInt64(kFSEventStreamEventIdSinceNow),
            0.5,
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
        // Cancel any pending debounce task
        debounceTask?.cancel()
        debounceTask = nil
        pendingPaths.removeAll()

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
    /// The callback is invoked after the debounce interval elapses without
    /// additional events, providing a set of changed paths.
    ///
    /// - Parameter callback: Closure taking a Set<URL> of changed paths
    func setOnChange(_ callback: @escaping (Set<URL>) -> Void) {
        onChange = callback
    }

    // MARK: - Private Methods

    /// Handles event paths with debouncing.
    ///
    /// Cancels any existing debounce task and creates a new one that will
    /// invoke the onChange callback after the debounce interval.
    ///
    /// - Parameters:
    ///   - paths: Set of URLs that changed
    ///   - requiresFullRescan: Whether the stream reported dropped/root-change events
    private func handleEventPaths(_ paths: Set<URL>, requiresFullRescan: Bool = false) {
        guard isRunning else { return }

        pendingPaths.formUnion(paths)
        if requiresFullRescan {
            pendingPaths.formUnion(pathsToWatch.map(\.standardizedFileURL))
        }
        debounceTask?.cancel()

        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))

            // Only invoke if not cancelled
            guard !Task.isCancelled else { return }
            guard isRunning else { return }

            let pathsToDeliver = pendingPaths
            pendingPaths.removeAll()
            debounceTask = nil
            onChange?(pathsToDeliver)
        }
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
        Unmanaged<AnyObject>.fromOpaque(callbackInfoPointer).release()
    }

    deinit {
        debounceTask?.cancel()

        // Clean up stream if still running
        if let eventStream = stream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
        }

        Self.releaseCallbackInfo(callbackInfoPointer)
    }
}
