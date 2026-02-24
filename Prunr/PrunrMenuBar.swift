import SwiftUI
import AppKit

@main
struct PrunrMenuBar: App {
    @MainActor
    private let menuBarManager = MenuBarManager()

    init() {
        // Ensure app doesn't appear in Dock (menu bar-only app)
        NSApp.setActivationPolicy(.accessory)

        // Initialize database on app launch
        do {
            try DatabaseManager.shared.initialize()
            print("Database initialized at: \(DatabaseManager.shared.databasePath ?? "unknown")")
        } catch {
            print("Failed to initialize database: \(error)")
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
