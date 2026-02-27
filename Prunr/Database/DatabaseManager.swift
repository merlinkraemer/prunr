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

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbPool = try DatabasePool(path: dbPath, configuration: config)

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

        // Migration v7: Deduplicate paths into separate table
        migrator.registerMigration("v7_path_dedup") { db in
            let columns = try db.columns(in: "snapshotEntry")
            let hasPathColumn = columns.contains { $0.name.lowercased() == "path" }
            if !hasPathColumn {
                return
            }

            try db.create(table: "paths", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
            }

            try db.execute(sql: "INSERT OR IGNORE INTO paths(path) SELECT DISTINCT path FROM snapshotEntry")

            try db.create(table: "snapshotEntry_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("snapshotId", .integer)
                    .notNull()
                    .references("snapshot", onDelete: .cascade)
                t.column("pathId", .integer)
                    .notNull()
                    .references("paths", onDelete: .cascade)
                t.column("sizeBytes", .integer).notNull()
            }

            try db.execute(sql: """
                INSERT INTO snapshotEntry_new (id, snapshotId, pathId, sizeBytes)
                SELECT se.id, se.snapshotId, p.id, se.sizeBytes
                FROM snapshotEntry se
                JOIN paths p ON p.path = se.path
                """)

            try db.execute(sql: "DROP TABLE snapshotEntry")
            try db.execute(sql: "ALTER TABLE snapshotEntry_new RENAME TO snapshotEntry")

            try db.execute(sql: "DROP INDEX IF EXISTS idx_snapshotEntry_snapshotId_path")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_snapshotEntry_snapshotId_path_nocase")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_snapshotEntry_path")

            try db.create(index: "idx_snapshotEntry_snapshotId", on: "snapshotEntry", columns: ["snapshotId"])
            try db.create(index: "idx_snapshotEntry_snapshotId_pathId", on: "snapshotEntry", columns: ["snapshotId", "pathId"])
        }

        // Migration v8: Add freeBytes column to snapshot table
        migrator.registerMigration("v8_add_free_bytes") { db in
            try db.alter(table: "snapshot") { t in
                t.add(column: "freeBytes", .integer)
            }
        }

        // Migration v9: Clean up orphaned entries (foreign keys weren't enabled before)
        migrator.registerMigration("v9_cleanup_orphaned_entries") { db in
            // Delete entries that reference non-existent snapshots
            try db.execute(sql: """
                DELETE FROM snapshotEntry 
                WHERE snapshotId NOT IN (SELECT id FROM snapshot)
                """)
            // Run VACUUM to reclaim space
            try db.execute(sql: "VACUUM")
        }

        // Migration v10: Normalize paths and add COLLATE NOCASE for case-insensitive uniqueness
        migrator.registerMigration("v10_normalize_paths_nocase") { db in
            // Create new paths table with COLLATE NOCASE on the unique constraint
            try db.create(table: "paths_new", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique(onConflict: .ignore).collate(.nocase)
            }

            // Migrate data with normalized paths
            // Normalization: remove trailing slash (unless it's just "/")
            try db.execute(sql: """
                INSERT OR IGNORE INTO paths_new (path)
                SELECT CASE
                    WHEN path = '/' THEN path
                    ELSE RTRIM(path, '/')
                END
                FROM paths
                """)

            // Update snapshotEntry to reference new path IDs
            // First, map old path IDs to new ones
            try db.execute(sql: """
                UPDATE snapshotEntry
                SET pathId = (
                    SELECT pnew.id
                    FROM paths pold
                    JOIN paths_new pnew ON (
                        CASE
                            WHEN pold.path = '/' THEN pold.path
                            ELSE RTRIM(pold.path, '/')
                        END = pnew.path
                    )
                    WHERE pold.id = snapshotEntry.pathId
                )
                """)

            // Drop old table and rename new one
            try db.execute(sql: "DROP TABLE paths")
            try db.execute(sql: "ALTER TABLE paths_new RENAME TO paths")
        }

        // Migration v11: Add categorySnapshot table for per-category size history
        migrator.registerMigration("v11_add_category_snapshot") { db in
            // Create categorySnapshot table for aggregated category totals per snapshot
            try db.create(table: "categorySnapshot") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("snapshotId", .integer)
                    .notNull()
                    .references("snapshot", onDelete: .cascade)
                t.column("category", .text).notNull()
                t.column("totalBytes", .integer).notNull()
            }

            // Index for faster lookups by snapshotId
            try db.create(index: "idx_categorySnapshot_snapshotId", on: "categorySnapshot", columns: ["snapshotId"])
        }

        try migrator.migrate(dbPool)
    }
}

