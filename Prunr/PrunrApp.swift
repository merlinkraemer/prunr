import SwiftUI
import GRDB

@main
struct PrunrApp: App {
    @FocusedValue(\.scanAction) private var scanAction
    @FocusedValue(\.refreshAction) private var refreshAction

    init() {
        // Initialize the database on app launch
        do {
            try DatabaseManager.shared.initialize()
            print("Database initialized at: \(DatabaseManager.shared.databasePath ?? "unknown")")
        } catch {
            print("Failed to initialize database: \(error)")
        }

        // ScanService.shared is now ready to use for scanning operations
    }

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .defaultSize(width: 800, height: 600)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Home Folder") {
                    scanAction?()
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Refresh Snapshots") {
                    refreshAction?()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
