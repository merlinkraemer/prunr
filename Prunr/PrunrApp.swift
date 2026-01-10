import SwiftUI
import GRDB

@main
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
            ContentView()
        }
    }
}
