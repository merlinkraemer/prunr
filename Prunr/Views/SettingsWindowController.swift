import AppKit
import SwiftUI

/// Hosts the settings window with a native `NSToolbar` (preference style) as the
/// tab bar — the System-Settings look with large icons + labels.
///
/// We deliberately do NOT use SwiftUI's `Settings` scene: that scene creates
/// hosting views that participate in the Core Animation display cycle and caused
/// continuous idle layout passes (bug #9). Instead the app is pure AppKit and we
/// build this window on demand. The toolbar (AppKit) drives a shared
/// `SettingsSelectionModel`, and a single long-lived `NSHostingController`
/// renders the selected pane via `SettingsView`, so SwiftUI state survives tab
/// switches.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let selection = SettingsSelectionModel()

    private override init() { super.init() }

    /// Show (or focus, if already open) the settings window.
    func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(selection: selection))
        hosting.title = "Prunr Settings"

        let window = NSWindow(contentViewController: hosting)
        window.title = "Prunr Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self

        let toolbar = NSToolbar(identifier: "PrunrSettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = selection.tab.toolbarIdentifier
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        window.center()
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func showFeedback() {
        selection.tab = .troubleshooting
        window?.toolbar?.selectedItemIdentifier = SettingsTab.troubleshooting.toolbarIdentifier
        show()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .focusFeedback, object: nil)
        }
    }

    @objc private func selectTab(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab.from(toolbarIdentifier: sender.itemIdentifier) else { return }
        selection.tab = tab
        window?.toolbar?.selectedItemIdentifier = tab.toolbarIdentifier
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Drop the reference so the next open builds a fresh window.
        window = nil
    }

    // MARK: - NSToolbarDelegate

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = SettingsTab.from(toolbarIdentifier: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(selectTab(_:))
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}
