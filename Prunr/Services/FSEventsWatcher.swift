import Foundation
import CoreServices

/// Actor that manages FSEventStream for file system monitoring with debounced change detection.
///
/// FSEventsWatcher wraps the low-level FSEventStream API from CoreServices,
/// providing a Swift-async interface with configurable debouncing to prevent
/// spamming callbacks when multiple rapid changes occur.
actor FSEventsWatcher {

    // MARK: - Types

    /// Wrapper around FSEventStream for type-safe management.
    ///
    /// The actual FSEventStreamRef is opaque from CoreServices, so we use
    /// a typealias for clarity and unsafe pointer operations.
    private typealias FSEventStream = OpaquePointer

    // MARK: - Properties

    /// The underlying FSEventStream, if created and started.
    private var stream: FSEventStream?

    /// Current debounce task for pending changes.
    private var debounceTask: Task<Void, Never>?

    /// Debounce interval in seconds (default: 3.0)
    private let debounceInterval: TimeInterval

    /// Callback invoked when debounced changes are detected.
    private var onChange: ((Set<URL>) -> Void)?

    /// Paths being watched by this watcher.
    private(set) var pathsToWatch: [URL]

    /// Whether the stream is currently active.
    private(set) var isRunning = false

    // MARK: - Initialization

    /// Creates a new FSEvents watcher for the given paths.
    ///
    /// - Parameters:
    ///   - pathsToWatch: Array of file URLs to monitor for changes
    ///   - debounceInterval: Seconds to wait before invoking onChange (default: 3.0)
    init(pathsToWatch: [URL], debounceInterval: TimeInterval = 3.0) {
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
        let paths = pathsToWatch.map { $0.path }

        // Create context for callback
        let context = Unmanaged.passRetained(self as AnyObject).toOpaque()

        // Create the event stream
        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (streamRef, clientCallbackInfo, numEvents, eventPaths, eventFlags, eventIds) in
                // Extract the watcher instance from context
                guard let clientCallbackInfo = clientCallbackInfo else { return }

                        let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(clientCallbackInfo).takeUnretainedValue()

                // Collect changed paths from the event
                        watcher.collectEventPaths(eventPaths, count: numEvents)
            },
            nil,
            paths as CFArray,
            kFSEventStreamEventIdSinceNow,
            0.5, // Latency in seconds - FSEvents batches events within this window
            FSEventStreamCreateFlags(kFSEventStreamEventIdSinceNow.rawValue)
        ) else {
            print("[FSEventsWatcher] Failed to create FSEventStream")
            return
        }

        stream = newStream

        // Schedule on the current run loop
        FSEventStreamScheduleWithRunLoop(newStream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultModes.rawValue)

        // Start the stream
        if FSEventStreamStart(newStream) {
            isRunning = true
            print("[FSEventsWatcher] Started monitoring \(paths.count) paths")
        } else {
            print("[FSEventsWatcher] Failed to start FSEventStream")
            FSEventStreamInvalidate(newStream)
            stream = nil
        }
    }

    /// Stops monitoring file system events.
    ///
    /// This stops the stream, invalidates it, and cleans up resources.
    func stop() {
        guard isRunning, let eventStream = stream else { return }

        // Cancel any pending debounce task
        debounceTask?.cancel()
        debounceTask = nil

        // Stop and invalidate the stream
        FSEventStreamStop(eventStream)
        FSEventStreamInvalidate(eventStream)

        stream = nil
        isRunning = false

        print("[FSEventsWatcher] Stopped monitoring")
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

    /// Collects event paths from FSEvents callback and triggers debounced handling.
    ///
    /// This is called from the C callback context and must be thread-safe.
    /// We accumulate changed paths and trigger debounced notification.
    ///
    /// - Parameters:
    ///   - eventPaths: Raw pointer to C array of path strings
    ///   - count: Number of paths in the array
    private func collectEventPaths(_ eventPaths: UnsafePointer<Unmanaged<CFString>?>, count: Int) {
        var changedPaths = Set<URL>()

        for i in 0..<count {
            if let pathRef = eventPaths[i].takeUnretainedValue() as String? {
                let url = URL(fileURLWithPath: pathRef)
                changedPaths.insert(url)
            }
        }

        // Trigger debounced handling of these paths
        Task {
            await handleEventPaths(changedPaths)
        }
    }

    /// Handles event paths with debouncing.
    ///
    /// Cancels any existing debounce task and creates a new one that will
    /// invoke the onChange callback after the debounce interval.
    ///
    /// - Parameter paths: Set of URLs that changed
    private func handleEventPaths(_ paths: Set<URL>) {
        // Cancel existing task
        debounceTask?.cancel()

        // Create new debounced task
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))

            // Only invoke if not cancelled
            guard !Task.isCancelled else { return }

            await onChange?(paths)
        }
    }

    // MARK: - Cleanup

    deinit {
        // Clean up stream if still running
        if isRunning, let eventStream = stream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
        }
    }
}