// MARK: - Snapshot CRUD

extension DatabaseManager {

    /// Creates a new snapshot with the current timestamp for a specific path
    /// - Parameters:
    ///   - trackedPathId: The ID of the TrackedPath this snapshot belongs to
    ///   - freeBytes: Optional volume free space at snapshot creation time
    /// - Returns: The inserted Snapshot with populated id
    func createSnapshot(trackedPathId: UUID, freeBytes: Int64? = nil) async throws -> Snapshot {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.write { db in
            var snapshot = Snapshot(trackedPathId: trackedPathId, createdAt: Date(), freeBytes: freeBytes)
            try snapshot.insert(db)
            print("[DEBUG] Created snapshot with id: \(snapshot.id ?? 0), trackedPathId: \(snapshot.trackedPathId), freeBytes: \(freeBytes ?? -1)")
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
            let pathId = try getOrCreatePathId(path: path, db: db)
            var entry = SnapshotEntry(snapshotId: snapshotId, pathId: pathId, sizeBytes: sizeBytes)
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
            let statement = try db.makeStatement(
                sql: "INSERT INTO snapshotEntry (snapshotId, pathId, sizeBytes) VALUES (?, ?, ?)"
            )

            for startIndex in stride(from: 0, to: entries.count, by: batchSize) {
                let endIndex = min(startIndex + batchSize, entries.count)
                let batch = entries[startIndex..<endIndex]

                let uniquePaths = Set(batch.map { $0.path })
                var pathIdByPath = try fetchPathIds(for: Array(uniquePaths), db: db)

                for scanResult in batch {
                    if let pathId = pathIdByPath[scanResult.path] {
                        try statement.execute(arguments: [snapshotId, pathId, scanResult.sizeBytes])
                    } else {
                        let pathId = try getOrCreatePathId(path: scanResult.path, db: db)
                        pathIdByPath[scanResult.path] = pathId
                        try statement.execute(arguments: [snapshotId, pathId, scanResult.sizeBytes])
                    }
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
    func fetchEntries(for snapshotId: Int64) async throws -> [SnapshotEntryWithPath] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            try SnapshotEntryWithPath.fetchAll(db, sql: """
                SELECT se.id, se.snapshotId, p.path AS path, se.sizeBytes
                FROM snapshotEntry se
                JOIN paths p ON p.id = se.pathId
                WHERE se.snapshotId = ?
                ORDER BY p.path ASC
                """, arguments: [snapshotId])
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

    /// Returns the number of entries for a given snapshot
    /// - Parameter snapshotId: The snapshot ID
    /// - Returns: Entry count
    func fetchEntryCount(for snapshotId: Int64) async throws -> Int {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM snapshotEntry WHERE snapshotId = ?", arguments: [snapshotId]) ?? 0
        }
    }

    /// Truncates the SQLite WAL file to reclaim space.
    func checkpointWalTruncate() async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        try await dbPool.write { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    // MARK: - Category Snapshot

    /// Writes a category total to the categorySnapshot table
    /// - Parameters:
    ///   - snapshotId: The snapshot ID to associate with
    ///   - category: The category name
    ///   - totalBytes: The total bytes for this category
    func writeCategorySnapshot(snapshotId: Int64, category: String, totalBytes: Int64) throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        try dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO categorySnapshot (snapshotId, category, totalBytes) VALUES (?, ?, ?)",
                arguments: [snapshotId, category, totalBytes]
            )
        }
    }

    /// Fetches category snapshot history for a tracked path
    /// - Parameters:
    ///   - trackedPathId: The tracked path ID to filter by
    ///   - limit: Maximum number of distinct snapshots to fetch (default 90)
    /// - Returns: Array of (snapshotId, createdAt, category, totalBytes) tuples
    func fetchCategorySnapshots(trackedPathId: String, limit: Int = 90) -> [(snapshotId: Int64, createdAt: Date, category: String, totalBytes: Int64)] {
        guard let dbPool = dbPool else {
            return []
        }

        do {
            return try dbPool.read { db in
                // First, get the distinct snapshot IDs limited by the number of snapshots
                let snapshotIds = try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT s.id FROM snapshot s
                        WHERE s.trackedPathId = ?
                        ORDER BY s.createdAt DESC
                        LIMIT ?
                        """,
                    arguments: [trackedPathId, limit]
                )

                guard !snapshotIds.isEmpty else {
                    return []
                }

                // Create placeholders for IN clause
                let placeholders = snapshotIds.map { _ in "?" }.joined(separator: ", ")

                // Fetch all category rows for these snapshots
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT cs.snapshotId, s.createdAt, cs.category, cs.totalBytes
                        FROM categorySnapshot cs
                        JOIN snapshot s ON s.id = cs.snapshotId
                        WHERE cs.snapshotId IN (\(placeholders))
                        ORDER BY s.createdAt DESC, cs.category
                        """,
                    arguments: StatementArguments(snapshotIds)
                )

                var result: [(snapshotId: Int64, createdAt: Date, category: String, totalBytes: Int64)] = []
                for row in rows {
                    let snapshotId: Int64 = row["snapshotId"] ?? Int64(0)
                    let createdAt: Date = row["createdAt"] ?? Date()
                    let category: String = row["category"] ?? ""
                    let totalBytes: Int64 = row["totalBytes"] ?? Int64(0)
                    result.append((snapshotId: snapshotId, createdAt: createdAt, category: category, totalBytes: totalBytes))
                }
                return result
            }
        } catch {
            print("[DatabaseManager] Error fetching category snapshots: \(error)")
            return []
        }
    }

