import Foundation
import GRDB

/// Manages the SQLite database connection and migrations
final class DatabaseManager {
    /// Shared singleton instance
    static let shared = DatabaseManager()

    /// The database connection pool
    private(set) var dbPool: DatabasePool?

    /// The path to the database file
    private(set) var databasePath: String?

    private init() {}

    /// Initialize the database at the standard Application Support location
    /// Creates the directory and database file if they don't exist
    func initialize() throws {
        let fileManager = FileManager.default

        // Get Application Support directory
        guard let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw DatabaseError.directoryNotFound
        }

        // Create Prunr subdirectory
        let prunrDirectory = appSupportURL.appendingPathComponent("Prunr", isDirectory: true)
        try fileManager.createDirectory(at: prunrDirectory, withIntermediateDirectories: true)

        // Database file path
        let dbPath = prunrDirectory.appendingPathComponent("prunr.db").path
        self.databasePath = dbPath

        // Open/create the database
        dbPool = try DatabasePool(path: dbPath)

        // Run migrations
        try runMigrations()
    }

    /// Run database migrations using GRDB's DatabaseMigrator
    private func runMigrations() throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        var migrator = DatabaseMigrator()

        // Migration v1: Create initial schema
        migrator.registerMigration("v1_initial_schema") { db in
            // Create snapshot table
            try db.create(table: "snapshot") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull()
            }

            // Create snapshotEntry table
            try db.create(table: "snapshotEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("snapshotId", .integer)
                    .notNull()
                    .references("snapshot", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("sizeBytes", .integer).notNull()
            }

            // Index for faster lookups by snapshot
            try db.create(index: "idx_snapshotEntry_snapshotId", on: "snapshotEntry", columns: ["snapshotId"])
        }

        try migrator.migrate(dbPool)
    }
}

// MARK: - Custom Errors

extension DatabaseManager {
    enum DatabaseError: Error, LocalizedError {
        case directoryNotFound
        case notInitialized

        var errorDescription: String? {
            switch self {
            case .directoryNotFound:
                return "Could not find Application Support directory"
            case .notInitialized:
                return "Database has not been initialized"
            }
        }
    }
}
