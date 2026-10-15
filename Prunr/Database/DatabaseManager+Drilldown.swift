import Foundation
import GRDB

/// One file's classification and size in the working set.
struct WorkingSetFileState: Sendable, Equatable {
    let category: GrowthCategory
    let subcategory: GrowthSubcategory?
    let sizeBytes: Int64
}

/// A working-set file before and after one write. `old == nil` is a new file,
/// `new == nil` a removed one.
struct WorkingSetFileChange: Sendable {
    let pathId: Int64
    let path: String
    let old: WorkingSetFileState?
    let new: WorkingSetFileState?
}

struct DrilldownGroupRow: Sendable, Equatable {
    let category: GrowthCategory
    let groupKey: String
    let totalBytes: Int64
    let fileCount: Int
    /// The stored top files are a correct but shortened prefix of the group.
    let isTopShort: Bool
}

struct DrilldownGroupsSnapshot: Sendable, Equatable {
    let rows: [DrilldownGroupRow]
    /// Tracked paths whose index has not been built yet (first launch after the upgrade).
    let buildingTrackedPathIds: Set<UUID>
}

struct DrilldownFileEntry: Sendable, Equatable {
    let groupKey: String
    let path: String
    let sizeBytes: Int64
}

struct PlaceChild: Identifiable, Sendable, Equatable {
    var id: String { path }
    /// Last path component; the root's own name for a file unit.
    let name: String
    let path: String
    let isFolder: Bool
    let totalBytes: Int64
    let fileCount: Int
}

struct DrilldownCategoryContents: Sendable, Equatable {
    let rows: [DrilldownGroupRow]
    let files: [DrilldownFileEntry]
}

struct PlaceContentsPage: Sendable, Equatable {
    let children: [PlaceChild]
    let hasMore: Bool
}

extension DatabaseManager {
    enum DrilldownIndexState: String {
        case building
        case ready
    }

    /// `prunr_owner_group(path)`: the owner group key of an Apps & System file
    /// (`DrilldownGroupKey.ownerKey`). Pure, so SQLite may cache results within a statement.
    static let ownerGroupFunction = DatabaseFunction("prunr_owner_group", argumentCount: 1, pure: true) { values in
        guard let path = String.fromDatabaseValue(values[0]) else { return nil }
        return DrilldownGroupKey.ownerKey(path: path)
    }

    static func registerDrilldownIndexMigration(in migrator: inout DatabaseMigrator) {
        // Migration v23: exact drilldown index next to the working set. History
        // starts fresh: the journal (incl. pre-unit rows) is cleared and the
        // index is rebuilt in the background from the existing working set.
        migrator.registerMigration(drilldownIndexMigrationIdentifier) { db in
            try db.execute(sql: """
                CREATE TABLE workingSetGroupTotal (
                    trackedPathId TEXT NOT NULL,
                    category TEXT NOT NULL,
                    groupKey TEXT NOT NULL,
                    totalBytes INTEGER NOT NULL,
                    fileCount INTEGER NOT NULL,
                    topShort INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (trackedPathId, category, groupKey)
                )
                """)
            try db.execute(sql: """
                CREATE TABLE workingSetTopEntry (
                    trackedPathId TEXT NOT NULL,
                    pathId INTEGER NOT NULL REFERENCES paths(id) ON DELETE CASCADE,
                    category TEXT NOT NULL,
                    groupKey TEXT NOT NULL,
                    sizeBytes INTEGER NOT NULL,
                    PRIMARY KEY (trackedPathId, pathId)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_workingSetTopEntry_group_size
                ON workingSetTopEntry(trackedPathId, category, groupKey, sizeBytes DESC, pathId)
                """)
            try db.execute(sql: """
                CREATE TABLE workingSetPlaceChild (
                    trackedPathId TEXT NOT NULL,
                    unitRoot TEXT NOT NULL COLLATE NOCASE,
                    name TEXT NOT NULL COLLATE NOCASE,
                    isFolder INTEGER NOT NULL,
                    totalBytes INTEGER NOT NULL,
                    fileCount INTEGER NOT NULL,
                    PRIMARY KEY (trackedPathId, unitRoot, name)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_workingSetPlaceChild_size
                ON workingSetPlaceChild(trackedPathId, unitRoot, totalBytes DESC, name)
                """)
            try db.execute(sql: """
                CREATE TABLE workingSetIndexState (
                    trackedPathId TEXT PRIMARY KEY NOT NULL,
                    state TEXT NOT NULL
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO workingSetIndexState (trackedPathId, state)
                    SELECT DISTINCT trackedPathId, ? FROM workingSetCategoryTotal
                    """,
                arguments: [DrilldownIndexState.building.rawValue]
            )
            try db.execute(sql: "DELETE FROM growthJournalBucket")
            try db.execute(sql: "DROP TABLE IF EXISTS subcategorySnapshot")
        }
    }

    static let drilldownIndexMigrationIdentifier = "v23_drilldown_index"

    static func registerOwnerUnitsMigration(in migrator: inout DatabaseMigrator) {
        // Migration v24: places grouped by owner. Unit keys changed (Preferences
        // and flat Library areas collapse, vendor folders go one deeper, hidden
        // home folders are tool units, DerivedData is found by shape) and so did
        // the classification of user folders, hidden folders, Steam games and the
        // Homebrew cache. History starts fresh: the journal is cleared, the
        // changed classifications and category totals are recomputed, and the
        // drilldown index is rebuilt in the background.
        migrator.registerMigration(ownerUnitsMigrationIdentifier) { db in
            let changed = try reclassifyOwnerUnitPaths(db: db)
            if changed > 0 {
                try db.execute(sql: "DELETE FROM workingSetCategoryTotal")
                try db.execute(sql: """
                    INSERT INTO workingSetCategoryTotal (trackedPathId, category, totalBytes, updatedAt)
                    SELECT wse.trackedPathId, pc.category, COALESCE(SUM(wse.sizeBytes), 0) AS totalBytes,
                           MAX(wse.updatedAt) AS updatedAt
                    FROM workingSetEntry wse
                    JOIN pathClassification pc ON pc.pathId = wse.pathId
                    GROUP BY wse.trackedPathId, pc.category
                    HAVING totalBytes > 0
                    """)
            }
            try db.execute(
                sql: """
                    INSERT INTO workingSetIndexState (trackedPathId, state)
                    SELECT DISTINCT trackedPathId, ? FROM workingSetCategoryTotal WHERE true
                    ON CONFLICT(trackedPathId) DO UPDATE SET state = excluded.state
                    """,
                arguments: [DrilldownIndexState.building.rawValue]
            )
            try db.execute(sql: "DELETE FROM growthJournalBucket")
        }
    }