    /// Normalizes a file path for consistent storage
    /// - Removes trailing slash (unless it's just "/")
    /// - Note: Case is preserved as-is; COLLATE NOCASE handles case-insensitive comparison
    private static func normalizePath(_ path: String) -> String {
        if path == "/" {
            return path
        }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func getOrCreatePathId(path: String, db: Database) throws -> Int64 {
        let normalizedPath = Self.normalizePath(path)
        try db.execute(sql: "INSERT OR IGNORE INTO paths (path) VALUES (?)", arguments: [normalizedPath])
        // Use COLLATE NOCASE for lookup to match the table's unique constraint
        if let row = try Row.fetchOne(db, sql: "SELECT id FROM paths WHERE path = ? COLLATE NOCASE", arguments: [normalizedPath]),
           let id: Int64 = row["id"] {
            return id
        }
        throw DatabaseError.notInitialized
    }

    private func fetchPathIds(for paths: [String], db: Database) throws -> [String: Int64] {
        guard !paths.isEmpty else { return [:] }

        // Normalize all paths before insertion
        let normalizedPaths = paths.map { Self.normalizePath($0) }

        for normalizedPath in normalizedPaths {
            try db.execute(sql: "INSERT OR IGNORE INTO paths (path) VALUES (?)", arguments: [normalizedPath])
        }

        let placeholders = Array(repeating: "?", count: normalizedPaths.count).joined(separator: ", ")
        // Use COLLATE NOCASE for lookup to match the table's unique constraint
        let sql = "SELECT id, path FROM paths WHERE path IN (\(placeholders)) COLLATE NOCASE"
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(normalizedPaths))

        var result: [String: Int64] = [:]
        for row in rows {
            if let path: String = row["path"],
               let id: Int64 = row["id"] {
                result[path] = id
            }
        }
        return result
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
                    COALESCE(pAfter.path, pBefore.path) as path,
                    beforeEntry.sizeBytes as oldSizeBytes,
                    afterEntry.sizeBytes as newSizeBytes,
                    COALESCE(afterEntry.sizeBytes, 0) - COALESCE(beforeEntry.sizeBytes, 0) as changeBytes
                FROM snapshotEntry AS beforeEntry INDEXED BY idx_snapshotEntry_snapshotId_pathId
                JOIN paths pBefore ON pBefore.id = beforeEntry.pathId
                LEFT JOIN snapshotEntry AS afterEntry INDEXED BY idx_snapshotEntry_snapshotId_pathId
                    ON beforeEntry.pathId = afterEntry.pathId
                    AND afterEntry.snapshotId = ?
                LEFT JOIN paths pAfter ON pAfter.id = afterEntry.pathId
                WHERE beforeEntry.snapshotId = ?
                UNION ALL
                SELECT
                    pAfter.path as path,
                    beforeEntry.sizeBytes as oldSizeBytes,
                    afterEntry.sizeBytes as newSizeBytes,
                    COALESCE(afterEntry.sizeBytes, 0) - COALESCE(beforeEntry.sizeBytes, 0) as changeBytes
                FROM snapshotEntry AS afterEntry INDEXED BY idx_snapshotEntry_snapshotId_pathId
                JOIN paths pAfter ON pAfter.id = afterEntry.pathId
                LEFT JOIN snapshotEntry AS beforeEntry INDEXED BY idx_snapshotEntry_snapshotId_pathId
                    ON afterEntry.pathId = beforeEntry.pathId
                    AND beforeEntry.snapshotId = ?
                WHERE afterEntry.snapshotId = ?
                    AND beforeEntry.pathId IS NULL
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
