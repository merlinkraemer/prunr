import Foundation
import SwiftUI

/// Service for managing FSEventsWatcher lifecycle and change notifications.
///
/// FSEventsService provides a high-level interface for file system monitoring
/// with debounced change detection. It's observable for SwiftUI integration
/// and manages the underlying FSEventsWatcher actor.
@MainActor
@Observable
final class FSEventsService {

    // MARK: - Singleton

    static let shared = FSEventsService()

    private init() {
        // Initialize with default paths
        watchedPaths = Set(TrackedPath.defaultPaths.map { $0.url })
    }

    // MARK: - Properties

    /// The underlying FSEvents watcher actor.
    private var watcher: FSEventsWatcher?

    /// Whether file system monitoring is currently active.
    var isWatching = false

    /// Set of paths currently being watched.
    var watchedPaths: Set<URL>

    /// Pending changed paths that have been detected but not yet processed.
    private var pendingChangedPaths: Set<URL> = []

    /// Callback invoked when file system changes are detected.
    ///
    /// This is invoked after the debounce interval elapses without
    /// additional events. External handlers can use this to trigger
    /// rescans or other actions.
    var onChangedPaths: ((Set<URL>) -> Void)?

    // MARK: - Computed Properties

    /// Whether there are pending changes that haven't been retrieved.
    var hasPendingChanges: Bool {
        !pendingChangedPaths.isEmpty
    }

    // MARK: - Public API

    /// Starts watching the specified paths for file system changes.
    ///
    /// If a watcher is already running, it will be stopped first.
    /// The new watcher will monitor the provided paths and invoke
    /// onChangedPaths after the debounce interval.
    ///
    /// - Parameter paths: Array of file URLs to monitor
    func startWatching(paths: [URL]) async {
        // Stop existing watcher if running
        await stopWatching()

        guard !paths.isEmpty else {
            print("[FSEventsService] No paths to watch")
            return
        }

        // Create new watcher with 3-second debounce
        let newWatcher = FSEventsWatcher(
            pathsToWatch: paths,
            debounceInterval: 3.0
        )

        // Set up change callback
        await newWatcher.setOnChange { [weak self] changedPaths in
            Task { @MainActor in
                self?.handleChangedPaths(changedPaths)
            }
        }

        // Start the watcher
        await newWatcher.start()

        // Update state on main actor
        watcher = newWatcher
        isWatching = true
        watchedPaths = Set(paths)
        print("[FSEventsService] Started watching \(paths.count) paths:")
        paths.forEach { print("  - \($0.path)") }
    }

    /// Stops file system monitoring.
    ///
    /// The current watcher is stopped and cleaned up.
    /// Pending changed paths are cleared.
    func stopWatching() async {
        guard let currentWatcher = watcher else { return }

        await currentWatcher.stop()

        // Clear state
        watcher = nil
        isWatching = false
        watchedPaths.removeAll()
        pendingChangedPaths.removeAll()
        print("[FSEventsService] Stopped watching")
    }

    /// Retrieves and clears pending changed paths.
    ///
    /// This allows external code to consume detected changes
    /// and reset the pending state.
    ///
    /// - Returns: Set of URLs that changed since last retrieval
    func getAndClearPendingChanges() -> Set<URL> {
        let changes = pendingChangedPaths
        pendingChangedPaths.removeAll()
        return changes
    }

    // MARK: - Private Methods

    /// Handles changed paths detected by the watcher.
    ///
    /// Accumulates changes into pendingChangedPaths and invokes
    /// the onChangedPaths callback if configured.
    ///
    /// - Parameter paths: Set of URLs that changed
    private func handleChangedPaths(_ paths: Set<URL>) {
        // Accumulate into pending changes
        pendingChangedPaths.formUnion(paths)

        print("[FSEventsService] FSEvents detected changes in:")
        paths.forEach { path in
            print("  - \(path.path)")
        }

        // Notify external handler
        onChangedPaths?(paths)
    }
}
