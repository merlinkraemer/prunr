import Foundation
import GRDB

/// Service for automatic database cleanup and maintenance
/// Runs automatically after scans with sensible defaults
actor DatabaseCleanupService {

    // MARK: - Constants

    /// Maximum snapshots to keep per tracked path (rolling comparison needs 2)
    private static let maxSnapshotsPerPath = 2
    private static let vacuumInterval: TimeInterval = 12 * 60 * 60
    private static let vacuumTimestampKey = "databaseLastVacuumAt"
    private static let checkpointInterval: TimeInterval = 60
    private static let checkpointTimestampKey = "databaseLastCheckpointAt"

    /// Default retention period for category history (30 days)
    private static let defaultCategoryHistoryRetentionDays = 30

    // MARK: - Properties

    static let shared = DatabaseCleanupService()

    private let db = DatabaseManager.shared

    private init() {}

    // MARK: - Public API

    /// Performs automatic cleanup after a scan completes
    /// Keeps only the most recent 2 snapshots per tracked path
    func performAutoCleanup() async {
        do {
            // First pass: aggregate category totals for snapshots about to lose their entries
            try await aggregateCategoryTotalsForOldSnapshots()

            // Second pass: delete snapshotEntry rows for old snapshots (keep snapshot metadata)
            let entriesDeleted = try await cleanupOldSnapshotEntries()
            if entriesDeleted > 0 {
                print("[DatabaseCleanupService] Auto-cleanup: deleted \(entriesDeleted) old snapshot entries")
            }

            // Third pass: delete old snapshot rows entirely (and cascading categorySnapshot rows)
            let snapshotsDeleted = try await cleanupOldCategoryHistory()
            if snapshotsDeleted > 0 {
                print("[DatabaseCleanupService] Auto-cleanup: deleted \(snapshotsDeleted) old snapshots")
                if shouldVacuumNow() {
                    try await vacuumDatabase()
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.vacuumTimestampKey)
                }
            }

            if shouldCheckpointNow() {
                try await db.checkpointWalTruncate()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkpointTimestampKey)
            }
        } catch {
            print("[DatabaseCleanupService] Auto-cleanup failed: \(error.localizedDescription)")
        }
    }

    private func shouldVacuumNow() -> Bool {
        let last = UserDefaults.standard.double(forKey: Self.vacuumTimestampKey)
        guard last > 0 else { return true }
        return Date().timeIntervalSince1970 - last >= Self.vacuumInterval
    }

    private func shouldCheckpointNow() -> Bool {
        let last = UserDefaults.standard.double(forKey: Self.checkpointTimestampKey)
        guard last > 0 else { return true }
        return Date().timeIntervalSince1970 - last >= Self.checkpointInterval
    }

    /// Aggregates category totals for snapshots that are about to lose their entry data
    /// This runs before cleanupOldSnapshotEntries to ensure we have category history
    private func aggregateCategoryTotalsForOldSnapshots() async throws {
        guard let dbPool = db.dbPool else { return }

        try await dbPool.write { db in
            // Get all tracked path IDs that have snapshots
            let pathIds = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT trackedPathId FROM snapshot WHERE trackedPathId != '' ORDER BY trackedPathId"
            )

            for pathId in pathIds {
                // Get snapshots for this path, ordered by newest first
                let snapshots = try Snapshot.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM snapshot
                    WHERE trackedPathId = ?
                    ORDER BY createdAt DESC
                    """,
                    arguments: [pathId]
                )

                // Find snapshots beyond the retention limit that still have entries
                let toAggregate = snapshots.dropFirst(Self.maxSnapshotsPerPath)
                var snapshotIdsToAggregate: [Int64] = []
                for snapshot in toAggregate {
                    if let snapshotId = snapshot.id {
                        snapshotIdsToAggregate.append(snapshotId)
                    }
                }

                // Also handle orphaned snapshots
                let orphanedSnapshots = try Snapshot.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM snapshot
                    WHERE trackedPathId = '' OR trackedPathId IS NULL
                    ORDER BY createdAt DESC
                    """
                )
                let orphanedToAggregate = orphanedSnapshots.dropFirst(Self.maxSnapshotsPerPath)
                for snapshot in orphanedToAggregate {
                    if let snapshotId = snapshot.id {
                        snapshotIdsToAggregate.append(snapshotId)
                    }
                }

                // Aggregate category totals for all identified snapshots
                for snapshotId in snapshotIdsToAggregate {
                    try aggregateCategoryTotals(for: snapshotId, db: db)
                }
            }
        }
    }

    /// Aggregates category totals for a specific snapshot and writes to categorySnapshot table
    /// - Parameters:
    ///   - snapshotId: The snapshot ID to aggregate
    ///   - db: The database connection
    private nonisolated func aggregateCategoryTotals(for snapshotId: Int64, db: Database) throws {
        // Check if categorySnapshot rows already exist for this snapshot (idempotency guard)
        let existingCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM categorySnapshot WHERE snapshotId = ?",
            arguments: [snapshotId]
        ) ?? 0

        guard existingCount == 0 else {
            // Already aggregated, skip
            return
        }

        // Get all entries for this snapshot with their path strings
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT se.sizeBytes, p.path
                FROM snapshotEntry se
                JOIN paths p ON p.id = se.pathId
                WHERE se.snapshotId = ?
                """,
            arguments: [snapshotId]
        )

        // Build pathId -> pathString dictionary (we already have it from the query)
        // Aggregate totals by category in memory
        var categoryTotals: [String: Int64] = [:]

        for row in rows {
            if let path: String = row["path"],
               let sizeBytes: Int64 = row["sizeBytes"] {
                let category = GrowthCategory.categorize(path: path)
                let categoryKey = category.rawValue
                categoryTotals[categoryKey, default: 0] += sizeBytes
            }
        }

        // Write each category total to categorySnapshot
        for (categoryKey, totalBytes) in categoryTotals {
            try db.execute(
                sql: "INSERT INTO categorySnapshot (snapshotId, category, totalBytes) VALUES (?, ?, ?)",
                arguments: [snapshotId, categoryKey, totalBytes]
            )
        }

        if !categoryTotals.isEmpty {
            print("[DatabaseCleanupService] Aggregated \(categoryTotals.count) categories for snapshot \(snapshotId)")
        }
    }

    /// Deletes snapshotEntry rows for old snapshots, keeping only the most recent N per tracked path
    /// Snapshot metadata (and categorySnapshot rows) are preserved for historical trend analysis
    /// - Returns: Number of snapshots that had their entries deleted
    private func cleanupOldSnapshotEntries() async throws -> Int {
        guard let dbPool = db.dbPool else { return 0 }

        return try await dbPool.write { db in
            var totalProcessed = 0

            // Get all tracked path IDs that have snapshots
            let pathIds = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT trackedPathId FROM snapshot WHERE trackedPathId != '' ORDER BY trackedPathId"
            )

            for pathId in pathIds {
                // Get snapshots for this path, ordered by newest first
                let snapshots = try Snapshot.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM snapshot
                    WHERE trackedPathId = ?
                    ORDER BY createdAt DESC
                    """,
                    arguments: [pathId]
                )

                // Delete entries for snapshots beyond the retention limit
                let toDelete = snapshots.dropFirst(Self.maxSnapshotsPerPath)
                for snapshot in toDelete {
                    if let snapshotId = snapshot.id {
                        // Check if entries still exist before deleting
                        let entryCount = try Int.fetchOne(
                            db,
                            sql: "SELECT COUNT(*) FROM snapshotEntry WHERE snapshotId = ?",
                            arguments: [snapshotId]
                        ) ?? 0

                        if entryCount > 0 {
                            // Delete entries only (keep snapshot row and categorySnapshot)
                            try db.execute(sql: "DELETE FROM snapshotEntry WHERE snapshotId = ?", arguments: [snapshotId])
                            totalProcessed += 1
                            print("[DatabaseCleanupService] Deleted entries for snapshot \(snapshotId) (had \(entryCount) entries)")
                        }
                    }
                }
            }

            // Also clean up orphaned snapshots
            let orphanedSnapshots = try Snapshot.fetchAll(
                db,
                sql: """
                SELECT * FROM snapshot
                WHERE trackedPathId = '' OR trackedPathId IS NULL
                ORDER BY createdAt DESC
                """
            )
            let orphanedToDelete = orphanedSnapshots.dropFirst(Self.maxSnapshotsPerPath)
            for snapshot in orphanedToDelete {
                if let snapshotId = snapshot.id {
                    let entryCount = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM snapshotEntry WHERE snapshotId = ?",
                        arguments: [snapshotId]
                    ) ?? 0

                    if entryCount > 0 {
                        try db.execute(sql: "DELETE FROM snapshotEntry WHERE snapshotId = ?", arguments: [snapshotId])
                        totalProcessed += 1
                    }
                }
            }

            return totalProcessed
        }
    }

    /// Deletes snapshot rows (and cascading categorySnapshot rows) older than the retention period
    /// - Returns: Number of snapshots deleted
    func cleanupOldCategoryHistory() async throws -> Int {
        guard let dbPool = db.dbPool else { return 0 }

        // Get retention period from SettingsStore (default 30 days)
        let retentionDays = await SettingsStore.shared.categoryHistoryRetentionDays
        let effectiveRetentionDays = retentionDays > 0 ? retentionDays : Self.defaultCategoryHistoryRetentionDays
        let cutoffDate = Date().addingTimeInterval(TimeInterval(-effectiveRetentionDays * 24 * 60 * 60))

        return try await dbPool.write { db in
            // Delete snapshots older than retention period
            // This cascades to categorySnapshot rows due to foreign key constraint
            let deleted = try Snapshot
                .filter(sql: "createdAt < ?", arguments: [cutoffDate])
                .deleteAll(db)

            if deleted > 0 {
                print("[DatabaseCleanupService] Deleted \(deleted) snapshots older than \(effectiveRetentionDays) days")
            }

            return deleted
        }
    }

    /// Vacuums the database to reclaim space
    private func vacuumDatabase() async throws {
        guard let dbPool = db.dbPool else { return }

        print("[DatabaseCleanupService] Running VACUUM...")
        try await dbPool.write { db in
            try db.execute(sql: "VACUUM")
        }
        print("[DatabaseCleanupService] VACUUM complete")
    }
}
