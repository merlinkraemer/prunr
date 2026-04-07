import SwiftUI
import AppKit
import Darwin

@main
struct PrunrMenuBar: App {
    @MainActor
    private let menuBarManager: MenuBarManager

    @MainActor
    init() {
        if let exitCode = HeadlessCommandRouter.runIfNeeded(arguments: Array(CommandLine.arguments.dropFirst())) {
            Darwin.exit(exitCode)
        }

        let manager = MenuBarManager()
        menuBarManager = manager

        // Ensure app doesn't appear in Dock (menu bar-only app)
        NSApp.setActivationPolicy(.accessory)

        // Initialize database on app launch
        do {
            try DatabaseManager.shared.initialize()
            Task { @MainActor [manager] in
                await manager.configureMonitoringOnLaunch()
            }
            Task.detached(priority: .utility) {
                await DatabaseCleanupService.shared.performStartupMaintenance()
            }
        } catch {
            // Surface the error so the user sees it instead of a blank app
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Prunr could not start"
                alert.informativeText = "The database failed to initialize: \(error.localizedDescription)\n\nTry relaunching the app. If the problem persists, delete ~/Library/Application Support/Prunr and relaunch."
                alert.alertStyle = .critical
                alert.addButton(withTitle: "Quit")
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    var body: some Scene {
        // Menu bar-only app: empty window with LSUIElement=1 in Info.plist
        WindowGroup {
            EmptyView()
                .frame(width: 0, height: 0)
                .task {
                    // Hide any window that might appear
                    if let window = NSApplication.shared.windows.first {
                        window.setIsVisible(false)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 0, height: 0)

        // Settings window
        Settings {
            SettingsView()
        }
        .defaultSize(width: 400, height: 350)
    }
}
