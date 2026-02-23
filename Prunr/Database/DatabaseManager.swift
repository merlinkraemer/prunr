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

            // Index for faster lookups by snapshot (for delta calculations)
            try db.create(index: "idx_snapshotEntry_snapshotId", on: "snapshotEntry", columns: ["snapshotId"])

            // Index for faster path lookups (for drill-down operations)
            try db.create(index: "idx_snapshotEntry_path", on: "snapshotEntry", columns: ["path"])
        }

        // Migration v2: Add trackedPathId to snapshot table
        migrator.registerMigration("v2_add_tracked_path_id") { db in
            // Add trackedPathId column (nullable for existing rows)
            try db.alter(table: "snapshot") { t in
                t.add(column: "trackedPathId", .text).defaults(to: "")
            }

            // Create index for faster lookups by trackedPathId
            try db.create(index: "idx_snapshot_trackedPathId", on: "snapshot", columns: ["trackedPathId"])
        }

        // Migration v3: Add index on path column for faster queries
        migrator.registerMigration("v3_add_path_index") { db in
            // Check if index already exists (for databases created after v1)
            try? db.create(index: "idx_snapshotEntry_path", on: "snapshotEntry", columns: ["path"])
        }

        // Migration v4: Add composite index for delta query optimization
        migrator.registerMigration("v4_add_composite_index") { db in
            // Composite index on (snapshotId, path) speeds up calculateDeltas query
            // which joins on both columns (lines 256-284)
            try db.create(index: "idx_snapshotEntry_snapshotId_path", on: "snapshotEntry", columns: ["snapshotId", "path"])
        }

        // Migration v5: Drop redundant path index to save space
        // The composite index (snapshotId, path) is sufficient for our queries
        migrator.registerMigration("v5_drop_redundant_path_index") { db in
            // Drop the standalone path index which was taking ~286MB
            // The composite index covers our query patterns:
            // - calculateDeltas uses: WHERE snapshotId = ? AND path matching
            // - fetchEntries uses: WHERE snapshotId = ? ORDER BY path
            try db.drop(index: "idx_snapshotEntry_path")
        }

        // Migration v6: Add NOCASE composite index for delta joins
        migrator.registerMigration("v6_add_nocase_delta_index") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_snapshotEntry_snapshotId_path_nocase
                ON snapshotEntry(snapshotId, path COLLATE NOCASE)
                """)
        }

        try migrator.migrate(dbPool)
    }
}

// MARK: - Snapshot CRUD

extension DatabaseManager {

    /// Creates a new snapshot with the current timestamp for a specific path
    /// - Parameter trackedPathId: The ID of the TrackedPath this snapshot belongs to
    /// - Returns: The inserted Snapshot with populated id
    func createSnapshot(trackedPathId: UUID) async throws -> Snapshot {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.write { db in
            var snapshot = Snapshot(trackedPathId: trackedPathId, createdAt: Date())
            try snapshot.insert(db)
            print("[DEBUG] Created snapshot with id: \(snapshot.id ?? 0), trackedPathId: \(snapshot.trackedPathId)")
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

        try await dbPool.write { db in
            var entry = SnapshotEntry(snapshotId: snapshotId, path: path, sizeBytes: sizeBytes)
            try entry.insert(db)
        }
    }

    /// Adds multiple entries to a snapshot using batch inserts
    /// - Parameters:
    ///   - snapshotId: The snapshot ID to add entries to
    ///   - entries: Array of ScanResult values to insert
    ///
    /// Optimized to use a single transaction for all batches for better performance
    /// Uses batch size of 5000 (increased from 2000 for better throughput)
    func addEntries(to snapshotId: Int64, entries: [ScanResult]) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let batchSize = 5000 // Increased from 2000 for better throughput

        // Use a single transaction for all batches (much faster)
        // Note: We can't call Task.yield() inside the database write block
        try await dbPool.write { db in
            // Use prepared statement to avoid repeated SQL parsing
            let statement = try db.makeStatement(
                sql: "INSERT INTO snapshotEntry (snapshotId, path, sizeBytes) VALUES (?, ?, ?)"
            )

            for startIndex in stride(from: 0, to: entries.count, by: batchSize) {
                let endIndex = min(startIndex + batchSize, entries.count)
                let batch = entries[startIndex..<endIndex]

                // Execute prepared statement for each entry
                for scanResult in batch {
                    try statement.execute(arguments: [snapshotId, scanResult.path, scanResult.sizeBytes])
                }
            }
        }
    }

    /// Fetches all snapshots ordered by creation date (newest first)
    /// - Parameter trackedPathId: Optional filter to only fetch snapshots for a specific path
    /// - Returns: Array of snapshots
    func fetchAllSnapshots(trackedPathId: UUID? = nil) async throws -> [Snapshot] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            var request = Snapshot.all()
                .order(Snapshot.Columns.createdAt.desc)

            // Filter by trackedPathId if provided
            // Also exclude snapshots with empty trackedPathId (old snapshots before migration)
            if let trackedPathId = trackedPathId {
                let pathIdString = trackedPathId.uuidString
                print("[DEBUG] Filtering snapshots by trackedPathId: \(pathIdString)")
                request = request.filter(Snapshot.Columns.trackedPathId == pathIdString)
            } else {
                // When not filtering by path, still exclude empty trackedPathId entries
                request = request.filter(Snapshot.Columns.trackedPathId != "")
            }

            let snapshots = try request.fetchAll(db)
            print("[DEBUG] Fetched \(snapshots.count) snapshots")
            for snap in snapshots {
                print("[DEBUG]   - id: \(snap.id ?? 0), trackedPathId: \(snap.trackedPathId), createdAt: \(snap.createdAt)")
            }
            return snapshots
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
            let start = Date()

            // SQLite doesn't support FULL OUTER JOIN, so we use UNION of LEFT JOINs
            // - First LEFT JOIN: all entries from 'before' snapshot with matching 'after' entries
            // - Second LEFT JOIN: entries only in 'after' snapshot (excluding matches)
            // - COLLATE NOCASE: macOS filesystem is case-insensitive
            // - COALESCE: treat NULL sizes as 0 for arithmetic
            // - Wrap in CTE to filter unchanged items after UNION
            let query = """
            WITH combined AS (
                SELECT
                    COALESCE(afterEntry.path, beforeEntry.path) as path,
                    beforeEntry.sizeBytes as oldSizeBytes,
                    afterEntry.sizeBytes as newSizeBytes,
                    COALESCE(afterEntry.sizeBytes, 0) - COALESCE(beforeEntry.sizeBytes, 0) as changeBytes
                FROM snapshotEntry AS beforeEntry INDEXED BY idx_snapshotEntry_snapshotId_path_nocase
                LEFT JOIN snapshotEntry AS afterEntry INDEXED BY idx_snapshotEntry_snapshotId_path_nocase
                    ON beforeEntry.path = afterEntry.path COLLATE NOCASE
                    AND afterEntry.snapshotId = ?
                WHERE beforeEntry.snapshotId = ?
                UNION ALL
                SELECT
                    afterEntry.path as path,
                    beforeEntry.sizeBytes as oldSizeBytes,
                    afterEntry.sizeBytes as newSizeBytes,
                    COALESCE(afterEntry.sizeBytes, 0) - COALESCE(beforeEntry.sizeBytes, 0) as changeBytes
                FROM snapshotEntry AS afterEntry INDEXED BY idx_snapshotEntry_snapshotId_path_nocase
                LEFT JOIN snapshotEntry AS beforeEntry INDEXED BY idx_snapshotEntry_snapshotId_path_nocase
                    ON afterEntry.path = beforeEntry.path COLLATE NOCASE
                    AND beforeEntry.snapshotId = ?
                WHERE afterEntry.snapshotId = ?
                    AND beforeEntry.path IS NULL
            )
            SELECT * FROM combined
            WHERE changeBytes != 0
            ORDER BY ABS(changeBytes) DESC
            """

            let deltas = try Delta.fetchAll(db, sql: query, arguments: [afterId, beforeId, beforeId, afterId])
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            print("[DatabaseManager] calculateDeltas before=\(beforeId) after=\(afterId) deltas=\(deltas.count) in \(elapsedMs)ms")

            return deltas
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