    static let ownerUnitsMigrationIdentifier = "v24_owner_units"

    static func registerOwnerGroupsMigration(in migrator: inout DatabaseMigrator) {
        // Migration v25: Apps & System groups its files by owner instead of by
        // cache subcategory. Only the drilldown index's group keys change, so the
        // index is rebuilt in the background; history is kept.
        migrator.registerMigration(ownerGroupsMigrationIdentifier) { db in
            try db.execute(
                sql: """
                    INSERT INTO workingSetIndexState (trackedPathId, state)
                    SELECT DISTINCT trackedPathId, ? FROM workingSetCategoryTotal WHERE true
                    ON CONFLICT(trackedPathId) DO UPDATE SET state = excluded.state
                    """,
                arguments: [DrilldownIndexState.building.rawValue]
            )
        }
    }

    static let ownerGroupsMigrationIdentifier = "v25_owner_groups"

    /// Reclassifies the paths whose category the v24 rules can change: the
    /// former "Other", Steam games, the Homebrew cache and Xcode build folders
    /// outside Developer. Returns the number of changed rows.
    private static func reclassifyOwnerUnitPaths(db: Database) throws -> Int {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT pc.pathId AS pathId, p.path AS path, pc.category AS category, pc.subcategory AS subcategory
            FROM pathClassification pc
            JOIN paths p ON p.id = pc.pathId
            WHERE pc.category = 'other'
               OR p.path LIKE '%/steamapps/common/%'
               OR p.path LIKE '%/Library/Caches/Homebrew%'
               OR (pc.category <> 'developer' AND (p.path LIKE '%.noindex/%' OR p.path LIKE '%/Build/Products/%'))
            """)
        var changes: [(pathId: Int64, category: String, subcategory: String)] = []
        while let row = try cursor.next() {
            guard let pathId: Int64 = row["pathId"], let path: String = row["path"] else { continue }
            let (category, subcategory) = GrowthCategory.classify(path: path)
            let newSubcategory = subcategory?.rawValue ?? ""
            let oldCategory: String = row["category"] ?? ""
            let oldSubcategory: String = row["subcategory"] ?? ""
            if category.rawValue != oldCategory || newSubcategory != oldSubcategory {
                changes.append((pathId, category.rawValue, newSubcategory))
            }
        }
        let update = try db.makeStatement(sql: "UPDATE pathClassification SET category = ?, subcategory = ? WHERE pathId = ?")
        for change in changes {
            try update.execute(arguments: [change.category, change.subcategory, change.pathId])
        }
        return changes.count
    }

    // MARK: - Delta maintenance

    private struct GroupRef: Hashable {
        let category: GrowthCategory
        let groupKey: String
    }

    private struct ResolvedChange {
        let change: WorkingSetFileChange
        let unitKey: String
        let oldGroup: GroupRef?
        let newGroup: GroupRef?
    }

    /// Applies file changes to every working-set derived table (category totals,
    /// drilldown groups, top files, place children) inside the caller's write
    /// transaction, after `workingSetEntry` itself was updated. Returns the
    /// journal deltas per (category, subcategory, unit).
    static func applyWorkingSetChanges(
        _ changes: [WorkingSetFileChange],
        trackedPathId: String,
        updatedAt: Date,
        db: Database
    ) throws -> [JournalDeltaKey: Int64] {
        let effective = changes.filter { $0.old != $0.new }
        guard !effective.isEmpty else { return [:] }

        let resolved = effective.map { change in
            let unitKey = UnitResolver.resolve(path: change.path)
            return ResolvedChange(
                change: change,
                unitKey: unitKey,
                oldGroup: change.old.map { groupRef(for: $0, unitKey: unitKey) },
                newGroup: change.new.map { groupRef(for: $0, unitKey: unitKey) }
            )
        }

        var journal: [JournalDeltaKey: Int64] = [:]
        var categoryDeltas: [GrowthCategory: Int64] = [:]
        var groupDeltas: [GroupRef: DrilldownIndexBuilder.Totals] = [:]
        var placeDeltas: [PlaceChildKey: DrilldownIndexBuilder.Totals] = [:]

        for item in resolved {
            let placeChild = PlaceChildKey(path: item.change.path, unitKey: item.unitKey)
            if let old = item.change.old, let group = item.oldGroup {
                journal[JournalDeltaKey(category: old.category, subcategory: old.subcategory, unitKey: item.unitKey), default: 0] -= old.sizeBytes
                categoryDeltas[old.category, default: 0] -= old.sizeBytes
                groupDeltas[group, default: .init()].totalBytes -= old.sizeBytes
                groupDeltas[group, default: .init()].fileCount -= 1
                if let placeChild {
                    placeDeltas[placeChild, default: .init()].totalBytes -= old.sizeBytes
                    placeDeltas[placeChild, default: .init()].fileCount -= 1
                }
            }
            if let new = item.change.new, let group = item.newGroup {
                journal[JournalDeltaKey(category: new.category, subcategory: new.subcategory, unitKey: item.unitKey), default: 0] += new.sizeBytes
                categoryDeltas[new.category, default: 0] += new.sizeBytes
                groupDeltas[group, default: .init()].totalBytes += new.sizeBytes
                groupDeltas[group, default: .init()].fileCount += 1
                if let placeChild {
                    placeDeltas[placeChild, default: .init()].totalBytes += new.sizeBytes
                    placeDeltas[placeChild, default: .init()].fileCount += 1
                }
            }
        }

        try applyWorkingSetCategoryDeltas(
            categoryDeltas,
            trackedPathId: trackedPathId,
            updatedAt: updatedAt,
            db: db
        )
        try applyGroupDeltas(groupDeltas, trackedPathId: trackedPathId, db: db)
        try applyTopEntryChanges(resolved, trackedPathId: trackedPathId, db: db)
        try applyPlaceChildDeltas(placeDeltas, trackedPathId: trackedPathId, db: db)

        return journal.filter { $0.value != 0 }
    }

    private static func groupRef(for state: WorkingSetFileState, unitKey: String) -> GroupRef {
        GroupRef(
            category: state.category,
            groupKey: DrilldownGroupKey.make(category: state.category, subcategory: state.subcategory, unitKey: unitKey)
        )
    }

    private static func applyGroupDeltas(
        _ deltas: [GroupRef: DrilldownIndexBuilder.Totals],
        trackedPathId: String,
        db: Database
    ) throws {
        let upsert = try db.cachedStatement(sql: """
            INSERT INTO workingSetGroupTotal (trackedPathId, category, groupKey, totalBytes, fileCount, topShort)
            VALUES (?, ?, ?, MAX(0, ?), MAX(0, ?), 0)
            ON CONFLICT(trackedPathId, category, groupKey) DO UPDATE SET
                totalBytes = MAX(0, workingSetGroupTotal.totalBytes + ?),
                fileCount = MAX(0, workingSetGroupTotal.fileCount + ?)
            """)
        let deleteEmpty = try db.cachedStatement(sql: """
            DELETE FROM workingSetGroupTotal
            WHERE trackedPathId = ? AND category = ? AND groupKey = ? AND fileCount <= 0
            """)
        for (group, delta) in deltas where delta.totalBytes != 0 || delta.fileCount != 0 {
            try upsert.execute(arguments: [
                trackedPathId, group.category.rawValue, group.groupKey,
                delta.totalBytes, delta.fileCount, delta.totalBytes, delta.fileCount
            ])
            try deleteEmpty.execute(arguments: [trackedPathId, group.category.rawValue, group.groupKey])
        }
    }

    /// Keeps each group's stored top files a correct prefix of the group's
    /// (size DESC) order. Invariant: every file of the group that is not
    /// stored is no larger than the smallest stored one. A file is (re)inserted
    /// when that cannot break the invariant: the group has no other unstored
    /// files, or the file is at least the smallest stored size before this
    /// batch. Anything else only shortens the prefix (`topShort`), refilled later.
    private static func applyTopEntryChanges(
        _ changes: [ResolvedChange],
        trackedPathId: String,
        db: Database
    ) throws {
        var touched = Set<GroupRef>()
        var candidates: [GroupRef: [(pathId: Int64, sizeBytes: Int64)]] = [:]
        for item in changes {
            if let group = item.oldGroup { touched.insert(group) }
            if let group = item.newGroup, let new = item.change.new {
                touched.insert(group)
                candidates[group, default: []].append((item.change.pathId, new.sizeBytes))
            }
        }
        guard !touched.isEmpty else { return }

        let stats = try db.cachedStatement(sql: """
            SELECT COUNT(*), MIN(sizeBytes) FROM workingSetTopEntry
            WHERE trackedPathId = ? AND category = ? AND groupKey = ?
            """)
        var before: [GroupRef: (rows: Int, minSize: Int64?)] = [:]
        for group in touched {
            let row = try Row.fetchOne(stats, arguments: [trackedPathId, group.category.rawValue, group.groupKey])
            let rows: Int = row.flatMap { $0[0] as Int? } ?? 0
            let minSize: Int64? = row.flatMap { $0[1] as Int64? }
            before[group] = (rows: rows, minSize: minSize)
        }

        let deletePath = try db.cachedStatement(sql: """
            DELETE FROM workingSetTopEntry WHERE trackedPathId = ? AND pathId = ?
            """)
        for item in changes {
            try deletePath.execute(arguments: [trackedPathId, item.change.pathId])
        }

        let fileCountStatement = try db.cachedStatement(sql: """
            SELECT fileCount FROM workingSetGroupTotal
            WHERE trackedPathId = ? AND category = ? AND groupKey = ?
            """)
        let insert = try db.cachedStatement(sql: """
            INSERT OR REPLACE INTO workingSetTopEntry (trackedPathId, pathId, category, groupKey, sizeBytes)
            VALUES (?, ?, ?, ?, ?)
            """)

        for group in touched {
            let groupArguments: StatementArguments = [trackedPathId, group.category.rawValue, group.groupKey]
            let fileCount = try Int.fetchOne(fileCountStatement, arguments: groupArguments) ?? 0
            guard fileCount > 0 else {
                try deleteTopEntries(of: group, trackedPathId: trackedPathId, db: db)
                continue
            }

            let rowsNow = try Int.fetchOne(stats, arguments: groupArguments) ?? 0
            let groupCandidates = candidates[group] ?? []
            let unstoredOthers = fileCount - rowsNow - groupCandidates.count
            let accepted: [(pathId: Int64, sizeBytes: Int64)]
            if unstoredOthers <= 0 {
                accepted = groupCandidates
            } else if let previous = before[group], previous.rows > 0, let minSize = previous.minSize {
                accepted = groupCandidates.filter { $0.sizeBytes >= minSize }
            } else {
                accepted = []
            }

            for candidate in accepted {
                try insert.execute(arguments: [
                    trackedPathId, candidate.pathId, group.category.rawValue, group.groupKey, candidate.sizeBytes
                ])
            }
            if rowsNow + accepted.count > DrilldownIndexBuilder.topLimit {
                try trimTopEntries(of: group, trackedPathId: trackedPathId, db: db)
            }
            let stored = min(DrilldownIndexBuilder.topLimit, rowsNow + accepted.count)
            try setTopShort(
                stored < min(DrilldownIndexBuilder.topLimit, fileCount),
                group: group,
                trackedPathId: trackedPathId,
                db: db
            )
        }
    }

    private static func deleteTopEntries(of group: GroupRef, trackedPathId: String, db: Database) throws {
        try db.execute(
            sql: "DELETE FROM workingSetTopEntry WHERE trackedPathId = ? AND category = ? AND groupKey = ?",
            arguments: [trackedPathId, group.category.rawValue, group.groupKey]
        )
    }

    private static func trimTopEntries(of group: GroupRef, trackedPathId: String, db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM workingSetTopEntry
                WHERE trackedPathId = ? AND category = ? AND groupKey = ?
                  AND pathId NOT IN (
                    SELECT pathId FROM workingSetTopEntry
                    WHERE trackedPathId = ? AND category = ? AND groupKey = ?
                    ORDER BY sizeBytes DESC, pathId
                    LIMIT ?
                  )
                """,
            arguments: [
                trackedPathId, group.category.rawValue, group.groupKey,
                trackedPathId, group.category.rawValue, group.groupKey,
                DrilldownIndexBuilder.topLimit
            ]
        )
    }

    private static func setTopShort(_ isShort: Bool, group: GroupRef, trackedPathId: String, db: Database) throws {
        try db.execute(
            sql: """
                UPDATE workingSetGroupTotal SET topShort = ?
                WHERE trackedPathId = ? AND category = ? AND groupKey = ?
                """,
            arguments: [isShort ? 1 : 0, trackedPathId, group.category.rawValue, group.groupKey]
        )
    }

    private static func applyPlaceChildDeltas(
        _ deltas: [PlaceChildKey: DrilldownIndexBuilder.Totals],
        trackedPathId: String,
        db: Database
    ) throws {
        let upsert = try db.cachedStatement(sql: """
            INSERT INTO workingSetPlaceChild (trackedPathId, unitRoot, name, isFolder, totalBytes, fileCount)
            VALUES (?, ?, ?, ?, MAX(0, ?), MAX(0, ?))
            ON CONFLICT(trackedPathId, unitRoot, name) DO UPDATE SET
                totalBytes = MAX(0, workingSetPlaceChild.totalBytes + ?),
                fileCount = MAX(0, workingSetPlaceChild.fileCount + ?),
                isFolder = CASE WHEN ? > 0 THEN ? ELSE workingSetPlaceChild.isFolder END
            """)
        let deleteEmpty = try db.cachedStatement(sql: """
            DELETE FROM workingSetPlaceChild
            WHERE trackedPathId = ? AND unitRoot = ? AND name = ? AND fileCount <= 0
            """)
        for (child, delta) in deltas where delta.totalBytes != 0 || delta.fileCount != 0 {
            let isFolder = child.isFolder ? 1 : 0
            try upsert.execute(arguments: [
                trackedPathId, child.unitRoot, child.name, isFolder,
                delta.totalBytes, delta.fileCount,
                delta.totalBytes, delta.fileCount,
                delta.fileCount, isFolder
            ])
            try deleteEmpty.execute(arguments: [trackedPathId, child.unitRoot, child.name])
        }
    }

    // MARK: - Rebuild

    /// Replaces the drilldown index of a tracked path with a builder's result.
    /// Runs in the caller's write transaction, next to the working-set write
    /// the builder describes, so both flip together.
    static func replaceDrilldownIndex(
        trackedPathId: String,
        builder: DrilldownIndexBuilder,
        db: Database
    ) throws {
        try clearDrilldownIndexRows(trackedPathId: trackedPathId, db: db)

        let insertGroup = try db.cachedStatement(sql: """
            INSERT INTO workingSetGroupTotal (trackedPathId, category, groupKey, totalBytes, fileCount, topShort)
            VALUES (?, ?, ?, ?, ?, ?)
            """)
        let insertTop = try db.cachedStatement(sql: """
            INSERT OR REPLACE INTO workingSetTopEntry (trackedPathId, pathId, category, groupKey, sizeBytes)
            VALUES (?, ?, ?, ?, ?)
            """)
        let pathIdStatement = try db.cachedStatement(sql: "SELECT id FROM paths WHERE path = ?")

        for (id, group) in builder.groups {
            var stored = 0
            for file in builder.topFiles(of: id) {
                let pathId: Int64?
                if let knownId = file.pathId {
                    pathId = knownId
                } else {
                    pathId = try Int64.fetchOne(pathIdStatement, arguments: [file.path])
                }
                guard let pathId else { continue }
                try insertTop.execute(arguments: [trackedPathId, pathId, id.category.rawValue, id.groupKey, file.sizeBytes])
                stored += 1
            }
            let isShort = stored < min(DrilldownIndexBuilder.topLimit, group.fileCount)
            try insertGroup.execute(arguments: [
                trackedPathId, id.category.rawValue, id.groupKey, group.totalBytes, group.fileCount, isShort ? 1 : 0
            ])
        }

        try applyPlaceChildDeltas(builder.placeChildren, trackedPathId: trackedPathId, db: db)
        try setDrilldownIndexState(.ready, trackedPathId: trackedPathId, db: db)
    }

    /// Recomputes the index from the working set in one pass, inside the
    /// caller's write transaction.
    static func rebuildDrilldownIndex(trackedPathId: String, db: Database) throws {
        let builder = try drilldownIndexBuilder(fromWorkingSetOf: trackedPathId, db: db)
        try replaceDrilldownIndex(trackedPathId: trackedPathId, builder: builder, db: db)
    }

    static func drilldownIndexBuilder(fromWorkingSetOf trackedPathId: String, db: Database) throws -> DrilldownIndexBuilder {
        var builder = DrilldownIndexBuilder()
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT wse.pathId AS pathId, p.path AS path, wse.sizeBytes AS sizeBytes,
                       pc.category AS category, pc.subcategory AS subcategory
                FROM workingSetEntry wse
                JOIN pathClassification pc ON pc.pathId = wse.pathId
                JOIN paths p ON p.id = wse.pathId
                WHERE wse.trackedPathId = ?
                """,
            arguments: [trackedPathId]
        )
        while let row = try cursor.next() {
            guard let rawCategory: String = row["category"],
                  let category = GrowthCategory(rawValue: rawCategory) else { continue }
            let rawSubcategory: String = row["subcategory"] ?? ""
            builder.add(
                path: row["path"] ?? "",
                pathId: row["pathId"],
                sizeBytes: row["sizeBytes"] ?? 0,
                category: category,
                subcategory: GrowthSubcategory(rawValue: rawSubcategory)
            )
        }
        return builder
    }

    static func clearDrilldownIndex(trackedPathId: String?, db: Database) throws {
        if let trackedPathId {
            try clearDrilldownIndexRows(trackedPathId: trackedPathId, db: db)
            try setDrilldownIndexState(.ready, trackedPathId: trackedPathId, db: db)
        } else {
            try db.execute(sql: "DELETE FROM workingSetGroupTotal")
            try db.execute(sql: "DELETE FROM workingSetTopEntry")
            try db.execute(sql: "DELETE FROM workingSetPlaceChild")
            try db.execute(sql: "DELETE FROM workingSetIndexState")
        }
    }

    private static func clearDrilldownIndexRows(trackedPathId: String, db: Database) throws {
        for table in ["workingSetGroupTotal", "workingSetTopEntry", "workingSetPlaceChild"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE trackedPathId = ?", arguments: [trackedPathId])
        }
    }

    private static func setDrilldownIndexState(_ state: DrilldownIndexState, trackedPathId: String, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO workingSetIndexState (trackedPathId, state) VALUES (?, ?)
                ON CONFLICT(trackedPathId) DO UPDATE SET state = excluded.state
                """,
            arguments: [trackedPathId, state.rawValue]
        )
    }

    /// Builds the index for every tracked path still marked `building` (after
    /// the v23 upgrade). Each path is rebuilt in its own write transaction, so
    /// concurrent working-set writes either land before (and are included) or
    /// after (and are applied as deltas). Returns the rebuilt paths.
    @discardableResult
    func rebuildDrilldownIndexIfNeeded() async throws -> [String] {
        guard let dbPool else { throw DatabaseError.notInitialized }

        let pending = try await dbPool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT trackedPathId FROM workingSetIndexState WHERE state = ?",
                arguments: [DrilldownIndexState.building.rawValue]
            )
        }
        for trackedPathId in pending {
            try await dbPool.write { db in
                try Self.rebuildDrilldownIndex(trackedPathId: trackedPathId, db: db)
            }
        }
        return pending
    }

    func rebuildDrilldownIndex(trackedPathId: UUID) async throws {
        guard let dbPool else { throw DatabaseError.notInitialized }
        try await dbPool.write { db in
            try Self.rebuildDrilldownIndex(trackedPathId: trackedPathId.uuidString, db: db)
        }
    }

    /// Refills groups whose stored top files were shortened by deltas.
    /// Returns the number of refilled groups.
    @discardableResult
    func refillShortTopGroups(trackedPathId: UUID) async throws -> Int {
        guard let dbPool else { throw DatabaseError.notInitialized }
        let trackedPathIdString = trackedPathId.uuidString

        let shortGroups: [GroupRef] = try await dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT category, groupKey FROM workingSetGroupTotal WHERE trackedPathId = ? AND topShort = 1",
                arguments: [trackedPathIdString]
            ).compactMap { row in
                guard let rawCategory: String = row["category"],
                      let category = GrowthCategory(rawValue: rawCategory) else { return nil }
                return GroupRef(category: category, groupKey: row["groupKey"] ?? "")
            }
        }

        var refilled = 0
        for group in shortGroups {
            let didRefill = try await dbPool.write { db -> Bool in
                let isStillShort = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT topShort FROM workingSetGroupTotal
                        WHERE trackedPathId = ? AND category = ? AND groupKey = ?
                        """,
                    arguments: [trackedPathIdString, group.category.rawValue, group.groupKey]
                ) ?? false
                guard isStillShort else { return false }

                let rows = try Self.fetchGroupFiles(
                    trackedPathId: trackedPathIdString,
                    category: group.category,
                    groupKeys: [group.groupKey],
                    offset: 0,
                    limit: DrilldownIndexBuilder.topLimit,
                    db: db
                )
                try Self.deleteTopEntries(of: group, trackedPathId: trackedPathIdString, db: db)
                let insert = try db.cachedStatement(sql: """
                    INSERT OR REPLACE INTO workingSetTopEntry (trackedPathId, pathId, category, groupKey, sizeBytes)
                    VALUES (?, ?, ?, ?, ?)
                    """)
                for row in rows {
                    try insert.execute(arguments: [
                        trackedPathIdString, row.pathId, group.category.rawValue, group.groupKey, row.sizeBytes
                    ])
                }
                try Self.setTopShort(false, group: group, trackedPathId: trackedPathIdString, db: db)
                return true
            }
            if didRefill { refilled += 1 }
        }
        return refilled
    }

    // MARK: - Reads

    /// A page of the files of one group, or of several owner groups merged.
    private static func fetchGroupFiles(
        trackedPathId: String,
        category: GrowthCategory,
        groupKeys: [String],
        offset: Int,
        limit: Int,
        db: Database
    ) throws -> [(pathId: Int64, path: String, sizeBytes: Int64)] {
        guard !groupKeys.isEmpty else { return [] }
        let rows: [Row]
        if groupKeys.allSatisfy(DrilldownGroupKey.isOwnerGroupKey) {
            let placeholders = Array(repeating: "?", count: groupKeys.count).joined(separator: ",")
            var arguments: StatementArguments = [trackedPathId, category.rawValue]
            arguments += StatementArguments(groupKeys)
            arguments += [limit, offset]
            rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT wse.pathId AS pathId, p.path AS path, wse.sizeBytes AS sizeBytes
                    FROM pathClassification pc
                    CROSS JOIN workingSetEntry wse ON wse.pathId = pc.pathId
                    JOIN paths p ON p.id = wse.pathId
                    WHERE wse.trackedPathId = ? AND pc.category = ?
                      AND prunr_owner_group(p.path) IN (\(placeholders))
                    ORDER BY wse.sizeBytes DESC, p.path ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: arguments
            )
        } else {
            let groupKey = groupKeys.first ?? ""
            rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT wse.pathId AS pathId, p.path AS path, wse.sizeBytes AS sizeBytes
                    FROM pathClassification pc
                    CROSS JOIN workingSetEntry wse ON wse.pathId = pc.pathId
                    JOIN paths p ON p.id = wse.pathId
                    WHERE wse.trackedPathId = ? AND pc.category = ? AND pc.subcategory = ?
                    ORDER BY wse.sizeBytes DESC, p.path ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [trackedPathId, category.rawValue, groupKey, limit, offset]
            )
        }
        return rows.map { row in
            (pathId: row["pathId"] ?? 0, path: row["path"] ?? "", sizeBytes: row["sizeBytes"] ?? 0)
        }
    }

    /// Every drilldown group of the given tracked paths, merged by group.
    func fetchDrilldownGroups(trackedPathIds: [UUID]) async throws -> DrilldownGroupsSnapshot {
        guard let dbPool else { throw DatabaseError.notInitialized }
        guard !trackedPathIds.isEmpty else { return DrilldownGroupsSnapshot(rows: [], buildingTrackedPathIds: []) }
        let ids = trackedPathIds.map(\.uuidString)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")

        return try await dbPool.read { db in
            var merged: [GroupRef: DrilldownGroupRow] = [:]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT category, groupKey, totalBytes, fileCount, topShort
                    FROM workingSetGroupTotal
                    WHERE trackedPathId IN (\(placeholders))
                    """,
                arguments: StatementArguments(ids)
            )
            for row in rows {
                guard let rawCategory: String = row["category"],
                      let category = GrowthCategory(rawValue: rawCategory) else { continue }
                let key = GroupRef(category: category, groupKey: row["groupKey"] ?? "")
                let totalBytes: Int64 = row["totalBytes"] ?? 0
                let fileCount: Int = row["fileCount"] ?? 0
                let isTopShort: Bool = row["topShort"] ?? false
                let existing = merged[key]
                merged[key] = DrilldownGroupRow(
                    category: category,
                    groupKey: key.groupKey,
                    totalBytes: (existing?.totalBytes ?? 0) + totalBytes,
                    fileCount: (existing?.fileCount ?? 0) + fileCount,
                    isTopShort: (existing?.isTopShort ?? false) || isTopShort
                )
            }

            var buildingArguments: StatementArguments = [DrilldownIndexState.building.rawValue]
            buildingArguments += StatementArguments(ids)
            let building = try String.fetchAll(
                db,
                sql: "SELECT trackedPathId FROM workingSetIndexState WHERE state = ? AND trackedPathId IN (\(placeholders))",
                arguments: buildingArguments
            )

            return DrilldownGroupsSnapshot(
                rows: merged.values.sorted {
                    $0.totalBytes == $1.totalBytes ? $0.groupKey < $1.groupKey : $0.totalBytes > $1.totalBytes
                },
                buildingTrackedPathIds: Set(building.compactMap(UUID.init(uuidString:)))
            )
        }
    }

    /// The stored top files of a category's groups (or of one group), largest
    /// first, merged across tracked paths.
    func fetchDrilldownTopFiles(
        trackedPathIds: [UUID],
        category: GrowthCategory,
        groupKey: String? = nil
    ) async throws -> [DrilldownFileEntry] {
        guard let dbPool else { throw DatabaseError.notInitialized }
        guard !trackedPathIds.isEmpty else { return [] }

        return try await dbPool.read { db in
            var files: [DrilldownFileEntry] = []
            var lowerBoundByGroup: [String: Int64] = [:]
            for trackedPathId in trackedPathIds {
                var arguments: StatementArguments = [trackedPathId.uuidString, category.rawValue]
                var groupFilter = ""
                if let groupKey {
                    groupFilter = "AND t.groupKey = ?"
                    arguments += [groupKey]
                }
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT t.groupKey AS groupKey, p.path AS path, t.sizeBytes AS sizeBytes
                        FROM workingSetTopEntry t
                        JOIN paths p ON p.id = t.pathId
                        WHERE t.trackedPathId = ? AND t.category = ? \(groupFilter)
                        """,
                    arguments: arguments
                ).map {
                    DrilldownFileEntry(groupKey: $0["groupKey"] ?? "", path: $0["path"] ?? "", sizeBytes: $0["sizeBytes"] ?? 0)
                }
                files += rows

                guard trackedPathIds.count > 1 else { continue }
                let storedByGroup = Dictionary(grouping: rows, by: \.groupKey)
                let groupFileCounts = try Row.fetchAll(
                    db,
                    sql: "SELECT groupKey, fileCount FROM workingSetGroupTotal WHERE trackedPathId = ? AND category = ?",
                    arguments: [trackedPathId.uuidString, category.rawValue]
                )
                for row in groupFileCounts {
                    let key: String = row["groupKey"] ?? ""
                    let fileCount: Int = row["fileCount"] ?? 0
                    let stored = storedByGroup[key] ?? []
                    guard stored.count < fileCount else { continue }
                    let bound = stored.map(\.sizeBytes).min() ?? Int64.max
                    lowerBoundByGroup[key] = max(lowerBoundByGroup[key] ?? Int64.min, bound)
                }
            }
            // Across tracked paths the merged rows stay a correct prefix only
            // down to the largest smallest-stored size of a path with unstored files.
            return files
                .filter { $0.sizeBytes >= (lowerBoundByGroup[$0.groupKey] ?? Int64.min) }
                .sorted(by: Self.fileRowSortsBefore)
        }
    }

    /// A page of a group's files straight from the working set, for paging
    /// past the stored top files. Several keys page through owner groups the
    /// store merged into one row.
    func fetchDrilldownFiles(
        trackedPathIds: [UUID],
        category: GrowthCategory,
        groupKeys: [String],
        offset: Int,
        limit: Int
    ) async throws -> [DrilldownFileEntry] {
        guard let dbPool else { throw DatabaseError.notInitialized }
        guard !trackedPathIds.isEmpty, limit > 0, let groupKey = groupKeys.first else { return [] }

        return try await dbPool.read { db in
            if trackedPathIds.count == 1, let trackedPathId = trackedPathIds.first {
                return try Self.fetchGroupFiles(
                    trackedPathId: trackedPathId.uuidString,
                    category: category,
                    groupKeys: groupKeys,
                    offset: offset,
                    limit: limit,
                    db: db
                ).map { DrilldownFileEntry(groupKey: groupKey, path: $0.path, sizeBytes: $0.sizeBytes) }
            }

            var files: [DrilldownFileEntry] = []
            for trackedPathId in trackedPathIds {
                files += try Self.fetchGroupFiles(
                    trackedPathId: trackedPathId.uuidString,
                    category: category,
                    groupKeys: groupKeys,
                    offset: 0,
                    limit: offset + limit,
                    db: db
                ).map { DrilldownFileEntry(groupKey: groupKey, path: $0.path, sizeBytes: $0.sizeBytes) }
            }
            return Array(files.sorted(by: Self.fileRowSortsBefore).dropFirst(offset).prefix(limit))
        }
    }

    static func fileRowSortsBefore(_ lhs: DrilldownFileEntry, _ rhs: DrilldownFileEntry) -> Bool {
        if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
        return lhs.path < rhs.path
    }

    /// The biggest direct children of a place (a unit root: the root path of a
    /// `UnitResolver` key), folders aggregated, largest first.
    func fetchPlaceContents(
        unitRoot: String,
        trackedPathIds: [UUID],
        offset: Int = 0,
        limit: Int = 50
    ) async throws -> PlaceContentsPage {
        guard let dbPool else { throw DatabaseError.notInitialized }
        guard !trackedPathIds.isEmpty, limit > 0 else { return PlaceContentsPage(children: [], hasMore: false) }
        let root = Self.normalizePath(unitRoot)
        let ids = trackedPathIds.map(\.uuidString)

        let rows: [PlaceChildRow] = try await dbPool.read { db in
            let building = try Self.buildingTrackedPathIds(ids, db: db)
            guard building.isEmpty else {
                let all = try Self.mergedPlaceChildren(root: root, trackedPathIds: ids, building: building, db: db)
                return Array(all.dropFirst(offset).prefix(limit + 1))
            }
            let sql: String
            var arguments: StatementArguments
            if ids.count == 1, let trackedPathId = ids.first {
                sql = """
                    SELECT name, isFolder, totalBytes, fileCount
                    FROM workingSetPlaceChild
                    WHERE trackedPathId = ? AND unitRoot = ?
                    ORDER BY totalBytes DESC, name
                    LIMIT ? OFFSET ?
                    """
                arguments = [trackedPathId, root]
            } else {
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                sql = """
                    SELECT name, MAX(isFolder) AS isFolder, SUM(totalBytes) AS totalBytes, SUM(fileCount) AS fileCount
                    FROM workingSetPlaceChild
                    WHERE trackedPathId IN (\(placeholders)) AND unitRoot = ?
                    GROUP BY name
                    ORDER BY totalBytes DESC, name
                    LIMIT ? OFFSET ?
                    """
                arguments = StatementArguments(ids)
                arguments += [root]
            }
            arguments += [limit + 1, offset]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { PlaceChildRow($0) }
        }

        let rootName = (root as NSString).lastPathComponent
        let children = rows.prefix(limit).map { row in
            PlaceChild(
                name: row.name.isEmpty ? rootName : row.name,
                path: row.name.isEmpty ? root : (root == "/" ? "/" + row.name : root + "/" + row.name),
                isFolder: row.isFolder,
                totalBytes: row.totalBytes,
                fileCount: row.fileCount
            )
        }
        return PlaceContentsPage(children: Array(children), hasMore: rows.count > limit)
    }

    private struct PlaceChildRow: Sendable {
        var name: String
        var isFolder: Bool
        var totalBytes: Int64
        var fileCount: Int

        init(name: String, isFolder: Bool, totalBytes: Int64, fileCount: Int) {
            self.name = name
            self.isFolder = isFolder
            self.totalBytes = totalBytes
            self.fileCount = fileCount
        }

        init(_ row: Row) {
            self.init(
                name: row["name"] ?? "",
                isFolder: row["isFolder"] ?? false,
                totalBytes: row["totalBytes"] ?? 0,
                fileCount: row["fileCount"] ?? 0
            )
        }
    }

    private static func buildingTrackedPathIds(_ ids: [String], db: Database) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var arguments: StatementArguments = [DrilldownIndexState.building.rawValue]
        arguments += StatementArguments(ids)
        return Set(try String.fetchAll(
            db,
            sql: "SELECT trackedPathId FROM workingSetIndexState WHERE state = ? AND trackedPathId IN (\(placeholders))",
            arguments: arguments
        ))
    }

    private static func mergedPlaceChildren(
        root: String,
        trackedPathIds: [String],
        building: Set<String>,
        db: Database
    ) throws -> [PlaceChildRow] {
        var merged: [String: PlaceChildRow] = [:]
        func add(_ row: PlaceChildRow) {
            let key = row.name.lowercased()
            if var existing = merged[key] {
                existing.isFolder = existing.isFolder || row.isFolder
                existing.totalBytes += row.totalBytes
                existing.fileCount += row.fileCount
                merged[key] = existing
            } else {
                merged[key] = row
            }
        }
        for trackedPathId in trackedPathIds {
            if building.contains(trackedPathId) {
                for (child, totals) in try placeChildrenFromWorkingSet(root: root, trackedPathId: trackedPathId, db: db) {
                    add(PlaceChildRow(name: child.name, isFolder: child.isFolder, totalBytes: totals.totalBytes, fileCount: totals.fileCount))
                }
            } else {
                try Row.fetchAll(
                    db,
                    sql: "SELECT name, isFolder, totalBytes, fileCount FROM workingSetPlaceChild WHERE trackedPathId = ? AND unitRoot = ?",
                    arguments: [trackedPathId, root]
                ).forEach { add(PlaceChildRow($0)) }
            }
        }
        return merged.values.sorted {
            if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
            return $0.name.caseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func placeChildrenFromWorkingSet(
        root: String,
        trackedPathId: String,
        db: Database
    ) throws -> [PlaceChildKey: DrilldownIndexBuilder.Totals] {
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT p.path AS path, wse.sizeBytes AS sizeBytes
                FROM paths p
                CROSS JOIN workingSetEntry wse ON wse.trackedPathId = ? AND wse.pathId = p.id
                WHERE p.path >= ? AND p.path < ?
                """,
            arguments: [trackedPathId, root, pathPrefixUpperBound(root)]
        )
        var children: [PlaceChildKey: DrilldownIndexBuilder.Totals] = [:]
        while let row = try cursor.next() {
            let path: String = row["path"] ?? ""
            guard let child = PlaceChildKey(path: path, unitKey: UnitResolver.resolve(path: path)),
                  child.unitRoot.caseInsensitiveCompare(root) == .orderedSame else { continue }
            children[PlaceChildKey(unitRoot: root, name: child.name, isFolder: child.isFolder), default: .init()]
                .add(row["sizeBytes"] ?? 0)
        }
        return children
    }

    func fetchDrilldownCategoryFromWorkingSet(
        trackedPathIds: [UUID],
        category: GrowthCategory
    ) async throws -> DrilldownCategoryContents {
        guard let dbPool else { throw DatabaseError.notInitialized }
        guard !trackedPathIds.isEmpty else { return DrilldownCategoryContents(rows: [], files: []) }

        return try await dbPool.read { db in
            var groups: [String: DrilldownIndexBuilder.GroupAccumulator] = [:]
            for trackedPathId in trackedPathIds {
                let cursor = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT wse.pathId AS pathId, p.path AS path, wse.sizeBytes AS sizeBytes, pc.subcategory AS subcategory
                        FROM pathClassification pc
                        CROSS JOIN workingSetEntry wse ON wse.pathId = pc.pathId
                        JOIN paths p ON p.id = wse.pathId
                        WHERE wse.trackedPathId = ? AND pc.category = ?
                        """,
                    arguments: [trackedPathId.uuidString, category.rawValue]
                )
                while let row = try cursor.next() {
                    let path: String = row["path"] ?? ""
                    let rawSubcategory: String = row["subcategory"] ?? ""
                    let groupKey = DrilldownGroupKey.make(
                        category: category,
                        subcategory: GrowthSubcategory(rawValue: rawSubcategory),
                        path: path
                    )
                    DrilldownIndexBuilder.accumulate(
                        path: path,
                        pathId: row["pathId"],
                        sizeBytes: row["sizeBytes"] ?? 0,
                        into: &groups[groupKey, default: .init()]
                    )
                }
            }
            return DrilldownCategoryContents(
                rows: groups.map { groupKey, group in
                    DrilldownGroupRow(
                        category: category,
                        groupKey: groupKey,
                        totalBytes: group.totalBytes,
                        fileCount: group.fileCount,
                        isTopShort: false
                    )
                },
                files: groups.flatMap { groupKey, group in
                    DrilldownIndexBuilder.ranked(group.candidates).map {
                        DrilldownFileEntry(groupKey: groupKey, path: $0.path, sizeBytes: $0.sizeBytes)
                    }
                }.sorted(by: Self.fileRowSortsBefore)
            )
        }
    }

    // MARK: - Verification

    /// Recomputes the index of a tracked path from the working set and returns
    /// every difference (empty when the index is exact). Top files are checked
    /// against the prefix invariant, not a specific tie order.
    func verifyDrilldownIndex(trackedPathId: UUID) async throws -> [String] {
        guard let dbPool else { throw DatabaseError.notInitialized }
        let id = trackedPathId.uuidString

        return try await dbPool.read { db in
            var problems: [String] = []
            let expected = try Self.drilldownIndexBuilder(fromWorkingSetOf: id, db: db)

            var storedGroups: [DrilldownIndexBuilder.GroupID: (totalBytes: Int64, fileCount: Int, topShort: Bool)] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT category, groupKey, totalBytes, fileCount, topShort FROM workingSetGroupTotal WHERE trackedPathId = ?",
                arguments: [id]
            ) {
                let rawCategory: String = row["category"] ?? ""
                guard let category = GrowthCategory(rawValue: rawCategory) else {
                    problems.append("group with unknown category \(rawCategory)")
                    continue
                }
                let totalBytes: Int64 = row["totalBytes"] ?? 0
                let fileCount: Int = row["fileCount"] ?? 0
                let topShort: Bool = row["topShort"] ?? false
                storedGroups[.init(category: category, groupKey: row["groupKey"] ?? "")] = (totalBytes, fileCount, topShort)
            }

            for (groupId, group) in expected.groups {
                guard let stored = storedGroups.removeValue(forKey: groupId) else {
                    problems.append("missing group \(groupId.category.rawValue)/\(groupId.groupKey)")
                    continue
                }
                if stored.totalBytes != group.totalBytes || stored.fileCount != group.fileCount {
                    problems.append(
                        "group \(groupId.category.rawValue)/\(groupId.groupKey): stored \(stored.totalBytes)/\(stored.fileCount) expected \(group.totalBytes)/\(group.fileCount)"
                    )
                }

                let top = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT t.pathId AS pathId, t.sizeBytes AS sizeBytes, wse.sizeBytes AS liveSize
                        FROM workingSetTopEntry t
                        LEFT JOIN workingSetEntry wse ON wse.trackedPathId = t.trackedPathId AND wse.pathId = t.pathId
                        WHERE t.trackedPathId = ? AND t.category = ? AND t.groupKey = ?
                        """,
                    arguments: [id, groupId.category.rawValue, groupId.groupKey]
                )
                let topIds = Set(top.compactMap { $0["pathId"] as Int64? })
                if top.contains(where: { ($0["liveSize"] as Int64?) != ($0["sizeBytes"] as Int64?) }) {
                    problems.append("group \(groupId.category.rawValue)/\(groupId.groupKey): top size differs from working set")
                }
                if top.count > DrilldownIndexBuilder.topLimit {
                    problems.append("group \(groupId.category.rawValue)/\(groupId.groupKey): \(top.count) top rows")
                }
                let expectedTop = expected.topFiles(of: groupId)
                let expectedIds = Set(expectedTop.compactMap(\.pathId))
                let allMembersKnown = expectedTop.count == group.fileCount
                if allMembersKnown, !topIds.isSubset(of: expectedIds) {
                    problems.append("group \(groupId.category.rawValue)/\(groupId.groupKey): top row outside the group")
                }
                let minStored = top.compactMap { $0["sizeBytes"] as Int64? }.min()
                if let minStored {
                    for file in expectedTop where file.sizeBytes > minStored {
                        if let pathId = file.pathId, !topIds.contains(pathId) {
                            problems.append("group \(groupId.category.rawValue)/\(groupId.groupKey): \(file.path) missing from top prefix")
                        }
                    }
                }
                let shouldBeShort = top.count < min(DrilldownIndexBuilder.topLimit, group.fileCount)
                if stored.topShort != shouldBeShort {
                    problems.append("group \(groupId.category.rawValue)/\(groupId.groupKey): topShort \(stored.topShort) with \(top.count) rows")
                }
            }
            for groupId in storedGroups.keys {
                problems.append("extra group \(groupId.category.rawValue)/\(groupId.groupKey)")
            }

            let orphanTop = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM workingSetTopEntry t
                    LEFT JOIN workingSetGroupTotal g
                      ON g.trackedPathId = t.trackedPathId AND g.category = t.category AND g.groupKey = t.groupKey
                    WHERE t.trackedPathId = ? AND g.trackedPathId IS NULL
                    """,
                arguments: [id]
            ) ?? 0
            if orphanTop > 0 {
                problems.append("\(orphanTop) top rows without a group")
            }

            var expectedPlaces: [String: DrilldownIndexBuilder.Totals] = [:]
            for (child, totals) in expected.placeChildren {
                let key = "\(child.unitRoot.lowercased())|\(child.name.lowercased())"
                expectedPlaces[key, default: .init()].totalBytes += totals.totalBytes
                expectedPlaces[key, default: .init()].fileCount += totals.fileCount
            }
            for row in try Row.fetchAll(
                db,
                sql: "SELECT unitRoot, name, totalBytes, fileCount FROM workingSetPlaceChild WHERE trackedPathId = ?",
                arguments: [id]
            ) {
                let unitRoot: String = row["unitRoot"] ?? ""
                let name: String = row["name"] ?? ""
                let key = "\(unitRoot.lowercased())|\(name.lowercased())"
                let totalBytes: Int64 = row["totalBytes"] ?? 0
                let fileCount: Int = row["fileCount"] ?? 0
                let totals = DrilldownIndexBuilder.Totals(totalBytes: totalBytes, fileCount: fileCount)
                guard let expectedTotals = expectedPlaces.removeValue(forKey: key) else {
                    problems.append("extra place child \(key)")
                    continue
                }
                if expectedTotals != totals {
                    problems.append("place child \(key): stored \(totals.totalBytes)/\(totals.fileCount) expected \(expectedTotals.totalBytes)/\(expectedTotals.fileCount)")
                }
            }
            for key in expectedPlaces.keys {
                problems.append("missing place child \(key)")
            }

            var storedCategories: [String: Int64] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT category, totalBytes FROM workingSetCategoryTotal WHERE trackedPathId = ?",
                arguments: [id]
            ) {
                storedCategories[row["category"] ?? ""] = row["totalBytes"] ?? 0
            }
            for (category, total) in expected.categoryTotals where total > 0 {
                if storedCategories.removeValue(forKey: category.rawValue) != total {
                    problems.append("category \(category.rawValue) total differs")
                }
            }
            for category in storedCategories.keys {
                problems.append("extra category total \(category)")
            }

            return problems
        }
    }
}
