import SwiftUI
import GRDB

@main
struct PrunrApp: App {
    @FocusedValue(\.scanAction) private var scanAction
    @FocusedValue(\.refreshAction) private var refreshAction

    #if DEBUG
    @FocusedValue(\.generateTestDataAction) private var generateTestDataAction
    #endif

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
                .frame(minWidth: 600, minHeight: 400)
        }
        .defaultSize(width: 800, height: 600)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Test Folder") {
                    scanAction?()
                }
                .keyboardShortcut("r", modifiers: .command)

                #if DEBUG
                Divider()

                Button("Generate Test Data") {
                    generateTestDataAction?()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                #endif
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
