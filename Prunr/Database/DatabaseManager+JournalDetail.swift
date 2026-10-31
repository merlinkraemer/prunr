import Foundation
import GRDB

extension DatabaseManager {
    static let journalDetailMigrationIdentifier = "v26_journal_detail"

    static func registerJournalDetailMigration(in migrator: inout DatabaseMigrator) {
        // Migration v26: per-child detail of the growth journal (PRD L1). No
        // back-fill: per-file history before this is gone, so older rows keep
        // the sizes-now page.
        migrator.registerMigration(journalDetailMigrationIdentifier) { db in
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
