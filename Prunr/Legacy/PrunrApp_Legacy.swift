import SwiftUI
import GRDB

// Legacy app entry point - replaced by PrunrMenuBar
// @main removed to avoid conflict with PrunrMenuBar
struct PrunrApp: App {
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
            RootView()
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 600)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Test Folder") {
                    AppActions.shared.scanAction?()
                }
                .keyboardShortcut("r", modifiers: .command)

                #if DEBUG
                Divider()

                Button("Generate Test Data") {
                    AppActions.shared.generateTestDataAction?()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                #endif
            }

            CommandGroup(after: .toolbar) {
                Button("Refresh Snapshots") {
                    AppActions.shared.refreshAction?()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
