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

    /// Baseline service for growth tracking
    private let baselineService = BaselineService.shared

    /// Right-click menu
    private var contextMenu: NSMenu?

    init() {
        setupMenuBar()
        setupContextMenu()
        updateFreeSpace()
        startWatchingDefaultPaths()
    }

    private func setupMenuBar() {
        // Create status item in menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.action = #selector(handleButtonClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Configure popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 420)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: MenuBarView())
    }

    private func setupContextMenu() {
        let menu = NSMenu()

        // Settings...
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Reset Baseline
        let resetItem = NSMenuItem(
            title: "Reset Baseline",
            action: #selector(resetBaseline),
            keyEquivalent: "r"
        )
        resetItem.target = self
        menu.addItem(resetItem)

        // Separator
        menu.addItem(NSMenuItem.separator())

        // Quit Prunr
        let quitItem = NSMenuItem(
            title: "Quit Prunr",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        contextMenu = menu
    }

    @objc private func handleButtonClick() {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        // Right-click shows menu, left-click shows popover
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        guard let menu = contextMenu, let button = statusItem?.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func openSettings() {
        // Close popover if open
        popover?.performClose(nil)
        isPopoverShown = false
        
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)

        // Bring Settings window to front (works even if already open)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            if let settingsWindow = NSApp.windows.first(where: { $0.title.contains("Settings") }) {
                settingsWindow.makeKeyAndOrderFront(nil)
            }
        }
    }


    @objc private func resetBaseline() {
        Task {
            do {
                try await baselineService.resetBaseline()
                updateFreeSpace()
            } catch {
                print("[MenuBarManager] Failed to reset baseline: \(error)")
            }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
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
        let freeBytes = DiskSpaceService.shared.getFreeSpace()
        let gb = Double(freeBytes) / 1_000_000_000

        if gb >= 1000 {
            let tb = gb / 1000
            updateFreeSpaceDisplay("\(String(format: "%.1f", tb)) TB")
        } else {
            updateFreeSpaceDisplay("\(String(format: "%.1f", gb)) GB")
        }
    }

    func updateFreeSpaceDisplay(_ freeSpace: String) {
        statusItem?.button?.title = freeSpace
    }

    // MARK: - FSEvents Integration

    /// Starts watching default tracked paths for file system changes.
    private func startWatchingDefaultPaths() {
        let urls = TrackedPath.defaultPaths.map { $0.url }

        // Set up callback to detect changes under tracked paths
        fseventsService.onChangedPaths = { [weak self] changedPaths in
            guard let self else { return }

            // Only rescan if we have a baseline
            Task {
                if await self.baselineService.hasBaseline() {
                    let trackedPaths = TrackedPath.defaultPaths

                    for changedPath in changedPaths {
                        for trackedPath in trackedPaths {
                            if changedPath.path.hasPrefix(trackedPath.url.path) {
                                print("[MenuBarManager] Path \(changedPath.path) changed under \(trackedPath.displayName)")
                                // Phase 4 will trigger targeted rescan and update UI
                            }
                        }
                    }
                }
            }
        }

        // Start watching asynchronously
        Task {
            await fseventsService.startWatching(paths: urls)
        }
    }
}
