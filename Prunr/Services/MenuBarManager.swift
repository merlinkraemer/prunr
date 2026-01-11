import AppKit
import SwiftUI

@MainActor
@Observable
final class MenuBarManager {
    private var statusItem: NSStatusItem?
    var popover: NSPopover?
    var isPopoverShown = false

    /// FSEvents service for file system monitoring
    private let fseventsService = FSEventsService.shared

    init() {
        setupMenuBar()
        updateFreeSpace()
        startWatchingDefaultPaths()
    }

    private func setupMenuBar() {
        // Create status item in menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            // Use SF Symbol for free space icon
            button.image = NSImage(systemSymbolName: "harddrive", accessibilityDescription: "Prunr")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Configure popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 240)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: MenuBarView())
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover = popover, popover.isShown {
            popover.performClose(nil)
            isPopoverShown = false
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            isPopoverShown = true
            popover?.contentViewController?.view.window?.makeKey()
        }
    }

    func updateFreeSpace() {
        let freeSpace = DiskSpaceService.shared.getFreeSpaceFormatted()
        // Simplify format (e.g., "50 GB" instead of "50.2 GB")
        let simplified = String(freeSpace.dropLast(3)) // Drop decimal
        updateFreeSpaceDisplay(simplified)
    }

    func updateFreeSpaceDisplay(_ freeSpace: String) {
        statusItem?.button?.title = " \(freeSpace)"
    }

    // MARK: - FSEvents Integration

    /// Starts watching default tracked paths for file system changes.
    private func startWatchingDefaultPaths() {
        let urls = TrackedPath.defaultPaths.map { $0.url }

        // Set up callback to log changes (full integration in Phase 3)
        fseventsService.onChangedPaths = { [weak self] changedPaths in
            print("[MenuBarManager] FSEvents detected changes in:")
            changedPaths.forEach { path in
                print("  - \(path.path)")
            }
            // Phase 3 will trigger rescans here
        }

        // Start watching asynchronously
        Task {
            await fseventsService.startWatching(paths: urls)
        }
    }
}
