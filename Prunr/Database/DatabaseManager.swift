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

    /// Initialize the database at the standard Application Support location.
    func initialize() throws {
        let fileManager = FileManager.default

        guard let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw DatabaseError.directoryNotFound
        }

        let dbPath = appSupportURL
            .appendingPathComponent("Prunr", isDirectory: true)
            .appendingPathComponent("prunr.db")
            .path

        try initialize(at: dbPath)
    }

    /// Initialize the database at an explicit SQLite file path.
    func initialize(at dbPath: String) throws {
        let fileManager = FileManager.default
        let dbURL = URL(fileURLWithPath: dbPath)

        if let existingPool = dbPool {
            try existingPool.close()
            dbPool = nil
        }

        try fileManager.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        databasePath = dbURL.path

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbPool = try DatabasePool(path: dbURL.path, configuration: config)
        try runMigrations()
        try clearWorkingSetRefreshStagingSynchronously()
    }

    func close() throws {
        if let dbPool {
            try dbPool.close()
            self.dbPool = nil
        }
        databasePath = nil
    }

    private func clearWorkingSetRefreshStagingSynchronously(sessionId: String? = nil) throws {
        guard let dbPool else {
            throw DatabaseError.notInitialized
        }

        try dbPool.write { db in
            try Self.clearWorkingSetRefreshStagingRows(sessionId: sessionId, db: db)
        }
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
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_snapshotEntry_path
                ON snapshotEntry(path)
                """)
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
            // Databases created after v1 already have this index.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_snapshotEntry_path
                ON snapshotEntry(path)
                """)
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
        // NOTE: VACUUM removed - it's too slow on large databases and not critical
        migrator.registerMigration("v9_cleanup_orphaned_entries") { db in
            // Delete entries that reference non-existent snapshots
            try db.execute(sql: """
                DELETE FROM snapshotEntry
                WHERE snapshotId NOT IN (SELECT id FROM snapshot)
                """)
            // VACUUM skipped - too slow on large databases (can take hours on 1GB+ DBs)
            // Space will be reclaimed naturally through normal operations
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

        // Migration v12: Reset categorySnapshot rows if legacy category names are present
        migrator.registerMigration("v12_reset_legacy_category_snapshot_names") { db in
            let validCategories = GrowthCategory.allCases.map(\.rawValue)
            let placeholders = validCategories.map { _ in "?" }.joined(separator: ", ")

            let invalidCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM categorySnapshot
                    WHERE category NOT IN (\(placeholders))
                    """,
                arguments: StatementArguments(validCategories)
            ) ?? 0

            if invalidCount > 0 {
                try db.execute(sql: "DELETE FROM categorySnapshot")
            }
        }

        // Migration v13: Cleanup any invalid categorySnapshot rows (post-refactor safety)
        migrator.registerMigration("v13_cleanup_invalid_category_snapshot_rows") { db in
            let validCategories = GrowthCategory.allCases.map(\.rawValue)
            let placeholders = validCategories.map { _ in "?" }.joined(separator: ", ")

            let invalidCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM categorySnapshot
                    WHERE category NOT IN (\(placeholders))
                    """,
                arguments: StatementArguments(validCategories)
            ) ?? 0

            if invalidCount > 0 {
                try db.execute(sql: "DELETE FROM categorySnapshot")
            }
        }

        // Migration v14: Add subcategorySnapshot table for drill-down summaries
        migrator.registerMigration("v14_add_subcategory_snapshot") { db in
            try db.create(table: "subcategorySnapshot", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("snapshotId", .integer)
                    .notNull()
                    .references("snapshot", onDelete: .cascade)
                t.column("category", .text).notNull()
                t.column("subcategory", .text).notNull().defaults(to: "")
                t.column("totalBytes", .integer).notNull()
                t.column("fileCount", .integer).notNull()
                t.column("topItemsJSON", .text).notNull()
            }

            try db.create(
                index: "idx_subcategorySnapshot_snapshotId_category",
                on: "subcategorySnapshot",
                columns: ["snapshotId", "category"]
            )
        }

        // Migration v15: Add standalone pathId index for orphan cleanup and path lookups
        migrator.registerMigration("v15_add_snapshot_entry_pathid_index") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_snapshotEntry_pathId
                ON snapshotEntry(pathId)
                """)
        }

        // Migration v16: Add working set and recent growth journal tables
        migrator.registerMigration("v16_add_working_set_and_growth_journal") { db in
            try db.create(table: "workingSetEntry", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackedPathId", .text).notNull()
                t.column("pathId", .integer)
                    .notNull()
                    .references("paths", onDelete: .cascade)
                t.column("sizeBytes", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_workingSetEntry_trackedPath_path
                ON workingSetEntry(trackedPathId, pathId)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_workingSetEntry_trackedPath
                ON workingSetEntry(trackedPathId)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_workingSetEntry_pathId
                ON workingSetEntry(pathId)
                """)

            try db.create(table: "growthJournalBucket", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackedPathId", .text).notNull()
                t.column("bucketStart", .datetime).notNull()
                t.column("category", .text).notNull()
                t.column("subcategory", .text).notNull().defaults(to: "")
                t.column("deltaBytes", .integer).notNull()
            }

            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_growthJournalBucket_identity
                ON growthJournalBucket(trackedPathId, bucketStart, category, subcategory)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_growthJournalBucket_trackedPath_time
                ON growthJournalBucket(trackedPathId, bucketStart)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_growthJournalBucket_trackedPath_category_time
                ON growthJournalBucket(trackedPathId, category, bucketStart)
                """)
        }

        // Migration v17: Add persistent path classification for SQL-side category filtering
        migrator.registerMigration("v17_add_path_classification") { db in
            try db.create(table: "pathClassification", ifNotExists: true) { t in
                t.column("pathId", .integer)
                    .notNull()
                    .primaryKey()
                    .references("paths", onDelete: .cascade)
                t.column("category", .text).notNull()
                t.column("subcategory", .text).notNull().defaults(to: "")
            }

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_pathClassification_category_subcategory_pathId
                ON pathClassification(category, subcategory, pathId)
                """)

            let upsert = try db.makeStatement(sql: """
                INSERT INTO pathClassification (pathId, category, subcategory)
                VALUES (?, ?, ?)
                ON CONFLICT(pathId) DO UPDATE SET
                    category = excluded.category,
                    subcategory = excluded.subcategory
                """)

            let rows = try Row.fetchAll(db, sql: "SELECT id, path FROM paths")
            for row in rows {
                guard
                    let pathId: Int64 = row["id"],
                    let path: String = row["path"]
                else {
                    continue
                }
                let category = GrowthCategory.categorize(path: path)
                let subcategory = GrowthCategory.subcategorize(path: path)?.rawValue ?? ""
                try upsert.execute(arguments: [pathId, category.rawValue, subcategory])
            }
        }

        // Migration v18: Add working-set category totals for live inventory reads
        migrator.registerMigration("v18_add_working_set_category_totals") { db in
            try db.create(table: "workingSetCategoryTotal", ifNotExists: true) { t in
                t.column("trackedPathId", .text).notNull()
                t.column("category", .text).notNull()
                t.column("totalBytes", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["trackedPathId", "category"])
            }

            try db.execute(sql: """
                INSERT INTO workingSetCategoryTotal (trackedPathId, category, totalBytes, updatedAt)
                SELECT
                    wse.trackedPathId,
                    pc.category,
                    COALESCE(SUM(wse.sizeBytes), 0) AS totalBytes,
                    MAX(wse.updatedAt) AS updatedAt
                FROM workingSetEntry wse
                JOIN pathClassification pc ON pc.pathId = wse.pathId
                GROUP BY wse.trackedPathId, pc.category
                HAVING totalBytes > 0
                ON CONFLICT(trackedPathId, category) DO UPDATE SET
                    totalBytes = excluded.totalBytes,
                    updatedAt = excluded.updatedAt
                """)
        }

        migrator.registerMigration("v19_add_working_set_refresh_staging") { db in
            try db.create(table: "workingSetRefreshStaging", ifNotExists: true) { t in
                t.column("sessionId", .text).notNull()
                t.column("path", .text).notNull()
                t.column("sizeBytes", .integer).notNull()
                t.column("category", .text).notNull()
                t.column("subcategory", .text).notNull().defaults(to: "")
                t.primaryKey(["sessionId", "path"])
            }

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_workingSetRefreshStaging_sessionId
                ON workingSetRefreshStaging(sessionId)
                """)
        }

        try migrator.migrate(dbPool)
    }
}

// MARK: - Snapshot CRUD

extension DatabaseManager {
    struct JournalDeltaKey: Hashable, Sendable {
        let category: GrowthCategory
        let subcategory: GrowthSubcategory?
    }

    private struct WorkingSetCategoryRow {
        let totalBytes: Int64
        let updatedAt: Date
    }

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
            // Snapshot created — id, trackedPathId, freeBytes logged via OSLog in callers
            return snapshot
        }
    }

    /// Creates a new snapshot by copying the current working set (pure in-DB copy, no filesystem I/O).
    /// Deletes all older snapshots for this path so the new one becomes the sole baseline.
    /// - Parameters:
    ///   - trackedPathId: The tracked path UUID
    ///   - freeBytes: Optional volume free space at creation time
    /// - Returns: The ID of the newly created snapshot
    func createSnapshotFromWorkingSet(trackedPathId: UUID, freeBytes: Int64?) async throws -> Int64 {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.write { db in
            // Create new snapshot row
            var snapshot = Snapshot(trackedPathId: trackedPathId, createdAt: Date(), freeBytes: freeBytes)
            try snapshot.insert(db)
            guard let newSnapshotId = snapshot.id else {
                throw DatabaseError.notInitialized
            }

            // Copy working set → snapshot entries (pure in-DB copy)
            try db.execute(
                sql: """
                    INSERT INTO snapshotEntry (snapshotId, pathId, sizeBytes)
                    SELECT ?, pathId, sizeBytes FROM workingSetEntry WHERE trackedPathId = ?
                    """,
                arguments: [newSnapshotId, trackedPathId.uuidString]
            )

            // Delete all older snapshots (FK CASCADE cleans snapshotEntry, categorySnapshot, subcategorySnapshot)
            try db.execute(
                sql: "DELETE FROM snapshot WHERE trackedPathId = ? AND id != ?",
                arguments: [trackedPathId.uuidString, newSnapshotId]
            )

            return newSnapshotId
        }
    }

    /// Deletes all growth journal buckets for a tracked path.
    func deleteGrowthJournalBuckets(trackedPathId: UUID) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        try await dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM growthJournalBucket WHERE trackedPathId = ?",
                arguments: [trackedPathId.uuidString]
            )
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

    /// Adds multiple entries to a snapshot using multi-row batch inserts
    /// - Parameters:
    ///   - snapshotId: The snapshot ID to add entries to
    ///   - entries: Array of ScanResult values to insert
    ///
    /// Uses multi-row VALUES inserts in chunks of 500 rows (much fewer SQL round-trips
    /// than per-row prepared statement execution).
    func addEntries(to snapshotId: Int64, entries: [ScanResult]) async throws {
        try await addEntriesCore(to: snapshotId, entries: entries, trackedPathId: nil, updatedAt: nil)
    }

    /// Internal implementation that optionally also writes to workingSetEntry in the same transaction.
    /// When trackedPathId + updatedAt are provided the caller must NOT call rebuildWorkingSet separately.
    func addEntriesWithWorkingSet(
        to snapshotId: Int64,
        entries: [ScanResult],
        trackedPathId: UUID,
        updatedAt: Date
    ) async throws {
        try await addEntriesCore(to: snapshotId, entries: entries, trackedPathId: trackedPathId, updatedAt: updatedAt)
    }

    private func addEntriesCore(
        to snapshotId: Int64,
        entries: [ScanResult],
        trackedPathId: UUID?,
        updatedAt: Date?
    ) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        // Inner SQL chunk: 500 rows per multi-row VALUES statement.
        // Each snapshotEntry row has 3 params (500×3=1500) and workingSetEntry has 4 (500×4=2000),
        // both well within SQLite's SQLITE_LIMIT_VARIABLE_NUMBER default of 32766 on macOS.
        let sqlChunkSize = 500

        let trackedPathIdString = trackedPathId?.uuidString

        // Use a single transaction for all batches (much faster)
        // Note: We can't call Task.yield() inside the database write block
        try await dbPool.write { db in
            for startIndex in stride(from: 0, to: entries.count, by: sqlChunkSize) {
                let endIndex = min(startIndex + sqlChunkSize, entries.count)
                let batch = entries[startIndex..<endIndex]

                let normalizedBatch = batch.map {
                    (
                        path: Self.normalizePath($0.path),
                        sizeBytes: $0.sizeBytes,
                        category: $0.category,
                        subcategory: $0.subcategory
                    )
                }
                let uniquePaths = Array(Set(normalizedBatch.map(\.path)))
                let classificationsByPath = Dictionary(
                    uniqueKeysWithValues: normalizedBatch.map {
                        ($0.path, ResolvedPathClassification(category: $0.category, subcategory: $0.subcategory))
                    }
                )
                let pathIdByPath = try fetchPathIds(
                    for: uniquePaths,
                    classificationsByPath: classificationsByPath,
                    db: db
                )

                // Build (snapshotId, pathId, sizeBytes) tuples for multi-row INSERT
                var snapshotRows: [(pathId: Int64, sizeBytes: Int64)] = []
                snapshotRows.reserveCapacity(normalizedBatch.count)
                for scanResult in normalizedBatch {
                    guard let pathId = pathIdByPath[scanResult.path] else {
                        throw DatabaseError.pathLookupFailed(scanResult.path)
                    }
                    snapshotRows.append((pathId: pathId, sizeBytes: scanResult.sizeBytes))
                }

                // Multi-row INSERT into snapshotEntry
                let valuePlaceholders = Array(repeating: "(?,?,?)", count: snapshotRows.count).joined(separator: ",")
                let insertSQL = "INSERT INTO snapshotEntry (snapshotId, pathId, sizeBytes) VALUES \(valuePlaceholders)"
                var args: [DatabaseValueConvertible?] = []
                args.reserveCapacity(snapshotRows.count * 3)
                for row in snapshotRows {
                    args.append(snapshotId)
                    args.append(row.pathId)
                    args.append(row.sizeBytes)
                }
                try db.execute(sql: insertSQL, arguments: StatementArguments(args))

                // Optionally also write to workingSetEntry in the same transaction
                if let trackedPathIdString, let updatedAt {
                    let wsPlaceholders = Array(repeating: "(?,?,?,?)", count: snapshotRows.count).joined(separator: ",")
                    let wsSQL = """
                        INSERT INTO workingSetEntry (trackedPathId, pathId, sizeBytes, updatedAt)
                        VALUES \(wsPlaceholders)
                        ON CONFLICT(trackedPathId, pathId) DO UPDATE SET
                            sizeBytes = excluded.sizeBytes,
                            updatedAt = excluded.updatedAt
                        """
                    var wsArgs: [DatabaseValueConvertible?] = []
                    wsArgs.reserveCapacity(snapshotRows.count * 4)
                    for row in snapshotRows {
                        wsArgs.append(trackedPathIdString)
                        wsArgs.append(row.pathId)
                        wsArgs.append(row.sizeBytes)
                        wsArgs.append(updatedAt)
                    }
                    try db.execute(sql: wsSQL, arguments: StatementArguments(wsArgs))
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
                .order(Snapshot.Columns.createdAt.desc, Snapshot.Columns.id.desc)

            // Filter by trackedPathId if provided
            // Also exclude snapshots with empty trackedPathId (old snapshots before migration)
            if let trackedPathId = trackedPathId {
                let pathIdString = trackedPathId.uuidString
                request = request.filter(Snapshot.Columns.trackedPathId == pathIdString)
            } else {
                // When not filtering by path, still exclude empty trackedPathId entries
                request = request.filter(Snapshot.Columns.trackedPathId != "")
            }

            return try request.fetchAll(db)
        }
    }

    /// Fetches the most recent snapshots ordered by creation date (newest first).
    /// - Parameters:
    ///   - trackedPathId: Optional filter to only fetch snapshots for a specific path
    ///   - limit: Maximum number of snapshots to return
    /// - Returns: Array of recent snapshots
    func fetchRecentSnapshots(trackedPathId: UUID? = nil, limit: Int) async throws -> [Snapshot] {
        guard limit > 0 else { return [] }
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            var request = Snapshot.all()
                .order(Snapshot.Columns.createdAt.desc, Snapshot.Columns.id.desc)
                .limit(limit)

            if let trackedPathId = trackedPathId {
                request = request.filter(Snapshot.Columns.trackedPathId == trackedPathId.uuidString)
            } else {
                request = request.filter(Snapshot.Columns.trackedPathId != "")
            }

            return try request.fetchAll(db)
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

    /// Fetches the top N largest entries for a snapshot, ordered by size descending.
    /// This is much faster than fetchEntries for large snapshots when you only need big files.
    /// - Parameters:
    ///   - snapshotId: The snapshot ID
    ///   - limit: Maximum number of entries to return (default 500)
    /// - Returns: Array of SnapshotEntryWithPath ordered by sizeBytes DESC
    func fetchTopEntries(for snapshotId: Int64, limit: Int = 500) async throws -> [SnapshotEntryWithPath] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            try SnapshotEntryWithPath.fetchAll(db, sql: """
                SELECT se.id, se.snapshotId, p.path AS path, se.sizeBytes
                FROM snapshotEntry se
                JOIN paths p ON p.id = se.pathId
                WHERE se.snapshotId = ?
                ORDER BY se.sizeBytes DESC, p.path ASC
                LIMIT ?
                """, arguments: [snapshotId, limit])
        }
    }

    /// Fetches entries for a snapshot with pagination, ordered by size descending.
    /// - Parameters:
    ///   - snapshotId: The snapshot ID
    ///   - offset: Number of entries to skip
    ///   - limit: Maximum number of entries to return
    /// - Returns: Array of SnapshotEntryWithPath ordered by sizeBytes DESC
    func fetchEntriesPaginated(for snapshotId: Int64, offset: Int, limit: Int) async throws -> [SnapshotEntryWithPath] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            try SnapshotEntryWithPath.fetchAll(db, sql: """
                SELECT se.id, se.snapshotId, p.path AS path, se.sizeBytes
                FROM snapshotEntry se
                JOIN paths p ON p.id = se.pathId
                WHERE se.snapshotId = ?
                ORDER BY se.sizeBytes DESC, p.path ASC
                LIMIT ? OFFSET ?
                """, arguments: [snapshotId, limit, offset])
        }
    }

    /// Fetches entries for a snapshot with pagination, without ordering.
    /// Use when you need to scan the entire snapshot without paying sort costs.
    /// - Parameters:
    ///   - snapshotId: The snapshot ID
    ///   - offset: Number of entries to skip
    ///   - limit: Maximum number of entries to return
    /// - Returns: Array of SnapshotEntryWithPath in database order
    func fetchEntriesPaginatedUnordered(for snapshotId: Int64, offset: Int, limit: Int) async throws -> [SnapshotEntryWithPath] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            try SnapshotEntryWithPath.fetchAll(db, sql: """
                SELECT se.id, se.snapshotId, p.path AS path, se.sizeBytes
                FROM snapshotEntry se
                JOIN paths p ON p.id = se.pathId
                WHERE se.snapshotId = ?
                LIMIT ? OFFSET ?
                """, arguments: [snapshotId, limit, offset])
        }
    }

    /// Fetches entries for a snapshot in primary-key order using cursor pagination.
    /// Avoids large OFFSET scans when walking very large snapshots end-to-end.
    func fetchEntriesPaginatedUnordered(
        for snapshotId: Int64,
        afterEntryId: Int64?,
        limit: Int
    ) async throws -> [SnapshotEntryWithPath] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            if let afterEntryId {
                return try SnapshotEntryWithPath.fetchAll(db, sql: """
                    SELECT se.id, se.snapshotId, p.path AS path, se.sizeBytes
                    FROM snapshotEntry se
                    JOIN paths p ON p.id = se.pathId
                    WHERE se.snapshotId = ? AND se.id > ?
                    ORDER BY se.id
                    LIMIT ?
                    """, arguments: [snapshotId, afterEntryId, limit])
            }

            return try SnapshotEntryWithPath.fetchAll(db, sql: """
                SELECT se.id, se.snapshotId, p.path AS path, se.sizeBytes
                FROM snapshotEntry se
                JOIN paths p ON p.id = se.pathId
                WHERE se.snapshotId = ?
                ORDER BY se.id
                LIMIT ?
                """, arguments: [snapshotId, limit])
        }
    }

    /// Fetches working set entries for a tracked path, paginated. Returns the same shape as snapshot entries.
    func fetchWorkingSetEntriesPaginated(trackedPathId: UUID, offset: Int, limit: Int) async throws -> [SnapshotEntryWithPath] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            try SnapshotEntryWithPath.fetchAll(db, sql: """
                SELECT wse.id, 0 AS snapshotId, p.path AS path, wse.sizeBytes
                FROM workingSetEntry wse
                JOIN paths p ON p.id = wse.pathId
                WHERE wse.trackedPathId = ?
                LIMIT ? OFFSET ?
                """, arguments: [trackedPathId.uuidString, limit, offset])
        }
    }

    /// Fetches working-set entries for a specific category using SQL-level filtering
    /// via pathClassification. Much faster than fetching all entries and classifying in Swift.
    func fetchWorkingSetEntriesByCategory(
        trackedPathId: UUID,
        category: GrowthCategory,
        offset: Int,
        limit: Int
    ) async throws -> [SnapshotEntryWithPath] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            try SnapshotEntryWithPath.fetchAll(db, sql: """
                SELECT wse.id, 0 AS snapshotId, p.path AS path, wse.sizeBytes
                FROM workingSetEntry wse
                JOIN pathClassification pc ON pc.pathId = wse.pathId
                JOIN paths p ON p.id = wse.pathId
                WHERE wse.trackedPathId = ? AND pc.category = ?
                LIMIT ? OFFSET ?
                """, arguments: [trackedPathId.uuidString, category.rawValue, limit, offset])
        }
    }

    func fetchSnapshotEntriesByClassification(
        snapshotId: Int64,
        category: GrowthCategory,
        subcategory: GrowthSubcategory?,
        offset: Int,
        limit: Int
    ) async throws -> [SnapshotEntryWithPath] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let subcategoryValue = subcategory?.rawValue ?? ""
        return try await dbPool.read { db in
            try SnapshotEntryWithPath.fetchAll(db, sql: """
                SELECT se.id, se.snapshotId, p.path AS path, se.sizeBytes
                FROM snapshotEntry se
                JOIN pathClassification pc ON pc.pathId = se.pathId
                JOIN paths p ON p.id = se.pathId
                WHERE se.snapshotId = ? AND pc.category = ? AND pc.subcategory = ?
                ORDER BY se.sizeBytes DESC, p.path ASC
                LIMIT ? OFFSET ?
                """, arguments: [snapshotId, category.rawValue, subcategoryValue, limit, offset])
        }
    }

    func fetchWorkingSetEntriesByClassification(
        trackedPathId: UUID,
        category: GrowthCategory,
        subcategory: GrowthSubcategory?,
        offset: Int,
        limit: Int
    ) async throws -> [SnapshotEntryWithPath] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let subcategoryValue = subcategory?.rawValue ?? ""
        return try await dbPool.read { db in
            try SnapshotEntryWithPath.fetchAll(db, sql: """
                SELECT wse.id, 0 AS snapshotId, p.path AS path, wse.sizeBytes
                FROM workingSetEntry wse
                JOIN pathClassification pc ON pc.pathId = wse.pathId
                JOIN paths p ON p.id = wse.pathId
                WHERE wse.trackedPathId = ? AND pc.category = ? AND pc.subcategory = ?
                ORDER BY wse.sizeBytes DESC, p.path ASC
                LIMIT ? OFFSET ?
                """, arguments: [trackedPathId.uuidString, category.rawValue, subcategoryValue, limit, offset])
        }
    }

    /// Returns the total bytes stored in a snapshot without materializing every row.
    func sumEntrySizes(for snapshotId: Int64) async throws -> Int64 {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(sizeBytes), 0) FROM snapshotEntry WHERE snapshotId = ?",
                arguments: [snapshotId]
            ) ?? 0
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

    /// Replaces all category totals for a snapshot in a single transaction.
    func replaceCategorySnapshots(snapshotId: Int64, totals: [GrowthCategory: Int64]) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM categorySnapshot WHERE snapshotId = ?", arguments: [snapshotId])

            guard !totals.isEmpty else { return }

            let statement = try db.makeStatement(
                sql: "INSERT INTO categorySnapshot (snapshotId, category, totalBytes) VALUES (?, ?, ?)"
            )

            for category in GrowthCategory.allCases {
                guard let totalBytes = totals[category], totalBytes > 0 else { continue }
                try statement.execute(arguments: [snapshotId, category.rawValue, totalBytes])
            }
        }
    }

    /// Fetches current category totals for a snapshot.
    func fetchCategoryTotals(for snapshotId: Int64) async throws -> [CategoryInventoryItem] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT category, totalBytes
                    FROM categorySnapshot
                    WHERE snapshotId = ?
                    ORDER BY totalBytes DESC
                    """,
                arguments: [snapshotId]
            )

            return rows.compactMap { row in
                guard
                    let categoryRaw: String = row["category"],
                    let category = GrowthCategory(rawValue: categoryRaw)
                else {
                    return nil
                }

                let totalBytes: Int64 = row["totalBytes"] ?? 0
                return CategoryInventoryItem(
                    category: category,
                    currentSizeBytes: totalBytes,
                    growthTrend: nil,
                    recentGrowthStory: nil
                )
            }
        }
    }

    func fetchWorkingSetCategoryTotals(for trackedPathId: UUID) async throws -> [CategoryInventoryItem] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let trackedPathIdString = trackedPathId.uuidString

        return try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT category, totalBytes
                    FROM workingSetCategoryTotal
                    WHERE trackedPathId = ?
                    ORDER BY totalBytes DESC, category ASC
                    """,
                arguments: [trackedPathIdString]
            )

            return rows.compactMap { row in
                guard
                    let categoryRaw: String = row["category"],
                    let category = GrowthCategory(rawValue: categoryRaw)
                else {
                    return nil
                }

                let totalBytes: Int64 = row["totalBytes"] ?? 0
                guard totalBytes > 0 else { return nil }

                return CategoryInventoryItem(
                    category: category,
                    currentSizeBytes: totalBytes,
                    growthTrend: nil,
                    recentGrowthStory: nil
                )
            }
        }
    }

    struct StoredSubcategorySnapshot: Sendable {
        let category: GrowthCategory
        let subcategory: GrowthSubcategory?
        let totalBytes: Int64
        let fileCount: Int
        let topItems: [GrowthItem]
    }

    /// Replaces all subcategory summaries for a snapshot in a single transaction.
    func replaceSubcategorySnapshots(snapshotId: Int64, rows: [StoredSubcategorySnapshot]) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let encoder = JSONEncoder()

        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM subcategorySnapshot WHERE snapshotId = ?", arguments: [snapshotId])

            guard !rows.isEmpty else { return }

            let statement = try db.makeStatement(
                sql: """
                    INSERT INTO subcategorySnapshot (snapshotId, category, subcategory, totalBytes, fileCount, topItemsJSON)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """
            )

            for row in rows {
                let payload = try encoder.encode(row.topItems)
                let json = String(decoding: payload, as: UTF8.self)
                try statement.execute(arguments: [
                    snapshotId,
                    row.category.rawValue,
                    row.subcategory?.rawValue ?? "",
                    row.totalBytes,
                    row.fileCount,
                    json
                ])
            }
        }
    }

    /// Fetches precomputed subcategory groups for a category within a snapshot.
    func fetchSubcategoryGroups(for snapshotId: Int64, category: GrowthCategory) async throws -> [SubcategoryGroup] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let decoder = JSONDecoder()

        return try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT subcategory, totalBytes, fileCount, topItemsJSON
                    FROM subcategorySnapshot
                    WHERE snapshotId = ? AND category = ?
                    ORDER BY totalBytes DESC
                    """,
                arguments: [snapshotId, category.rawValue]
            )

            return try rows.map { row in
                let rawSubcategory: String = row["subcategory"] ?? ""
                let subcategory = rawSubcategory.isEmpty ? nil : GrowthSubcategory(rawValue: rawSubcategory)
                let totalBytes: Int64 = row["totalBytes"] ?? 0
                let fileCount: Int = row["fileCount"] ?? 0
                let topItemsJSON: String = row["topItemsJSON"] ?? "[]"
                let topItems = try decoder.decode([GrowthItem].self, from: Data(topItemsJSON.utf8))

                let displayName: String
                if let subcategory {
                    displayName = subcategory.displayName
                } else {
                    displayName = category.supportsSubcategories ? "Uncategorized" : "Files"
                }

                return SubcategoryGroup(
                    subcategory: subcategory,
                    displayName: displayName,
                    totalBytes: totalBytes,
                    fileCount: fileCount,
                    growthBytes: nil,
                    topFiles: topItems
                )
            }
        }
    }

    func rebuildWorkingSet(from snapshotId: Int64, trackedPathId: UUID, updatedAt: Date = Date()) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let trackedPathIdString = trackedPathId.uuidString

        try await dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM workingSetEntry WHERE trackedPathId = ?",
                arguments: [trackedPathIdString]
            )

            try db.execute(
                sql: """
                    INSERT INTO workingSetEntry (trackedPathId, pathId, sizeBytes, updatedAt)
                    SELECT ?, pathId, sizeBytes, ?
                    FROM snapshotEntry
                    WHERE snapshotId = ?
                    """,
                arguments: [trackedPathIdString, updatedAt, snapshotId]
            )

            try db.execute(
                sql: "DELETE FROM workingSetCategoryTotal WHERE trackedPathId = ?",
                arguments: [trackedPathIdString]
            )

            try db.execute(
                sql: """
                    INSERT INTO workingSetCategoryTotal (trackedPathId, category, totalBytes, updatedAt)
                    SELECT
                        ?,
                        pc.category,
                        COALESCE(SUM(se.sizeBytes), 0),
                        ?
                    FROM snapshotEntry se
                    JOIN pathClassification pc ON pc.pathId = se.pathId
                    WHERE se.snapshotId = ?
                    GROUP BY pc.category
                    HAVING COALESCE(SUM(se.sizeBytes), 0) > 0
                    """,
                arguments: [trackedPathIdString, updatedAt, snapshotId]
            )
        }
    }

    /// Clears working-set entries for a tracked path in preparation for an inline rebuild.
    ///
    /// Must be called before the first `addEntriesWithWorkingSet` batch so subsequent
    /// ON CONFLICT upserts don't accumulate stale rows from a previous scan.
    func clearWorkingSetEntries(trackedPathId: UUID) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let trackedPathIdString = trackedPathId.uuidString
        try await dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM workingSetEntry WHERE trackedPathId = ?",
                arguments: [trackedPathIdString]
            )
            try db.execute(
                sql: "DELETE FROM workingSetCategoryTotal WHERE trackedPathId = ?",
                arguments: [trackedPathIdString]
            )
        }
    }

    /// Replaces all working-set category totals for a tracked path using the provided in-memory totals.
    ///
    /// Used by the inline working-set path (alsoWriteWorkingSet = true) to avoid a separate
    /// SQL GROUP BY over 2.2M rows after scan completion.
    func replaceWorkingSetCategoryTotals(
        trackedPathId: UUID,
        totals: [GrowthCategory: Int64],
        updatedAt: Date
    ) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let trackedPathIdString = trackedPathId.uuidString

        try await dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM workingSetCategoryTotal WHERE trackedPathId = ?",
                arguments: [trackedPathIdString]
            )

            guard !totals.isEmpty else { return }

            let nonZeroTotals = totals.filter { $0.value > 0 }
            guard !nonZeroTotals.isEmpty else { return }

            let valuePlaceholders = Array(repeating: "(?,?,?,?)", count: nonZeroTotals.count).joined(separator: ",")
            let sql = "INSERT INTO workingSetCategoryTotal (trackedPathId, category, totalBytes, updatedAt) VALUES \(valuePlaceholders)"
            var args: [DatabaseValueConvertible?] = []
            args.reserveCapacity(nonZeroTotals.count * 4)
            for (category, totalBytes) in nonZeroTotals {
                args.append(trackedPathIdString)
                args.append(category.rawValue)
                args.append(totalBytes)
                args.append(updatedAt)
            }
            try db.execute(sql: sql, arguments: StatementArguments(args))
        }
    }

    func replaceWorkingSetSubtree(
        trackedPathId: UUID,
        rootPath: String,
        entries: [ScanResult],
        updatedAt: Date = Date()
    ) async throws -> [JournalDeltaKey: Int64] {
        let stagingSessionId = UUID().uuidString
        try await clearWorkingSetRefreshStaging(sessionId: stagingSessionId)

        do {
            if !entries.isEmpty {
                try await appendWorkingSetRefreshStaging(
                    sessionId: stagingSessionId,
                    entries: entries
                )
            }

            return try await replaceWorkingSetSubtree(
                trackedPathId: trackedPathId,
                rootPath: rootPath,
                stagingSessionId: stagingSessionId,
                updatedAt: updatedAt
            )
        } catch {
            try? await clearWorkingSetRefreshStaging(sessionId: stagingSessionId)
            throw error
        }
    }

    func appendWorkingSetRefreshStaging(
        sessionId: String,
        entries: [ScanResult]
    ) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        guard !entries.isEmpty else { return }

        let sqlChunkSize = 500

        try await dbPool.write { db in
            for startIndex in stride(from: 0, to: entries.count, by: sqlChunkSize) {
                let endIndex = min(startIndex + sqlChunkSize, entries.count)
                let batch = entries[startIndex..<endIndex]
                let normalizedBatch = batch.map {
                    (
                        path: Self.normalizePath($0.path),
                        sizeBytes: $0.sizeBytes,
                        category: $0.category.rawValue,
                        subcategory: $0.subcategory?.rawValue ?? ""
                    )
                }

                let placeholders = Array(repeating: "(?,?,?,?,?)", count: normalizedBatch.count).joined(separator: ",")
                let sql = """
                    INSERT INTO workingSetRefreshStaging (sessionId, path, sizeBytes, category, subcategory)
                    VALUES \(placeholders)
                    ON CONFLICT(sessionId, path) DO UPDATE SET
                        sizeBytes = excluded.sizeBytes,
                        category = excluded.category,
                        subcategory = excluded.subcategory
                    """

                var arguments: [DatabaseValueConvertible?] = []
                arguments.reserveCapacity(normalizedBatch.count * 5)
                for entry in normalizedBatch {
                    arguments.append(sessionId)
                    arguments.append(entry.path)
                    arguments.append(entry.sizeBytes)
                    arguments.append(entry.category)
                    arguments.append(entry.subcategory)
                }

                try db.execute(sql: sql, arguments: StatementArguments(arguments))
            }
        }
    }

    func clearWorkingSetRefreshStaging(sessionId: String? = nil) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        try await dbPool.write { db in
            try Self.clearWorkingSetRefreshStagingRows(sessionId: sessionId, db: db)
        }
    }

    private static func clearWorkingSetRefreshStagingRows(sessionId: String? = nil, db: Database) throws {
        if let sessionId {
            try db.execute(
                sql: "DELETE FROM workingSetRefreshStaging WHERE sessionId = ?",
                arguments: [sessionId]
            )
        } else {
            try db.execute(sql: "DELETE FROM workingSetRefreshStaging")
        }
    }

    func replaceWorkingSetSubtree(
        trackedPathId: UUID,
        rootPath: String,
        stagingSessionId: String,
        updatedAt: Date = Date()
    ) async throws -> [JournalDeltaKey: Int64] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let trackedPathIdString = trackedPathId.uuidString
        let normalizedRoot = Self.normalizePath(rootPath)
        let rootPrefix = normalizedRoot == "/" ? "/" : normalizedRoot + "/"

        return try await dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO paths (path)
                    SELECT path
                    FROM workingSetRefreshStaging
                    WHERE sessionId = ?
                    """,
                arguments: [stagingSessionId]
            )

            try db.execute(
                sql: """
                    INSERT INTO pathClassification (pathId, category, subcategory)
                    SELECT p.id, s.category, s.subcategory
                    FROM workingSetRefreshStaging s
                    JOIN paths p ON p.path = s.path
                    WHERE s.sessionId = ?
                    ON CONFLICT(pathId) DO UPDATE SET
                        category = excluded.category,
                        subcategory = excluded.subcategory
                    """,
                arguments: [stagingSessionId]
            )

            let deltaRows = try Row.fetchAll(
                db,
                sql: """
                    WITH oldRows AS (
                        SELECT
                            p.path AS path,
                            wse.sizeBytes AS sizeBytes,
                            pc.category AS category,
                            pc.subcategory AS subcategory
                        FROM workingSetEntry wse
                        JOIN paths p ON p.id = wse.pathId
                        JOIN pathClassification pc ON pc.pathId = wse.pathId
                        WHERE wse.trackedPathId = ?
                          AND (p.path = ? OR p.path LIKE ?)
                    ),
                    newRows AS (
                        SELECT path, sizeBytes, category, subcategory
                        FROM workingSetRefreshStaging
                        WHERE sessionId = ?
                    ),
                    combined AS (
                        SELECT
                            COALESCE(newRows.category, oldRows.category) AS category,
                            COALESCE(newRows.subcategory, oldRows.subcategory) AS subcategory,
                            COALESCE(newRows.sizeBytes, 0) - COALESCE(oldRows.sizeBytes, 0) AS deltaBytes
                        FROM oldRows
                        LEFT JOIN newRows ON newRows.path = oldRows.path
                        UNION ALL
                        SELECT
                            newRows.category AS category,
                            newRows.subcategory AS subcategory,
                            COALESCE(newRows.sizeBytes, 0) - COALESCE(oldRows.sizeBytes, 0) AS deltaBytes
                        FROM newRows
                        LEFT JOIN oldRows ON oldRows.path = newRows.path
                        WHERE oldRows.path IS NULL
                    )
                    SELECT category, subcategory, SUM(deltaBytes) AS deltaBytes
                    FROM combined
                    WHERE deltaBytes != 0
                    GROUP BY category, subcategory
                    """,
                arguments: [
                    trackedPathIdString,
                    normalizedRoot,
                    rootPrefix + "%",
                    stagingSessionId
                ]
            )

            var deltasByCategory: [JournalDeltaKey: Int64] = [:]
            deltasByCategory.reserveCapacity(deltaRows.count)
            for row in deltaRows {
                guard
                    let rawCategory: String = row["category"],
                    let category = GrowthCategory(rawValue: rawCategory)
                else {
                    continue
                }

                let rawSubcategory: String = row["subcategory"] ?? ""
                let subcategory = rawSubcategory.isEmpty ? nil : GrowthSubcategory(rawValue: rawSubcategory)
                let deltaBytes: Int64 = row["deltaBytes"] ?? 0
                guard deltaBytes != 0 else { continue }

                deltasByCategory[JournalDeltaKey(category: category, subcategory: subcategory), default: 0] += deltaBytes
            }

            try db.execute(
                sql: """
                    DELETE FROM workingSetEntry
                    WHERE trackedPathId = ?
                      AND pathId IN (
                        SELECT p.id
                        FROM paths p
                        WHERE p.path = ? OR p.path LIKE ?
                      )
                    """,
                arguments: [trackedPathIdString, normalizedRoot, rootPrefix + "%"]
            )

            try db.execute(
                sql: """
                    INSERT INTO workingSetEntry (trackedPathId, pathId, sizeBytes, updatedAt)
                    SELECT ?, p.id, s.sizeBytes, ?
                    FROM workingSetRefreshStaging s
                    JOIN paths p ON p.path = s.path
                    WHERE s.sessionId = ?
                    ON CONFLICT(trackedPathId, pathId) DO UPDATE SET
                        sizeBytes = excluded.sizeBytes,
                        updatedAt = excluded.updatedAt
                    """,
                arguments: [trackedPathIdString, updatedAt, stagingSessionId]
            )

            // Apply incremental deltas to category totals.
            try applyWorkingSetCategoryDeltas(
                deltasByCategory,
                trackedPathId: trackedPathIdString,
                updatedAt: updatedAt,
                db: db
            )

            try db.execute(
                sql: "DELETE FROM workingSetRefreshStaging WHERE sessionId = ?",
                arguments: [stagingSessionId]
            )

            return deltasByCategory
        }
    }

    func upsertGrowthJournalBuckets(
        trackedPathId: UUID,
        bucketStart: Date,
        deltas: [JournalDeltaKey: Int64]
    ) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        guard !deltas.isEmpty else { return }

        let trackedPathIdString = trackedPathId.uuidString

        try await dbPool.write { db in
            let statement = try db.makeStatement(
                sql: """
                    INSERT INTO growthJournalBucket (trackedPathId, bucketStart, category, subcategory, deltaBytes)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(trackedPathId, bucketStart, category, subcategory)
                    DO UPDATE SET deltaBytes = deltaBytes + excluded.deltaBytes
                    """
            )

            for (key, deltaBytes) in deltas where deltaBytes != 0 {
                try statement.execute(arguments: [
                    trackedPathIdString,
                    bucketStart,
                    key.category.rawValue,
                    key.subcategory?.rawValue ?? "",
                    deltaBytes
                ])
            }
        }
    }

    func fetchGrowthJournalBuckets(
        trackedPathId: UUID,
        since: Date? = nil
    ) async throws -> [GrowthJournalBucket] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let trackedPathIdString = trackedPathId.uuidString

        return try await dbPool.read { db in
            if let since {
                return try GrowthJournalBucket.fetchAll(
                    db,
                    sql: """
                        SELECT *
                        FROM growthJournalBucket
                        WHERE trackedPathId = ? AND bucketStart >= ?
                        ORDER BY bucketStart ASC
                        """,
                    arguments: [trackedPathIdString, since]
                )
            }

            return try GrowthJournalBucket.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM growthJournalBucket
                    WHERE trackedPathId = ?
                    ORDER BY bucketStart ASC
                    """,
                arguments: [trackedPathIdString]
            )
        }
    }

    func fetchGrowthJournalTotalsByCategory(
        trackedPathId: UUID,
        since: Date
    ) async throws -> [GrowthCategory: Int64] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let trackedPathIdString = trackedPathId.uuidString

        return try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT category, COALESCE(SUM(deltaBytes), 0) AS totalDelta
                    FROM growthJournalBucket
                    WHERE trackedPathId = ? AND bucketStart >= ?
                    GROUP BY category
                    """,
                arguments: [trackedPathIdString, since]
            )

            var result: [GrowthCategory: Int64] = [:]
            for row in rows {
                guard
                    let rawCategory: String = row["category"],
                    let category = GrowthCategory(rawValue: rawCategory)
                else {
                    continue
                }

                let totalDelta: Int64 = row["totalDelta"] ?? 0
                result[category] = totalDelta
            }

            return result
        }
    }

    func fetchGrowthJournalTotalsBySubcategory(
        trackedPathId: UUID,
        category: GrowthCategory,
        since: Date
    ) async throws -> [GrowthSubcategory?: Int64] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let trackedPathIdString = trackedPathId.uuidString

        return try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT subcategory, COALESCE(SUM(deltaBytes), 0) AS totalDelta
                    FROM growthJournalBucket
                    WHERE trackedPathId = ? AND category = ? AND bucketStart >= ?
                    GROUP BY subcategory
                    """,
                arguments: [trackedPathIdString, category.rawValue, since]
            )

            var result: [GrowthSubcategory?: Int64] = [:]
            for row in rows {
                let rawSubcategory: String? = row["subcategory"]
                let subcategory = rawSubcategory.flatMap { GrowthSubcategory(rawValue: $0) }
                let totalDelta: Int64 = row["totalDelta"] ?? 0
                if totalDelta > 0 {
                    result[subcategory, default: 0] += totalDelta
                }
            }

            return result
        }
    }

    func pruneGrowthJournalBuckets(olderThan cutoff: Date) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        try await dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM growthJournalBucket WHERE bucketStart < ?",
                arguments: [cutoff]
            )
        }
    }

    func clearRealtimeData(trackedPathId: UUID? = nil) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let trackedPathIdString = trackedPathId?.uuidString

        try await dbPool.write { db in
            if let trackedPathIdString {
                try db.execute(
                    sql: "DELETE FROM workingSetEntry WHERE trackedPathId = ?",
                    arguments: [trackedPathIdString]
                )
                try db.execute(
                    sql: "DELETE FROM workingSetCategoryTotal WHERE trackedPathId = ?",
                    arguments: [trackedPathIdString]
                )
                try db.execute(
                    sql: "DELETE FROM growthJournalBucket WHERE trackedPathId = ?",
                    arguments: [trackedPathIdString]
                )
            } else {
                try db.execute(sql: "DELETE FROM workingSetEntry")
                try db.execute(sql: "DELETE FROM workingSetCategoryTotal")
                try db.execute(sql: "DELETE FROM growthJournalBucket")
            }
        }
    }

    /// Normalizes a file path for consistent storage
    /// - Removes trailing slash (unless it's just "/")
    /// - Note: Case is preserved as-is. macOS is case-preserving, and normalizePath
    ///   is applied on every insert/lookup so exact-match queries are safe.
    private static func normalizePath(_ path: String) -> String {
        if path == "/" {
            return path
        }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private struct ResolvedPathClassification {
        let category: GrowthCategory
        let subcategory: GrowthSubcategory?
    }

    private func upsertPathClassifications(
        pathIdByPath: [String: Int64],
        classificationsByPath: [String: ResolvedPathClassification]? = nil,
        db: Database
    ) throws {
        guard !pathIdByPath.isEmpty else { return }

        // Build flat array of (pathId, category, subcategory) tuples for chunked multi-row INSERT
        var rows: [(pathId: Int64, category: String, subcategory: String)] = []
        rows.reserveCapacity(pathIdByPath.count)
        for (path, pathId) in pathIdByPath {
            let resolved = classificationsByPath?[path]
                ?? ResolvedPathClassification(
                    category: GrowthCategory.categorize(path: path),
                    subcategory: GrowthCategory.subcategorize(path: path)
                )
            rows.append((
                pathId: pathId,
                category: resolved.category.rawValue,
                subcategory: resolved.subcategory?.rawValue ?? ""
            ))
        }

        // Insert in chunks of 500 rows using multi-row VALUES — ~500x fewer round-trips
        let chunkSize = 500
        for startIndex in stride(from: 0, to: rows.count, by: chunkSize) {
            let endIndex = min(startIndex + chunkSize, rows.count)
            let chunk = rows[startIndex..<endIndex]
            let valuePlaceholders = Array(repeating: "(?,?,?)", count: chunk.count).joined(separator: ",")
            let sql = """
                INSERT INTO pathClassification (pathId, category, subcategory)
                VALUES \(valuePlaceholders)
                ON CONFLICT(pathId) DO UPDATE SET
                    category = excluded.category,
                    subcategory = excluded.subcategory
                """
            var args: [DatabaseValueConvertible?] = []
            args.reserveCapacity(chunk.count * 3)
            for row in chunk {
                args.append(row.pathId)
                args.append(row.category)
                args.append(row.subcategory)
            }
            try db.execute(sql: sql, arguments: StatementArguments(args))
        }
    }

    private func getOrCreatePathId(path: String, db: Database) throws -> Int64 {
        let normalizedPath = Self.normalizePath(path)
        try db.execute(sql: "INSERT OR IGNORE INTO paths (path) VALUES (?)", arguments: [normalizedPath])
        // Exact match — paths are normalized on insert so no COLLATE NOCASE needed
        if let row = try Row.fetchOne(db, sql: "SELECT id FROM paths WHERE path = ?", arguments: [normalizedPath]),
           let id: Int64 = row["id"] {
            try upsertPathClassifications(pathIdByPath: [normalizedPath: id], db: db)
            return id
        }
        throw DatabaseError.notInitialized
    }

    private func fetchPathIds(
        for paths: [String],
        classificationsByPath: [String: ResolvedPathClassification]? = nil,
        db: Database
    ) throws -> [String: Int64] {
        guard !paths.isEmpty else { return [:] }

        // normalizePath is idempotent; dedup via Set
        let normalizedPaths = Array(Set(paths.map { Self.normalizePath($0) }))
        let pathChunkSize = 500

        // Bulk-insert any new paths (exact match, no COLLATE NOCASE — paths normalized on entry)
        for startIndex in stride(from: 0, to: normalizedPaths.count, by: pathChunkSize) {
            let endIndex = min(startIndex + pathChunkSize, normalizedPaths.count)
            let chunk = Array(normalizedPaths[startIndex..<endIndex])
            let values = Array(repeating: "(?)", count: chunk.count).joined(separator: ", ")
            try db.execute(
                sql: "INSERT OR IGNORE INTO paths (path) VALUES \(values)",
                arguments: StatementArguments(chunk)
            )
        }

        var result: [String: Int64] = [:]
        result.reserveCapacity(normalizedPaths.count)

        // Fetch IDs with exact match — no COLLATE NOCASE overhead
        for startIndex in stride(from: 0, to: normalizedPaths.count, by: pathChunkSize) {
            let endIndex = min(startIndex + pathChunkSize, normalizedPaths.count)
            let chunk = Array(normalizedPaths[startIndex..<endIndex])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let sql = "SELECT id, path FROM paths WHERE path IN (\(placeholders))"
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(chunk))

            for row in rows {
                guard
                    let storedPath: String = row["path"],
                    let pathId: Int64 = row["id"]
                else {
                    continue
                }
                result[storedPath] = pathId
            }
        }

        try upsertPathClassifications(
            pathIdByPath: result,
            classificationsByPath: classificationsByPath,
            db: db
        )
        return result
    }

    private func fetchWorkingSetCategoryRows(
        trackedPathId: String,
        db: Database
    ) throws -> [GrowthCategory: WorkingSetCategoryRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT category, totalBytes, updatedAt
                FROM workingSetCategoryTotal
                WHERE trackedPathId = ?
                """,
            arguments: [trackedPathId]
        )

        var result: [GrowthCategory: WorkingSetCategoryRow] = [:]
        for row in rows {
            guard
                let rawCategory: String = row["category"],
                let category = GrowthCategory(rawValue: rawCategory)
            else {
                continue
            }

            let totalBytes: Int64 = row["totalBytes"] ?? 0
            let updatedAt: Date = row["updatedAt"] ?? Date()
            result[category] = WorkingSetCategoryRow(totalBytes: totalBytes, updatedAt: updatedAt)
        }

        return result
    }

    private func applyWorkingSetCategoryDeltas(
        _ deltasByCategory: [JournalDeltaKey: Int64],
        trackedPathId: String,
        updatedAt: Date,
        db: Database
    ) throws {
        guard !deltasByCategory.isEmpty else { return }

        var totalsByCategory = try fetchWorkingSetCategoryRows(trackedPathId: trackedPathId, db: db)
        let upsert = try db.makeStatement(sql: """
            INSERT INTO workingSetCategoryTotal (trackedPathId, category, totalBytes, updatedAt)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(trackedPathId, category) DO UPDATE SET
                totalBytes = excluded.totalBytes,
                updatedAt = excluded.updatedAt
            """)
        let delete = try db.makeStatement(sql: """
            DELETE FROM workingSetCategoryTotal
            WHERE trackedPathId = ? AND category = ?
            """)

        for (key, deltaBytes) in deltasByCategory where deltaBytes != 0 {
            let existing = totalsByCategory[key.category]?.totalBytes ?? 0
            let nextTotal = max(0, existing + deltaBytes)

            if nextTotal == 0 {
                try delete.execute(arguments: [trackedPathId, key.category.rawValue])
                totalsByCategory[key.category] = nil
                continue
            }

            try upsert.execute(arguments: [trackedPathId, key.category.rawValue, nextTotal, updatedAt])
            totalsByCategory[key.category] = WorkingSetCategoryRow(
                totalBytes: nextTotal,
                updatedAt: updatedAt
            )
        }
    }
}

// MARK: - Growth Contributors

extension DatabaseManager {

    /// Finds files in a category that grew or appeared since the last snapshot
    /// by comparing working set entries against snapshot entries.
    ///
    /// - Parameters:
    ///   - trackedPathId: The tracked path to query
    ///   - snapshotId: The baseline snapshot to compare against
    ///   - category: The growth category to filter by
    ///   - subcategory: Optional subcategory filter
    ///   - limit: Maximum number of results
    /// - Returns: Array of (path, currentSizeBytes, growthBytes) tuples sorted by growthBytes DESC
    func fetchGrowthContributors(
        trackedPathId: UUID,
        snapshotId: Int64,
        category: GrowthCategory,
        subcategory: GrowthSubcategory?,
        limit: Int = 50
    ) async throws -> [GrowthContributor] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let trackedPathIdString = trackedPathId.uuidString
        let subcategoryRawValue = subcategory?.rawValue ?? ""
        let hasSubcategoryFilter = subcategory == nil ? 0 : 1

        return try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        p.path AS path,
                        wse.sizeBytes AS currentSizeBytes,
                        wse.sizeBytes - COALESCE(se.sizeBytes, 0) AS growthBytes
                    FROM workingSetEntry wse
                    JOIN pathClassification pc ON pc.pathId = wse.pathId
                    JOIN paths p ON p.id = wse.pathId
                    LEFT JOIN snapshotEntry se
                        ON se.pathId = wse.pathId
                        AND se.snapshotId = ?
                    WHERE wse.trackedPathId = ?
                        AND wse.sizeBytes > COALESCE(se.sizeBytes, 0)
                        AND pc.category = ?
                        AND (? = 0 OR pc.subcategory = ?)
                    ORDER BY growthBytes DESC
                    LIMIT ?
                    """,
                arguments: [
                    snapshotId,
                    trackedPathIdString,
                    category.rawValue,
                    hasSubcategoryFilter,
                    subcategoryRawValue,
                    limit
                ]
            )

            return rows.map { row in
                let path: String = row["path"] ?? ""
                let currentSizeBytes: Int64 = row["currentSizeBytes"] ?? 0
                let growthBytes: Int64 = row["growthBytes"] ?? 0

                return GrowthContributor(
                    path: path,
                    currentSizeBytes: currentSizeBytes,
                    growthBytes: growthBytes
                )
            }
        }
    }

    func fetchGrowthTotalsBySubcategory(
        trackedPathId: UUID,
        snapshotId: Int64,
        category: GrowthCategory
    ) async throws -> [GrowthSubcategory?: Int64] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let trackedPathIdString = trackedPathId.uuidString

        return try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        pc.subcategory AS subcategory,
                        COALESCE(SUM(wse.sizeBytes - COALESCE(se.sizeBytes, 0)), 0) AS growthBytes
                    FROM workingSetEntry wse
                    JOIN pathClassification pc ON pc.pathId = wse.pathId
                    LEFT JOIN snapshotEntry se
                        ON se.pathId = wse.pathId
                        AND se.snapshotId = ?
                    WHERE wse.trackedPathId = ?
                        AND wse.sizeBytes > COALESCE(se.sizeBytes, 0)
                        AND pc.category = ?
                    GROUP BY pc.subcategory
                    """,
                arguments: [snapshotId, trackedPathIdString, category.rawValue]
            )

            var totals: [GrowthSubcategory?: Int64] = [:]
            for row in rows {
                let growthBytes: Int64 = row["growthBytes"] ?? 0
                guard growthBytes > 0 else { continue }

                let rawSubcategory: String = row["subcategory"] ?? ""
                let subcategory = rawSubcategory.isEmpty ? nil : GrowthSubcategory(rawValue: rawSubcategory)
                totals[subcategory, default: 0] += growthBytes
            }

            return totals
        }
    }
}

/// A file that contributed to growth since the last snapshot
struct GrowthContributor: Identifiable, Sendable, Equatable {
    var id: String { path }
    let path: String
    let currentSizeBytes: Int64
    let growthBytes: Int64
}

// MARK: - Snapshot Diff Growth Contributors

extension DatabaseManager {

    /// Compares two snapshots to find files that grew between them.
    /// Used as a fallback when working-set comparison returns nothing.
    func fetchSnapshotDiffContributors(
        latestSnapshotId: Int64,
        previousSnapshotId: Int64,
        category: GrowthCategory,
        subcategory: GrowthSubcategory?,
        limit: Int = 50
    ) async throws -> [GrowthContributor] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        let subcategoryRawValue = subcategory?.rawValue ?? ""
        let hasSubcategoryFilter = subcategory == nil ? 0 : 1

        return try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        p.path AS path,
                        newSe.sizeBytes AS currentSizeBytes,
                        newSe.sizeBytes - COALESCE(oldSe.sizeBytes, 0) AS growthBytes
                    FROM snapshotEntry newSe
                    JOIN pathClassification pc ON pc.pathId = newSe.pathId
                    JOIN paths p ON p.id = newSe.pathId
                    LEFT JOIN snapshotEntry oldSe
                        ON oldSe.pathId = newSe.pathId
                        AND oldSe.snapshotId = ?
                    WHERE newSe.snapshotId = ?
                        AND newSe.sizeBytes > COALESCE(oldSe.sizeBytes, 0)
                        AND pc.category = ?
                        AND (? = 0 OR pc.subcategory = ?)
                    ORDER BY growthBytes DESC
                    LIMIT ?
                    """,
                arguments: [
                    previousSnapshotId,
                    latestSnapshotId,
                    category.rawValue,
                    hasSubcategoryFilter,
                    subcategoryRawValue,
                    limit
                ]
            )

            return rows.map { row in
                let path: String = row["path"] ?? ""
                let currentSizeBytes: Int64 = row["currentSizeBytes"] ?? 0
                let growthBytes: Int64 = row["growthBytes"] ?? 0

                return GrowthContributor(
                    path: path,
                    currentSizeBytes: currentSizeBytes,
                    growthBytes: growthBytes
                )
            }
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

            return deltas
        }
    }
}

// MARK: - Custom Errors

extension DatabaseManager {
    enum DatabaseError: Error, LocalizedError {
        case directoryNotFound
        case notInitialized
        case pathLookupFailed(String)

        var errorDescription: String? {
            switch self {
            case .directoryNotFound:
                return "Could not find Application Support directory"
            case .notInitialized:
                return "Database has not been initialized"
            case .pathLookupFailed(let path):
                return "Failed to resolve path ID for: \(path)"
            }
        }
    }
}
