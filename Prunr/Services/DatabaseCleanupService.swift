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

    // MARK: - Properties

    static let shared = DatabaseCleanupService()

    private let db = DatabaseManager.shared

    private init() {}

    // MARK: - Public API

    /// Performs automatic cleanup after a scan completes
    /// Keeps only the most recent 2 snapshots per tracked path
    func performAutoCleanup() async {
        do {
            let deleted = try await cleanupOldSnapshots()
            if deleted > 0 {
                print("[DatabaseCleanupService] Auto-cleanup: deleted \(deleted) old snapshots")
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

    /// Deletes old snapshots, keeping only the most recent N per tracked path
    /// - Returns: Number of snapshots deleted
    private func cleanupOldSnapshots() async throws -> Int {
        guard let dbPool = db.dbPool else { return 0 }

        return try await dbPool.write { db in
            var totalDeleted = 0

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

                // Delete snapshots beyond the retention limit
                let toDelete = snapshots.dropFirst(Self.maxSnapshotsPerPath)
                for snapshot in toDelete {
                    if let snapshotId = snapshot.id {
                        let deleted = try Snapshot.filter(id: snapshotId).deleteAll(db)
                        totalDeleted += deleted
                    }
                }
            }

            // Also clean up orphaned snapshots (empty trackedPathId from old migrations)
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
                    let deleted = try Snapshot.filter(id: snapshotId).deleteAll(db)
                    totalDeleted += deleted
                }
            }

            return totalDeleted
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
