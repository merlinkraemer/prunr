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

        var entry = SnapshotEntry(snapshotId: snapshotId, path: path, sizeBytes: sizeBytes)
        try await dbPool.write { db in
            try entry.insert(db)
        }
    }

    /// Adds multiple entries to a snapshot using batch inserts
    /// - Parameters:
    ///   - snapshotId: The snapshot ID to add entries to
    ///   - entries: Array of ScanResult values to insert
    ///
    /// Uses batch size of 2000 per research (sweet spot between 1000-5000)
    /// Note: dbPool.write already runs in a transaction, no need for inTransaction
    func addEntries(to snapshotId: Int64, entries: [ScanResult]) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let batchSize = 2000

        // Process in batches
        for startIndex in stride(from: 0, to: entries.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, entries.count)
            let batch = entries[startIndex..<endIndex]

            // Convert ScanResult to SnapshotEntry and insert
            // dbPool.write already provides transaction context
            try await dbPool.write { db in
                for scanResult in batch {
                    var entry = SnapshotEntry(
                        snapshotId: snapshotId,
                        path: scanResult.path,
                        sizeBytes: scanResult.sizeBytes
                    )
                    try entry.insert(db)
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

// MARK: - Delta Calculation

extension DatabaseManager {

    /// Calculates deltas between two snapshots using SQL FULL OUTER JOIN
    ///
    /// Returns paths that changed in size between the two snapshots, sorted by
    /// absolute change magnitude (largest changes first). Unchanged paths are
    /// filtered out at the SQL level for performance.
    ///
    /// - Parameters:
    ///   - beforeId: The earlier snapshot ID
    ///   - afterId: The later snapshot ID
    /// - Returns: Array of Deltas sorted by |changeBytes| descending
    /// - Throws: DatabaseError.notInitialized if database not ready
    func calculateDeltas(beforeId: Int64, afterId: Int64) async throws -> [Delta] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            // SQLite doesn't support FULL OUTER JOIN, so we use UNION of LEFT JOINs
            // - First LEFT JOIN: all entries from 'before' snapshot with matching 'after' entries
            // - Second LEFT JOIN: entries only in 'after' snapshot (excluding matches)
            // - COLLATE NOCASE: macOS filesystem is case-insensitive
            // - COALESCE: treat NULL sizes as 0 for arithmetic
            // - Wrap in CTE to filter unchanged items after UNION
            let query = """
            WITH combined AS (
                SELECT
                    COALESCE(after.path, before.path) as path,
                    before.sizeBytes as oldSizeBytes,
                    after.sizeBytes as newSizeBytes,
                    COALESCE(after.sizeBytes, 0) - COALESCE(before.sizeBytes, 0) as changeBytes
                FROM snapshotEntry before
                LEFT JOIN snapshotEntry after
                    ON before.path = after.path COLLATE NOCASE
                    AND after.snapshotId = ?
                WHERE before.snapshotId = ?
                UNION
                SELECT
                    after.path as path,
                    before.sizeBytes as oldSizeBytes,
                    after.sizeBytes as newSizeBytes,
                    COALESCE(after.sizeBytes, 0) - COALESCE(before.sizeBytes, 0) as changeBytes
                FROM snapshotEntry after
                LEFT JOIN snapshotEntry before
                    ON after.path = before.path COLLATE NOCASE
                    AND before.snapshotId = ?
                WHERE after.snapshotId = ?
                    AND before.path IS NULL
            )
            SELECT * FROM combined
            WHERE changeBytes != 0
            ORDER BY ABS(changeBytes) DESC
            """
            return try Delta.fetchAll(db, sql: query, arguments: [afterId, beforeId, beforeId, afterId])
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
