import AppKit
import SwiftUI

/// Hosts the settings window with a native `NSToolbar` (preference style) as the
/// tab bar. SwiftUI's `Settings` scene is avoided because its hosting views
/// caused continuous idle layout passes (bug #9).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let selection = SettingsSelectionModel()
    private var devModeObserver: NSObjectProtocol?

    private override init() {
        super.init()
        devModeObserver = NotificationCenter.default.addObserver(
            forName: .devModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncToolbarWithDevMode()
            }
        }
    }

    func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        if !visibleTabs.contains(selection.tab) {
            selection.tab = .general
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
        select(.feedback)
        show()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .focusFeedback, object: nil)
        }
    }

    private var visibleTabs: [SettingsTab] {
        SettingsTab.visibleTabs(devMode: DevMode.shared.isEnabled)
    }

    private func select(_ tab: SettingsTab) {
        selection.tab = tab
        window?.toolbar?.selectedItemIdentifier = tab.toolbarIdentifier
    }

    private func syncToolbarWithDevMode() {
        if !visibleTabs.contains(selection.tab) {
            select(.general)
        }
        guard let toolbar = window?.toolbar else { return }

        let wanted = visibleTabs.map(\.toolbarIdentifier)
        for index in toolbar.items.indices.reversed() where !wanted.contains(toolbar.items[index].itemIdentifier) {
            toolbar.removeItem(at: index)
        }
        for (index, identifier) in wanted.enumerated()
        where !toolbar.items.map(\.itemIdentifier).contains(identifier) {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
        toolbar.selectedItemIdentifier = selection.tab.toolbarIdentifier
    }

    @objc private func selectTab(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab.from(toolbarIdentifier: sender.itemIdentifier) else { return }
        select(tab)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
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
        visibleTabs.map(\.toolbarIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }
}
