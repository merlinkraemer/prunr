import Foundation
import GRDB

/// Service for automatic database cleanup and maintenance
/// Runs automatically after scans with sensible defaults
actor DatabaseCleanupService {

    struct MaintenanceReport: Sendable {
        let dbBytesBefore: Int64
        let dbBytesAfter: Int64
        let walBytesBefore: Int64
        let walBytesAfter: Int64
        let snapshotsDeleted: Int
        let snapshotEntrySnapshotsTrimmed: Int
        let orphanedPathsDeleted: Int
        let backfilledSnapshots: Int
        let backfilledSubcategorySnapshots: Int
    }

    // MARK: - Constants

    /// Keep the latest two full snapshot payloads for each path so that historical
    /// comparison in the main window can still compute deltas after auto-cleanup.
    private static let maxSnapshotEntryPayloadsPerPath = 2
    /// Keep the latest two snapshots available for history/reconciliation lookups.
    private static let recentHistorySnapshotsPerPath = 2
    /// Bound retained summary snapshots so scan-heavy same-day sessions don't grow history indefinitely.
    private static let maxCategoryHistorySnapshotsPerPath = 500
    private static let vacuumInterval: TimeInterval = 12 * 60 * 60
    private static let vacuumTimestampKey = "databaseLastVacuumAt"
    private static let checkpointInterval: TimeInterval = 60
    private static let checkpointTimestampKey = "databaseLastCheckpointAt"
    private static let appVersionKey = "appLastLaunchedVersion"
    private static let startupCleanupTimestampKey = "databaseLastStartupCleanupAt"
    private static let startupCleanupInterval: TimeInterval = 12 * 60 * 60
    private static let startupAggressiveDbSizeBytes: Int64 = 400 * 1024 * 1024
    private static let startupAggressiveWalSizeBytes: Int64 = 32 * 1024 * 1024
    private static let startupInitialDelay: TimeInterval = 2 * 60
    private static let startupIdlePollInterval: TimeInterval = 5
    private static let startupIdleMaxWait: TimeInterval = 5 * 60
    private static let minimumVacuumReclaimBytes: Int64 = 96 * 1024 * 1024
    private static let minimumVacuumReclaimRatio = 0.18

    /// Default retention period for category history (30 days)
    private static let defaultCategoryHistoryRetentionDays = 30

    // MARK: - Properties

    static let shared = DatabaseCleanupService()

    private let db = DatabaseManager.shared
    private var isStartupMaintenanceRunning = false

    private init() {}

    private struct StorageStats {
        let dbBytes: Int64
        let walBytes: Int64
        let shmBytes: Int64
        let pageCount: Int64
        let pageSize: Int64
        let freelistCount: Int64

        var freelistBytes: Int64 {
            freelistCount * pageSize
        }

        var freelistRatio: Double {
            guard pageCount > 0 else { return 0 }
            return Double(freelistCount) / Double(pageCount)
        }
    }

    // MARK: - Public API

    /// Performs automatic cleanup after a scan completes.
    /// Keeps only the latest full raw snapshot payload per tracked path.
    func performAutoCleanup() async {
        do {
            let storageBefore = await databaseStorageStats()

            // First pass: aggregate category totals for snapshots about to lose their entries
            try await aggregateCategoryTotalsForOldSnapshots()

            // Second pass: delete snapshotEntry rows for old snapshots (keep snapshot metadata)
            let entriesDeleted = try await cleanupOldSnapshotEntries()

            // Remove paths that are no longer referenced by snapshotEntry rows
            let pathsDeleted = try await cleanupOrphanedPaths()

            // Third pass: delete old snapshot rows entirely (and cascading categorySnapshot rows)
            let snapshotsDeleted = try await cleanupOldCategoryHistory()

            let reclaimedRows = entriesDeleted > 0 || pathsDeleted > 0 || snapshotsDeleted > 0
            let storageAfterCleanup = await databaseStorageStats()
            if reclaimedRows && shouldVacuumNow(before: storageBefore, after: storageAfterCleanup) {
                try await db.checkpointWalTruncate()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkpointTimestampKey)
                try await vacuumDatabase()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.vacuumTimestampKey)
            } else if shouldCheckpointNow() {
                try await db.checkpointWalTruncate()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkpointTimestampKey)
            }
        } catch {
            print("[DatabaseCleanupService] Auto-cleanup failed: \(error.localizedDescription)")
        }
    }

    /// Performs startup maintenance to keep app data lean between app versions.
    /// Runs a standard cleanup pass and optionally forces WAL checkpoint/vacuum
    /// when version changes or database size grows beyond thresholds.
    func performStartupMaintenance() async {
        guard !isStartupMaintenanceRunning else { return }
        isStartupMaintenanceRunning = true
        defer { isStartupMaintenanceRunning = false }

        // Give initial autoscan/watcher setup time to settle before maintenance can claim the writer.
        try? await Task.sleep(for: .milliseconds(Int(Self.startupInitialDelay * 1000)))

        let appVersion = currentAppVersion()
        let lastVersion = UserDefaults.standard.string(forKey: Self.appVersionKey)
        let versionChanged = lastVersion != appVersion

        let now = Date().timeIntervalSince1970
        let lastCleanup = UserDefaults.standard.double(forKey: Self.startupCleanupTimestampKey)
        let shouldRun = lastCleanup == 0 || now - lastCleanup >= Self.startupCleanupInterval

        let sizes = databaseFileSizes()
        let shouldAggressiveCleanup = versionChanged
            || sizes.dbBytes >= Self.startupAggressiveDbSizeBytes
            || sizes.walBytes >= Self.startupAggressiveWalSizeBytes

        guard shouldRun || shouldAggressiveCleanup else { return }

        let becameIdle = await waitForAppToBeIdle(
            maxWait: Self.startupIdleMaxWait,
            pollInterval: Self.startupIdlePollInterval
        )
        guard becameIdle else {
            return
        }

        _ = try? await backfillRecentCategorySnapshots()
        _ = try? await backfillRecentSubcategorySnapshots()
        await performAutoCleanup()

        do {
            if shouldAggressiveCleanup {
                try await db.checkpointWalTruncate()
                try await vacuumDatabase()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.vacuumTimestampKey)
            } else if shouldCheckpointNow() {
                try await db.checkpointWalTruncate()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkpointTimestampKey)
            }
        } catch {
            print("[DatabaseCleanupService] Startup maintenance failed: \(error.localizedDescription)")
        }

        UserDefaults.standard.set(appVersion, forKey: Self.appVersionKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.startupCleanupTimestampKey)
    }

    /// Performs an explicit one-shot maintenance pass and forces WAL checkpoint + VACUUM.
    func compactDatabaseNow() async throws -> MaintenanceReport {
        let before = databaseFileSizes()
        let backfilled = try await backfillRecentCategorySnapshots()
        let backfilledSubcategories = try await backfillRecentSubcategorySnapshots()
        try await aggregateCategoryTotalsForOldSnapshots()
        let entriesDeleted = try await cleanupOldSnapshotEntries()
        let pathsDeleted = try await cleanupOrphanedPaths()
        let snapshotsDeleted = try await cleanupOldCategoryHistory()

        try await db.checkpointWalTruncate()
        try await vacuumDatabase()
        let after = databaseFileSizes()

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.vacuumTimestampKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkpointTimestampKey)

        return MaintenanceReport(
            dbBytesBefore: before.dbBytes,
            dbBytesAfter: after.dbBytes,
            walBytesBefore: before.walBytes,
            walBytesAfter: after.walBytes,
            snapshotsDeleted: snapshotsDeleted,
            snapshotEntrySnapshotsTrimmed: entriesDeleted,
            orphanedPathsDeleted: pathsDeleted,
            backfilledSnapshots: backfilled,
            backfilledSubcategorySnapshots: backfilledSubcategories
        )
    }

    private func shouldVacuumNow() -> Bool {
        let last = UserDefaults.standard.double(forKey: Self.vacuumTimestampKey)
        guard last > 0 else { return true }
        return Date().timeIntervalSince1970 - last >= Self.vacuumInterval
    }

    private func shouldVacuumNow(before: StorageStats, after: StorageStats) -> Bool {
        guard shouldVacuumNow() else { return false }

        let reclaimedBytes = max(0, before.dbBytes - after.dbBytes) + after.freelistBytes
        if reclaimedBytes >= Self.minimumVacuumReclaimBytes {
            return true
        }

        return after.freelistRatio >= Self.minimumVacuumReclaimRatio
            && after.dbBytes >= Self.startupAggressiveDbSizeBytes
    }

    private func currentAppVersion() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    private func databaseFileSizes() -> (dbBytes: Int64, walBytes: Int64, shmBytes: Int64) {
        guard let dbPath = db.databasePath else { return (0, 0, 0) }
        let walPath = dbPath + "-wal"
        let shmPath = dbPath + "-shm"

        let dbBytes = fileSizeBytes(atPath: dbPath)
        let walBytes = fileSizeBytes(atPath: walPath)
        let shmBytes = fileSizeBytes(atPath: shmPath)

        return (dbBytes, walBytes, shmBytes)
    }

    private func databaseStorageStats() async -> StorageStats {
        let sizes = databaseFileSizes()

        guard let dbPool = db.dbPool else {
            return StorageStats(
                dbBytes: sizes.dbBytes,
                walBytes: sizes.walBytes,
                shmBytes: sizes.shmBytes,
                pageCount: 0,
                pageSize: 0,
                freelistCount: 0
            )
        }

        do {
            return try await dbPool.read { db in
                let pageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
                let freelistCount = try Int64.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0

                return StorageStats(
                    dbBytes: sizes.dbBytes,
                    walBytes: sizes.walBytes,
                    shmBytes: sizes.shmBytes,
                    pageCount: pageCount,
                    pageSize: pageSize,
                    freelistCount: freelistCount
                )
            }
        } catch {
            return StorageStats(
                dbBytes: sizes.dbBytes,
                walBytes: sizes.walBytes,
                shmBytes: sizes.shmBytes,
                pageCount: 0,
                pageSize: 0,
                freelistCount: 0
            )
        }
    }

    private func fileSizeBytes(atPath path: String) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let size = attributes[.size] as? NSNumber {
                return size.int64Value
            }
        } catch {
            return 0
        }
        return 0
    }

    private func shouldCheckpointNow() -> Bool {
        let last = UserDefaults.standard.double(forKey: Self.checkpointTimestampKey)
        guard last > 0 else { return true }
        return Date().timeIntervalSince1970 - last >= Self.checkpointInterval
    }

    private func waitForAppToBeIdle(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(maxWait)

        while Date() < deadline {
            if await !isAppBusy() {
                return true
            }

            try? await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
        }

        return await !isAppBusy()
    }

    private func isAppBusy() async -> Bool {
        await MainActor.run {
            if ScanService.shared.isScanning {
                return true
            }

            guard let manager = MenuBarManager.shared else {
                return false
            }

            return manager.isLoading
                || manager.isAutoScanning
                || manager.isAnalyzingChanges
                || manager.isCleaningUp
        }
    }

    /// Ensures the latest retained snapshots already have aggregated category totals.
    /// This keeps current inventory and trend calculations fast without re-reading huge snapshots.
    private func backfillRecentCategorySnapshots() async throws -> Int {
        let snapshotIds = try await recentSnapshotIDs()

        var backfilled = 0
        for snapshotId in snapshotIds {
            let result = try await aggregateSnapshotSummariesIfMissing(for: snapshotId)
            if result.categoryWritten {
                backfilled += 1
            }
        }

        return backfilled
    }

    private func backfillRecentSubcategorySnapshots() async throws -> Int {
        let snapshotIds = try await recentSnapshotIDs()

        var backfilled = 0
        for snapshotId in snapshotIds {
            let result = try await aggregateSnapshotSummariesIfMissing(for: snapshotId)
            if result.subcategoryWritten {
                backfilled += 1
            }
        }

        return backfilled
    }

    private func recentSnapshotIDs() async throws -> [Int64] {
        guard let dbPool = db.dbPool else { return [] }

        return try await dbPool.read { db -> [Int64] in
            let trackedPathIds = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT trackedPathId FROM snapshot WHERE trackedPathId != '' ORDER BY trackedPathId"
            )

            var ids: [Int64] = []

            for trackedPathId in trackedPathIds {
                let recent = try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT id
                        FROM snapshot
                        WHERE trackedPathId = ?
                        ORDER BY createdAt DESC
                        LIMIT ?
                        """,
                    arguments: [trackedPathId, Self.recentHistorySnapshotsPerPath]
                )
                ids.append(contentsOf: recent)
            }

            let orphaned = try Int64.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM snapshot
                    WHERE trackedPathId = '' OR trackedPathId IS NULL
                    ORDER BY createdAt DESC
                    LIMIT ?
                    """,
                arguments: [Self.recentHistorySnapshotsPerPath]
            )
            ids.append(contentsOf: orphaned)

            return ids
        }
    }

    /// Aggregates category totals for snapshots that are about to lose their entry data
    /// This runs before cleanupOldSnapshotEntries to ensure we have category history
    private func aggregateCategoryTotalsForOldSnapshots() async throws {
        guard let dbPool = db.dbPool else { return }

        let snapshotIdsToAggregate = try await dbPool.read { db -> [Int64] in
            // Get all tracked path IDs that have snapshots
            let pathIds = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT trackedPathId FROM snapshot WHERE trackedPathId != '' ORDER BY trackedPathId"
            )

            var snapshotIdsToAggregate: [Int64] = []

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
                let toAggregate = snapshots.dropFirst(Self.maxSnapshotEntryPayloadsPerPath)
                for snapshot in toAggregate {
                    if let snapshotId = snapshot.id {
                        snapshotIdsToAggregate.append(snapshotId)
                    }
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
            let orphanedToAggregate = orphanedSnapshots.dropFirst(Self.maxSnapshotEntryPayloadsPerPath)
            for snapshot in orphanedToAggregate {
                if let snapshotId = snapshot.id {
                    snapshotIdsToAggregate.append(snapshotId)
                }
            }

            return Array(Set(snapshotIdsToAggregate)).sorted()
        }

        for snapshotId in snapshotIdsToAggregate {
            _ = try await aggregateSnapshotSummariesIfMissing(for: snapshotId)
        }
    }

    /// Aggregates category totals for a specific snapshot and writes to categorySnapshot table
    /// This is called for new snapshots immediately after creation, and for old snapshots before cleanup
    /// - Parameter snapshotId: The snapshot ID to aggregate
    public func aggregateCategoryTotals(for snapshotId: Int64) async throws {
        _ = try await aggregateCategoryTotalsIfMissing(for: snapshotId)
    }

    @discardableResult
    private func aggregateCategoryTotalsIfMissing(for snapshotId: Int64) async throws -> Bool {
        let result = try await aggregateSnapshotSummariesIfMissing(for: snapshotId)
        return result.categoryWritten
    }

    @discardableResult
    private func aggregateSubcategoryTotalsIfMissing(for snapshotId: Int64) async throws -> Bool {
        let result = try await aggregateSnapshotSummariesIfMissing(for: snapshotId)
        return result.subcategoryWritten
    }

    @discardableResult
    private func aggregateSnapshotSummariesIfMissing(
        for snapshotId: Int64
    ) async throws -> (categoryWritten: Bool, subcategoryWritten: Bool) {
        guard let dbPool = db.dbPool else {
            return (false, false)
        }

        let existing = try await dbPool.read { db in
            let categoryCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM categorySnapshot WHERE snapshotId = ?",
                arguments: [snapshotId]
            ) ?? 0
            let subcategoryCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM subcategorySnapshot WHERE snapshotId = ?",
                arguments: [snapshotId]
            ) ?? 0

            return (categoryCount: categoryCount, subcategoryCount: subcategoryCount)
        }

        let needsCategories = existing.categoryCount == 0
        let needsSubcategories = existing.subcategoryCount == 0
        guard needsCategories || needsSubcategories else {
            return (false, false)
        }

        let summary = try await buildSnapshotSummary(for: snapshotId)

        if needsCategories {
            try await db.replaceCategorySnapshots(snapshotId: snapshotId, totals: summary.categoryTotals)
        }

        if needsSubcategories {
            try await db.replaceSubcategorySnapshots(snapshotId: snapshotId, rows: summary.subcategoryRows)
        }

        return (
            categoryWritten: needsCategories && !summary.categoryTotals.isEmpty,
            subcategoryWritten: needsSubcategories && !summary.subcategoryRows.isEmpty
        )
    }

    private func buildSnapshotSummary(for snapshotId: Int64) async throws -> SnapshotSummary {
        var categoryTotals: [GrowthCategory: Int64] = [:]
        var grouped: [DatabaseManager.JournalDeltaKey: SubcategoryAccumulator] = [:]
        let pageSize = 5_000
        var offset = 0

        while true {
            let entries = try await db.fetchEntriesPaginatedUnordered(for: snapshotId, offset: offset, limit: pageSize)
            guard !entries.isEmpty else { break }

            for entry in entries {
                let category = GrowthCategory.categorize(path: entry.path)
                let subcategory = GrowthCategory.subcategorize(path: entry.path)
                categoryTotals[category, default: 0] += entry.sizeBytes

                let key = DatabaseManager.JournalDeltaKey(category: category, subcategory: subcategory)
                var value = grouped[key] ?? SubcategoryAccumulator()
                value.add(path: entry.path, sizeBytes: entry.sizeBytes, subcategory: subcategory)
                grouped[key] = value
            }

            offset += entries.count
        }

        let rows = grouped.map { key, accumulator in
            let finalized = accumulator.topItems.sorted { lhs, rhs in
                if lhs.currentSizeBytes == rhs.currentSizeBytes {
                    return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                }
                return lhs.currentSizeBytes > rhs.currentSizeBytes
            }.map { item in
                GrowthItem(
                    path: item.path,
                    growthBytes: item.currentSizeBytes,
                    currentSizeBytes: item.currentSizeBytes,
                    percentOfParent: accumulator.totalBytes > 0
                        ? Double(item.currentSizeBytes) / Double(accumulator.totalBytes)
                        : 0,
                    subcategory: key.subcategory
                )
            }

            return DatabaseManager.StoredSubcategorySnapshot(
                category: key.category,
                subcategory: key.subcategory,
                totalBytes: accumulator.totalBytes,
                fileCount: accumulator.fileCount,
                topItems: finalized
            )
        }

        return SnapshotSummary(
            categoryTotals: categoryTotals,
            subcategoryRows: rows
        )
    }

    /// Deletes snapshotEntry rows for old snapshots, keeping only the latest full payload per tracked path
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
                let toDelete = snapshots.dropFirst(Self.maxSnapshotEntryPayloadsPerPath)
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
            let orphanedToDelete = orphanedSnapshots.dropFirst(Self.maxSnapshotEntryPayloadsPerPath)
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
            var snapshotIDsToDelete = Set(try Int64.fetchAll(
                db,
                sql: "SELECT id FROM snapshot WHERE createdAt < ?",
                arguments: [cutoffDate]
            ))

            let trackedPathIds = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT trackedPathId FROM snapshot WHERE trackedPathId != '' ORDER BY trackedPathId"
            )

            for trackedPathId in trackedPathIds {
                let overflowIDs = try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT id
                        FROM snapshot
                        WHERE trackedPathId = ?
                        ORDER BY createdAt DESC, id DESC
                        LIMIT -1 OFFSET ?
                        """,
                    arguments: [trackedPathId, Self.maxCategoryHistorySnapshotsPerPath]
                )
                snapshotIDsToDelete.formUnion(overflowIDs)
            }

            let orphanOverflowIDs = try Int64.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM snapshot
                    WHERE trackedPathId = '' OR trackedPathId IS NULL
                    ORDER BY createdAt DESC, id DESC
                    LIMIT -1 OFFSET ?
                    """,
                arguments: [Self.maxCategoryHistorySnapshotsPerPath]
            )
            snapshotIDsToDelete.formUnion(orphanOverflowIDs)

            guard !snapshotIDsToDelete.isEmpty else { return 0 }

            let chunkSize = 500
            let orderedSnapshotIDs = snapshotIDsToDelete.sorted()
            var deleted = 0

            for startIndex in stride(from: 0, to: orderedSnapshotIDs.count, by: chunkSize) {
                let endIndex = min(startIndex + chunkSize, orderedSnapshotIDs.count)
                let chunk = Array(orderedSnapshotIDs[startIndex..<endIndex])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")

                // Delete snapshots older than retention or beyond the count cap.
                // Cascades handle category/subcategory summaries automatically.
                try db.execute(
                    sql: "DELETE FROM snapshot WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                deleted += try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
            }

            return deleted
        }
    }

    /// Deletes paths that are no longer referenced by snapshotEntry rows
    /// - Returns: Number of path rows deleted
    private func cleanupOrphanedPaths() async throws -> Int {
        guard let dbPool = db.dbPool else { return 0 }

        return try await dbPool.write { db in
            try db.execute(
                sql: """
                DELETE FROM paths
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM snapshotEntry
                    WHERE snapshotEntry.pathId = paths.id
                )
                AND NOT EXISTS (
                    SELECT 1
                    FROM workingSetEntry
                    WHERE workingSetEntry.pathId = paths.id
                )
                """
            )
            return try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
        }
    }

    /// Vacuums the database to reclaim space
    private func vacuumDatabase() async throws {
        guard let dbPool = db.dbPool else { return }

        try await dbPool.vacuum()
    }

    private struct SnapshotSummary {
        let categoryTotals: [GrowthCategory: Int64]
        let subcategoryRows: [DatabaseManager.StoredSubcategorySnapshot]
    }

    private struct SubcategoryAccumulator {
        var totalBytes: Int64 = 0
        var fileCount = 0
        var topItems: [GrowthItem] = []

        mutating func add(path: String, sizeBytes: Int64, subcategory: GrowthSubcategory?) {
            totalBytes += sizeBytes
            fileCount += 1

            let item = GrowthItem(
                path: path,
                growthBytes: sizeBytes,
                currentSizeBytes: sizeBytes,
                percentOfParent: 0,
                subcategory: subcategory
            )

            if topItems.count < SubcategoryGroup.initialLoadLimit {
                topItems.append(item)
                return
            }

            guard let smallestIndex = topItems.indices.min(by: {
                topItems[$0].currentSizeBytes < topItems[$1].currentSizeBytes
            }) else {
                return
            }
            guard sizeBytes > topItems[smallestIndex].currentSizeBytes else { return }
            topItems[smallestIndex] = item
        }
    }
}
