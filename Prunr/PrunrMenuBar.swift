import SwiftUI
import AppKit

@main
struct PrunrMenuBar: App {
    @State private var menuBarManager = MenuBarManager()

    init() {
        // Initialize database on app launch
        do {
            try DatabaseManager.shared.initialize()
            print("Database initialized at: \(DatabaseManager.shared.databasePath ?? "unknown")")
        } catch {
            print("Failed to initialize database: \(error)")
        }
    }

    var body: some Scene {
        // Empty scene - we don't want any windows
        // NSStatusItem is managed by MenuBarManager
        Settings {
            Text("Settings coming in Phase 5")
        }
    }
}
