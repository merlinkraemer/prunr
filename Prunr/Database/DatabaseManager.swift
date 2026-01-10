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

// MARK: - Snapshot CRUD

extension DatabaseManager {

    /// Creates a new snapshot with the current timestamp
    /// - Returns: The inserted Snapshot with populated id
    func createSnapshot() async throws -> Snapshot {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.write { db in
            var snapshot = Snapshot(createdAt: Date())
            try snapshot.insert(db)
            return snapshot
        }
    }

    /// Adds a single entry to a snapshot (for testing/debugging)
    /// - Parameters:
    ///   - snapshotId: The snapshot ID to add the entry to
    ///   - path: The file path
    ///   - sizeBytes: The size in bytes
    func addEntry(to snapshotId: Int64, path: String, sizeBytes: Int64) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let entry = SnapshotEntry(snapshotId: snapshotId, path: path, sizeBytes: sizeBytes)
        try await dbPool.write { db in
            try entry.insert(db)
        }
    }

    /// Adds multiple entries to a snapshot using batch transactions
    /// - Parameters:
    ///   - snapshotId: The snapshot ID to add entries to
    ///   - entries: Array of ScanResult values to insert
    ///
    /// Uses batch size of 2000 per research (sweet spot between 1000-5000)
    /// Calls Task.yield() between batches to prevent blocking
    func addEntries(to snapshotId: Int64, entries: [ScanResult]) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let batchSize = 2000

        // Process in batches
        for startIndex in stride(from: 0, to: entries.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, entries.count)
            let batch = entries[startIndex..<endIndex]

            // Convert ScanResult to SnapshotEntry and insert in transaction
            try await dbPool.write { db in
                try db.inTransaction {
                    for scanResult in batch {
                        let entry = SnapshotEntry(
                            snapshotId: snapshotId,
                            path: scanResult.path,
                            sizeBytes: scanResult.sizeBytes
                        )
                        try entry.insert(db)
                    }
                    return .commit
                }
            }

            // Yield between batches to prevent blocking
            await Task.yield()
        }
    }

    /// Fetches all snapshots ordered by creation date (newest first)
    /// - Returns: Array of all snapshots
    func fetchAllSnapshots() async throws -> [Snapshot] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            try Snapshot.all()
                .order(Snapshot.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    /// Fetches all entries for a specific snapshot ordered by path
    /// - Parameter snapshotId: The snapshot ID to fetch entries for
    /// - Returns: Array of SnapshotEntry values ordered by path ASC
    func fetchEntries(for snapshotId: Int64) async throws -> [SnapshotEntry] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            try SnapshotEntry.filter(SnapshotEntry.Columns.snapshotId == snapshotId)
                .order(SnapshotEntry.Columns.path.asc)
                .fetchAll(db)
        }
    }

    /// Deletes a snapshot and all its entries (cascade handled by schema)
    /// - Parameter id: The snapshot ID to delete
    func deleteSnapshot(id: Int64) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        try await dbPool.write { db in
            _ = try Snapshot.filter(id: id).deleteAll(db)
        }
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
