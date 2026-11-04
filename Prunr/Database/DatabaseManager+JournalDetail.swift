import Foundation
import GRDB

struct ChangeFeedInput: Sendable {
    let slots: [JournalSlot]
    let carries: [String: PlaceCount]
}

struct ClassificationNames: Sendable {
    let nameByCode: [Int64: String]
    let codeByName: [String: Int64]
}

final class ClassificationNameCache: @unchecked Sendable {
    private final class Entry {
        let names: ClassificationNames
        init(_ names: ClassificationNames) { self.names = names }
    }

    private let lock = NSLock()
    private let entriesByConnection = NSMapTable<Database, Entry>.weakToStrongObjects()

    func names(_ db: Database) throws -> ClassificationNames {
        lock.lock()
        let cached = entriesByConnection.object(forKey: db)?.names
        lock.unlock()
        if let cached { return cached }
        return try reload(db)
    }

    @discardableResult
    func reload(_ db: Database) throws -> ClassificationNames {
        var nameByCode: [Int64: String] = [:]
        var codeByName: [String: Int64] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT name, code FROM classificationName") {
            let name: String = row["name"]
            let code: Int64 = row["code"]
            nameByCode[code] = name
            codeByName[name] = code
        }
        let names = ClassificationNames(nameByCode: nameByCode, codeByName: codeByName)
        lock.lock()
        entriesByConnection.setObject(Entry(names), forKey: db)
        lock.unlock()
        return names
    }

    func name(code: Int64?, names: inout ClassificationNames, db: Database) throws -> String? {
        guard let code else { return nil }
        if let name = names.nameByCode[code] { return name }
        names = try reload(db)
        return names.nameByCode[code]
    }

    func code(name: String, names: inout ClassificationNames, db: Database) throws -> Int64 {
        if let code = names.codeByName[name] { return code }
        names = try reload(db)
        guard let code = names.codeByName[name] else {
            throw DatabaseManager.DatabaseError.classificationNameMissing(name)
        }
        return code
    }
}

extension DatabaseManager {
    static let journalDetailMigrationIdentifier = "v26_journal_detail"
    static let journalCheckpointMigrationIdentifier = "v27_journal_checkpoint"
    static let dropPrefixIndexesMigrationIdentifier = "v28_drop_prefix_indexes"
    static let snapshotEntryCountMigrationIdentifier = "v29_snapshot_entry_count"
    static let slimWorkingSetEntryMigrationIdentifier = "v30_slim_working_set_entry"
    static let pathDirsMigrationIdentifier = "v31_path_dirs"
    static let classificationCodesMigrationIdentifier = "v32_classification_codes"
    static let workingSetKeySQL = "(SELECT key FROM workingSetTrackedPath WHERE trackedPathId = ?)"
    static let heavyMigrationIdentifiers = [
        slimWorkingSetEntryMigrationIdentifier,
        pathDirsMigrationIdentifier,
        classificationCodesMigrationIdentifier
    ]
    static let classificationNameCache = ClassificationNameCache()

    static func registerJournalDetailMigration(in migrator: inout DatabaseMigrator) {
        // Migration v26: per-child detail of the growth journal (PRD L1). No
        // back-fill: per-file history before this is gone, so older rows keep
        // the sizes-now page.
        migrator.registerMigration(journalDetailMigrationIdentifier, foreignKeyChecks: .immediate) { db in
            try db.execute(sql: """
                CREATE TABLE growthJournalDetail (
                    trackedPathId TEXT NOT NULL,
                    unitRoot TEXT NOT NULL COLLATE NOCASE,
                    bucketStart DATETIME NOT NULL,
                    source TEXT NOT NULL,
                    name TEXT NOT NULL COLLATE NOCASE,
                    isFolder INTEGER NOT NULL,
                    deltaBytes INTEGER NOT NULL,
                    PRIMARY KEY (trackedPathId, unitRoot, bucketStart, source, name)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_growthJournalDetail_trackedPath_time
                ON growthJournalDetail(trackedPathId, bucketStart)
                """)
        }
    }

    static func registerJournalCheckpointMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(journalCheckpointMigrationIdentifier, foreignKeyChecks: .immediate) { db in
            try db.execute(sql: """
                CREATE TABLE growthJournalCheckpoint (
                    unitKey TEXT PRIMARY KEY,
                    asOf DATETIME NOT NULL,
                    countBytes INTEGER NOT NULL,
                    grossBytes INTEGER NOT NULL,
                    countStartDay DATETIME NOT NULL,
                    lastActiveDay DATETIME NOT NULL
                ) WITHOUT ROWID
                """)
        }
    }

    static func registerDropPrefixIndexesMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(dropPrefixIndexesMigrationIdentifier, foreignKeyChecks: .immediate) { db in
            try db.execute(sql: "DROP INDEX IF EXISTS idx_snapshotEntry_snapshotId")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_workingSetEntry_trackedPath")
        }
    }

    static func registerSnapshotEntryCountMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(snapshotEntryCountMigrationIdentifier, foreignKeyChecks: .immediate) { db in
            try db.alter(table: "snapshot") { t in
                t.add(column: "entryCount", .integer)
            }
        }
    }

    static func registerSlimWorkingSetEntryMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(slimWorkingSetEntryMigrationIdentifier, foreignKeyChecks: .immediate) { db in
            try db.execute(sql: """
                CREATE TABLE workingSetTrackedPath (
                    key INTEGER PRIMARY KEY,
                    trackedPathId TEXT NOT NULL UNIQUE,
                    updatedAt DATETIME
                )
                """)
            let hasLegacyTable = try db.tableExists("workingSetEntry")
            try db.execute(sql: """
                CREATE TABLE workingSetEntry_new (
                    trackedPathKey INTEGER NOT NULL,
                    pathId INTEGER NOT NULL REFERENCES paths(id) ON DELETE CASCADE,
                    sizeBytes INTEGER NOT NULL,
                    PRIMARY KEY (trackedPathKey, pathId)
                ) WITHOUT ROWID
                """)
            if hasLegacyTable {
                try Self.copyLegacyWorkingSetEntries(db)
            }
            try db.execute(sql: "ALTER TABLE workingSetEntry_new RENAME TO workingSetEntry")
            try db.execute(sql: "CREATE INDEX idx_workingSetEntry_pathId ON workingSetEntry(pathId)")
        }
    }

    private static func copyLegacyWorkingSetEntries(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO workingSetTrackedPath (trackedPathId, updatedAt)
            SELECT trackedPathId, MAX(updatedAt)
            FROM workingSetEntry
            GROUP BY trackedPathId
            ORDER BY trackedPathId
            """)
        try db.execute(sql: """
            INSERT INTO workingSetEntry_new (trackedPathKey, pathId, sizeBytes)
            SELECT t.key, w.pathId, w.sizeBytes
            FROM workingSetTrackedPath t
            CROSS JOIN workingSetEntry w ON w.trackedPathId = t.trackedPathId
            WHERE EXISTS (SELECT 1 FROM paths p WHERE p.id = w.pathId)
            ORDER BY t.key, w.pathId
            """)
        try db.execute(sql: "DROP TABLE workingSetEntry")
    }

    static func registerPathDirsMigration(in migrator: inout DatabaseMigrator) {
        migrator = migrator.disablingDeferredForeignKeyChecks()
        migrator.registerMigration(pathDirsMigrationIdentifier) { db in
            db.add(function: Self.pathDirFunction)
            let previousCacheSize = try Int.fetchOne(db, sql: "PRAGMA cache_size") ?? -2000
            try db.execute(sql: "PRAGMA cache_size = -131072")
            try db.execute(sql: """
                CREATE TABLE dirs (
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE COLLATE NOCASE
                )
                """)
            try db.execute(sql: """
                CREATE TABLE paths_new (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    dirId INTEGER NOT NULL REFERENCES dirs(id),
                    name TEXT NOT NULL COLLATE NOCASE
                )
                """)
            var pathSequence: Int64 = 0
            if try db.tableExists("paths") {
                pathSequence = try Int64.fetchOne(
                    db,
                    sql: "SELECT seq FROM sqlite_sequence WHERE name = 'paths'"
                ) ?? 0
                try Self.copyLegacyPaths(db)
            }
            try db.execute(sql: "ALTER TABLE paths_new RENAME TO paths")
            try db.execute(
                sql: """
                    INSERT INTO sqlite_sequence (name, seq)
                    SELECT 'paths', ? WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = 'paths')
                    """,
                arguments: [pathSequence]
            )
            try db.execute(
                sql: "UPDATE sqlite_sequence SET seq = MAX(seq, ?) WHERE name = 'paths'",
                arguments: [pathSequence]
            )
            try db.execute(sql: "CREATE UNIQUE INDEX idx_paths_dirId_name ON paths(dirId, name)")
            try db.execute(sql: """
                CREATE VIEW pathText AS
                SELECT p.id AS id, (d.path || p.name) COLLATE NOCASE AS path
                FROM paths p
                JOIN dirs d ON d.id = p.dirId
                """)
            try db.execute(sql: "DROP TABLE IF EXISTS workingSetRefreshStaging")
            try db.execute(sql: """
                CREATE TABLE workingSetRefreshStaging (
                    sessionId TEXT NOT NULL,
                    dir TEXT NOT NULL,
                    name TEXT NOT NULL,
                    sizeBytes INTEGER NOT NULL,
                    category TEXT NOT NULL,
                    subcategory TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY (sessionId, dir, name)
                )
                """)
            try db.execute(sql: "PRAGMA cache_size = \(previousCacheSize)")
        }
    }

    static func registerClassificationCodesMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(classificationCodesMigrationIdentifier, foreignKeyChecks: .immediate) { db in
            try db.execute(sql: """
                CREATE TABLE classificationName (
                    code INTEGER PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE
                )
                """)
            try Self.insertClassificationNames(db)
            try db.execute(sql: """
                CREATE TABLE pathClassification_new (
                    pathId INTEGER PRIMARY KEY NOT NULL REFERENCES paths(id) ON DELETE CASCADE,
                    category INTEGER NOT NULL,
                    subcategory INTEGER NOT NULL
                )
                """)
            if try db.tableExists("pathClassification") {
                try Self.copyLegacyPathClassification(db)
            }
            try db.execute(sql: "ALTER TABLE pathClassification_new RENAME TO pathClassification")
            try db.execute(sql: """
                CREATE INDEX idx_pathClassification_category_subcategory_pathId
                ON pathClassification(category, subcategory, pathId)
                """)
        }
    }

    private static func copyLegacyPathClassification(_ db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO classificationName (name)
            SELECT category FROM pathClassification
            UNION
            SELECT subcategory FROM pathClassification
            """)
        try db.execute(sql: """
            INSERT INTO pathClassification_new (pathId, category, subcategory)
            SELECT pc.pathId, c.code, s.code
            FROM pathClassification pc
            CROSS JOIN classificationName c ON c.name = pc.category
            CROSS JOIN classificationName s ON s.name = pc.subcategory
            WHERE EXISTS (SELECT 1 FROM paths p WHERE p.id = pc.pathId)
            ORDER BY pc.pathId
            """)
        try db.execute(sql: "DROP TABLE pathClassification")
    }

    static var classificationNames: [String] {
        [""] + GrowthCategory.allCases.map(\.rawValue) + GrowthSubcategory.allCases.map(\.rawValue)
    }

    static func insertClassificationNames(_ db: Database) throws {
        let insert = try db.makeStatement(sql: "INSERT OR IGNORE INTO classificationName (name) VALUES (?)")
        for name in classificationNames {
            try insert.execute(arguments: [name])
        }
        try classificationNameCache.reload(db)
    }

    static let classificationCodeSQL = "(SELECT code FROM classificationName WHERE name = ?)"

    static func classificationNameSQL(_ codeColumn: String) -> String {
        "(SELECT name FROM classificationName WHERE code = \(codeColumn))"
    }

    private static func copyLegacyPaths(_ db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO dirs (path)
            SELECT prunr_path_dir(path) FROM paths ORDER BY id
            """)
        try db.execute(sql: """
            INSERT INTO paths_new (id, dirId, name)
            SELECT p.id, d.id, substr(p.path, length(d.path) + 1)
            FROM paths p
            CROSS JOIN dirs d ON d.path = prunr_path_dir(p.path)
            ORDER BY p.id
            """)
        try db.execute(sql: "DROP TABLE paths")
    }

    static let pathDirFunction = DatabaseFunction("prunr_path_dir", argumentCount: 1, pure: true) { values in
        guard let path = String.fromDatabaseValue(values[0]) else { return nil }
        return DatabaseManager.splitPath(path).dir
    }

    static func splitPath(_ path: String) -> (dir: String, name: String) {
        let scalars = path.unicodeScalars
        guard let slash = scalars.lastIndex(of: "/") else { return ("", path) }
        let nameStart = scalars.index(after: slash)
        return (String(scalars[..<nameStart]), String(scalars[nameStart...]))
    }

    static let pathIdSQL = """
        SELECT p.id
        FROM dirs d
        CROSS JOIN paths p ON p.dirId = d.id AND p.name = ?
        WHERE d.path = ?
        """

    static func pathIdArguments(_ path: String) -> StatementArguments {
        let parts = splitPath(path)
        return [parts.name, parts.dir]
    }

    static func pathId(_ path: String, db: Database) throws -> Int64? {
        try Int64.fetchOne(db.cachedStatement(sql: pathIdSQL), arguments: pathIdArguments(path))
    }

    @discardableResult
    static func insertPath(_ path: String, id: Int64? = nil, db: Database) throws -> Int64? {
        let parts = splitPath(path)
        try db.cachedStatement(sql: "INSERT OR IGNORE INTO dirs (path) VALUES (?)")
            .execute(arguments: [parts.dir])
        try db.cachedStatement(sql: """
            INSERT OR IGNORE INTO paths (id, dirId, name)
            SELECT ?, id, ? FROM dirs WHERE path = ?
            """)
            .execute(arguments: [id, parts.name, parts.dir])
        return try pathId(path, db: db)
    }

    static func pathValuesSQL(count: Int) -> String {
        "WITH input(dir, name) AS (VALUES " + Array(repeating: "(?, ?)", count: count).joined(separator: ", ") + ")"
    }

    static func pathValueArguments(_ paths: [String]) -> [String] {
        var arguments: [String] = []
        arguments.reserveCapacity(paths.count * 2)
        for path in paths {
            let parts = splitPath(path)
            arguments.append(parts.dir)
            arguments.append(parts.name)
        }
        return arguments
    }

    static let subtreePathsSQL = """
        SELECT p.id AS id, d.path || p.name AS path
        FROM dirs d
        CROSS JOIN paths p ON p.dirId = d.id
        WHERE d.path >= ? AND d.path < ?
        UNION ALL
        SELECT p.id, d.path || p.name
        FROM dirs d
        CROSS JOIN paths p ON p.dirId = d.id AND p.name = ?
        WHERE d.path = ? AND ?
        """

    static func subtreeArguments(root normalizedRoot: String) -> StatementArguments {
        let rootPrefix = normalizedRoot == "/" ? "/" : normalizedRoot + "/"
        let parts = splitPath(normalizedRoot)
        return [rootPrefix, pathPrefixUpperBound(rootPrefix), parts.name, parts.dir, normalizedRoot != "/"]
    }

    static func keysetLowerDir(rootPrefix: String, afterPath: String?) -> (lowerDir: String, afterDir: String, afterName: String) {
        guard let afterPath else { return (rootPrefix, "", "") }
        let parts = splitPath(afterPath)
        let lowerDir = parts.dir.unicodeScalars.count >= rootPrefix.unicodeScalars.count ? parts.dir : rootPrefix
        return (lowerDir, parts.dir, parts.name)
    }

    static func workingSetKey(trackedPathId: String, db: Database) throws -> Int64 {
        try db.execute(
            sql: "INSERT OR IGNORE INTO workingSetTrackedPath (trackedPathId) VALUES (?)",
            arguments: [trackedPathId]
        )
        guard let key = try Int64.fetchOne(
            db,
            sql: "SELECT key FROM workingSetTrackedPath WHERE trackedPathId = ?",
            arguments: [trackedPathId]
        ) else {
            throw DatabaseError.workingSetKeyMissing(trackedPathId)
        }
        return key
    }

    static func touchWorkingSet(key: Int64, updatedAt: Date, db: Database) throws {
        try db.execute(
            sql: "UPDATE workingSetTrackedPath SET updatedAt = MAX(COALESCE(updatedAt, ?), ?) WHERE key = ?",
            arguments: [updatedAt, updatedAt, key]
        )
    }

    static func clearWorkingSetRows(trackedPathId: String, db: Database) throws {
        try db.execute(
            sql: "DELETE FROM workingSetEntry WHERE trackedPathKey = \(workingSetKeySQL)",
            arguments: [trackedPathId]
        )
        try db.execute(
            sql: "UPDATE workingSetTrackedPath SET updatedAt = NULL WHERE trackedPathId = ?",
            arguments: [trackedPathId]
        )
    }

    func fetchJournalCheckpoints() async throws -> [JournalCheckpoint] {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            try Self.fetchJournalCheckpoints(db: db)
        }
    }

    /// Every slot of these paths and the checkpoints, read in one transaction
    /// so a prune in between cannot count a day twice.
    func fetchChangeFeedInput(trackedPathIds: [UUID]) async throws -> ChangeFeedInput {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            let slots = try Self.fetchJournalSlots(
                db: db,
                trackedPathIds: trackedPathIds,
                since: Date(timeIntervalSince1970: 0)
            )
            let checkpoints = try Self.fetchJournalCheckpoints(db: db)
            return ChangeFeedInput(
                slots: slots,
                carries: Dictionary(uniqueKeysWithValues: checkpoints.map { ($0.unitKey, $0.state) })
            )
        }
    }

    func replaceJournalCheckpoints(_ checkpoints: [JournalCheckpoint]) async throws {
        guard let dbPool = dbPool else {
            throw DatabaseError.notInitialized
        }

        try await dbPool.write { db in
            try Self.replaceJournalCheckpoints(checkpoints, db: db)
        }
    }

    static func fetchJournalCheckpoints(db: Database) throws -> [JournalCheckpoint] {
        try Row.fetchAll(db, sql: "SELECT * FROM growthJournalCheckpoint").map { row in
            JournalCheckpoint(
                unitKey: row["unitKey"],
                asOf: row["asOf"],
                countBytes: row["countBytes"],
                grossBytes: row["grossBytes"],
                countStartDay: row["countStartDay"],
                lastActiveDay: row["lastActiveDay"]
            )
        }
    }

    static func replaceJournalCheckpoints(_ checkpoints: [JournalCheckpoint], db: Database) throws {
        try deleteJournalCheckpoints(db: db)
        let statement = try db.makeStatement(
            sql: """
                INSERT INTO growthJournalCheckpoint
                    (unitKey, asOf, countBytes, grossBytes, countStartDay, lastActiveDay)
                VALUES (?, ?, ?, ?, ?, ?)
                """
        )
        for checkpoint in checkpoints {
            try statement.execute(arguments: [
                checkpoint.unitKey,
                checkpoint.asOf,
                checkpoint.countBytes,
                checkpoint.grossBytes,
                checkpoint.countStartDay,
                checkpoint.lastActiveDay
            ])
        }
    }

    static func deleteJournalCheckpoints(db: Database) throws {
        try db.execute(sql: "DELETE FROM growthJournalCheckpoint")
    }

    static func deleteJournalCheckpoints(trackedPathId: String, db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM growthJournalCheckpoint
                WHERE unitKey IN (
                    SELECT DISTINCT unitKey FROM growthJournalBucket WHERE trackedPathId = ?
                )
                """,
            arguments: [trackedPathId]
        )
    }

    /// Adds per-child deltas to one bucket inside the caller's write
    /// transaction, bounded to the top children per place.
    static func writeJournalDetail(
        _ deltas: [PlaceChildKey: Int64],
        trackedPathId: String,
        bucketStart: Date,
        source: GrowthJournalBucket.Source,
        db: Database
    ) throws {
        let bounded = GrowthJournalDetail.bounded(deltas)
        guard !bounded.isEmpty else { return }
        let upsert = try db.cachedStatement(sql: """
            INSERT INTO growthJournalDetail (trackedPathId, unitRoot, bucketStart, source, name, isFolder, deltaBytes)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(trackedPathId, unitRoot, bucketStart, source, name) DO UPDATE SET
                deltaBytes = deltaBytes + excluded.deltaBytes,
                isFolder = MAX(isFolder, excluded.isFolder)
            """)
        for (child, deltaBytes) in bounded {
            try upsert.execute(arguments: [
                trackedPathId, child.unitRoot, bucketStart, source.rawValue, child.name, child.isFolder, deltaBytes
            ])
        }
    }

    /// Writes per-child deltas for many buckets in one transaction.
    func upsertJournalDetail(
        trackedPathId: UUID,
        deltasByBucketStart: [Date: [PlaceChildKey: Int64]],
        source: GrowthJournalBucket.Source
    ) async throws {
        guard let dbPool else { throw DatabaseError.notInitialized }
        guard deltasByBucketStart.values.contains(where: { !$0.isEmpty }) else { return }
        let trackedPathIdString = trackedPathId.uuidString

        try await dbPool.write { db in
            for (bucketStart, deltas) in deltasByBucketStart {
                try Self.writeJournalDetail(
                    deltas,
                    trackedPathId: trackedPathIdString,
                    bucketStart: bucketStart,
                    source: source,
                    db: db
                )
            }
        }
    }

    /// Signed per-child totals for buckets in `(from, to]`, across every
    /// source: what a full scan's per-child residual is computed against.
    func fetchJournalDetailTotals(
        trackedPathId: UUID,
        from: Date,
        to: Date
    ) async throws -> [PlaceChildKey: Int64] {
        guard let dbPool else { throw DatabaseError.notInitialized }
        let trackedPathIdString = trackedPathId.uuidString

        return try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT unitRoot, name, MAX(isFolder) AS isFolder, SUM(deltaBytes) AS totalDelta
                    FROM growthJournalDetail
                    WHERE trackedPathId = ? AND bucketStart > ? AND bucketStart <= ?
                    GROUP BY unitRoot, name
                    """,
                arguments: [trackedPathIdString, from, to]
            )
            var result: [PlaceChildKey: Int64] = [:]
            for row in rows {
                let unitRoot: String = row["unitRoot"] ?? ""
                let name: String = row["name"] ?? ""
                let isFolder: Bool = row["isFolder"] ?? false
                let totalDelta: Int64 = row["totalDelta"] ?? 0
                result[PlaceChildKey(unitRoot: unitRoot, name: name, isFolder: isFolder), default: 0] += totalDelta
            }
            return result
        }
    }

    static func deleteJournalDetail(trackedPathId: String?, db: Database) throws {
        if let trackedPathId {
            try db.execute(sql: "DELETE FROM growthJournalDetail WHERE trackedPathId = ?", arguments: [trackedPathId])
        } else {
            try db.execute(sql: "DELETE FROM growthJournalDetail")
        }
    }
}
