import Foundation
import GRDB
import OSLog

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
    }

    // MARK: - Constants

    private static let maxSnapshotEntryPayloadsPerPath = 1
    /// Keep the latest two snapshots available for history/reconciliation lookups.
    private static let recentHistorySnapshotsPerPath = 2
    /// Bound retained summary snapshots so scan-heavy same-day sessions don't grow history indefinitely.
    private static let maxCategoryHistorySnapshotsPerPath = 500
    private static let vacuumTimestampKey = "databaseLastVacuumAt"
    private static let checkpointInterval: TimeInterval = 60
    private static let checkpointTimestampKey = "databaseLastCheckpointAt"
    private static let appVersionKey = "appLastLaunchedVersion"
    private static let startupCleanupTimestampKey = "databaseLastStartupCleanupAt"
    private static let startupCleanupInterval: TimeInterval = 12 * 60 * 60
    private static let startupAggressiveWalSizeBytes: Int64 = 32 * 1024 * 1024
    private static let startupInitialDelay: TimeInterval = 2 * 60
    private static let startupIdlePollInterval: TimeInterval = 5
    private static let startupIdleMaxWait: TimeInterval = 5 * 60
    /// Incomplete snapshots newer than this are treated as in-flight, not abandoned.
    static let abandonedScanGracePeriod: TimeInterval = 15 * 60
    private static let compactIdleMaxWait: TimeInterval = 10
    private static let compactIdlePollInterval: TimeInterval = 0.5
    private static let minimumReclaimFreeBytes: Int64 = 64 * 1024 * 1024
    private static let incrementalVacuumChunkBytes: Int64 = 64 * 1024 * 1024
    private static let incrementalConversionDiskFactor: Int64 = 2

    /// Default retention period for category history (30 days)
    private static let defaultCategoryHistoryRetentionDays = 30

    // MARK: - Properties

    static let shared = DatabaseCleanupService()

    private let db = DatabaseManager.shared
    private var isStartupMaintenanceRunning = false
    private let logger = Logger(subsystem: "com.prunr.app", category: "DatabaseCleanup")

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
    }

    // MARK: - Public API

    /// Performs automatic cleanup after a scan completes.
    /// Keeps only the latest full raw snapshot payload per tracked path.
    func performAutoCleanup() async {
        do {
            try await aggregateCategoryTotalsForOldSnapshots()

            let entriesDeleted = try await cleanupOldSnapshotEntries()

            let pathsDeleted = try await cleanupOrphanedPaths()

            let snapshotsDeleted = try await cleanupOldCategoryHistory()

            let reclaimedRows = entriesDeleted > 0 || pathsDeleted > 0 || snapshotsDeleted > 0
            let storageAfterCleanup = await databaseStorageStats()
            if reclaimedRows && Self.freePagesWorthReclaiming(freelistBytes: storageAfterCleanup.freelistBytes) {
                _ = try await reclaimFreePages()
                try await db.checkpointWalTruncate()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkpointTimestampKey)
            } else if shouldCheckpointNow() {
                try await db.checkpointWalTruncate()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkpointTimestampKey)
            }
        } catch {
            logger.error("Auto-cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    struct StartupMaintenancePlan: Equatable, Sendable {
        let runCleanup: Bool
        let checkpoint: Bool
        let reclaimFreePages: Bool
    }

    enum AutoVacuumConversion: Equatable, Sendable {
        case alreadyIncremental
        case converted
        case skippedLowDisk
        case skippedBusy
        case failed
    }

    static func startupMaintenancePlan(
        versionChanged: Bool,
        walBytes: Int64,
        freelistBytes: Int64,
        lastCleanupAt: TimeInterval,
        lastCheckpointAt: TimeInterval,
        now: TimeInterval
    ) -> StartupMaintenancePlan {
        let cleanupDue = lastCleanupAt == 0 || now - lastCleanupAt >= startupCleanupInterval
        let largeWal = walBytes >= startupAggressiveWalSizeBytes
        let reclaim = freePagesWorthReclaiming(freelistBytes: freelistBytes)
        let checkpointDue = lastCheckpointAt == 0 || now - lastCheckpointAt >= checkpointInterval
        return StartupMaintenancePlan(
            runCleanup: cleanupDue || versionChanged || largeWal,
            checkpoint: reclaim || versionChanged || largeWal || checkpointDue,
            reclaimFreePages: reclaim
        )
    }

    static func freePagesWorthReclaiming(freelistBytes: Int64) -> Bool {
        freelistBytes >= minimumReclaimFreeBytes
    }

    static func hasDiskForIncrementalConversion(databaseBytes: Int64, availableBytes: Int64?) -> Bool {
        guard let availableBytes else { return false }
        return availableBytes >= databaseBytes * incrementalConversionDiskFactor
    }

    static func incrementalVacuumPagesPerStep(pageSize: Int64) -> Int {
        guard pageSize > 0 else { return 1 }
        return Int(max(1, incrementalVacuumChunkBytes / pageSize))
    }

    /// One-time switch of an existing database to `auto_vacuum = INCREMENTAL`.
    /// SQLite only changes that mode through a full VACUUM outside a
    /// transaction, so this cannot be a migration.
    @discardableResult
    func convertToIncrementalAutoVacuumIfNeeded(busyCheck: (@Sendable () async -> Bool)? = nil) async -> AutoVacuumConversion {
        do {
            guard try await db.autoVacuumMode() != DatabaseManager.incrementalAutoVacuumMode else {
                return .alreadyIncremental
            }
        } catch {
            logger.error("Auto-vacuum mode check failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }

        let sizes = databaseFileSizes()
        let databaseBytes = sizes.dbBytes + sizes.walBytes
        guard Self.hasDiskForIncrementalConversion(databaseBytes: databaseBytes, availableBytes: availableDiskBytes()) else {
            logger.notice("Incremental auto-vacuum switch skipped: low disk space")
            return .skippedLowDisk
        }
        let busy: Bool
        if let busyCheck {
            busy = await busyCheck()
        } else {
            busy = await isAppBusy()
        }
        guard !busy else { return .skippedBusy }

        do {
            try await db.checkpointWalTruncate()
            try await vacuumDatabase()
            try await db.checkpointWalTruncate()
            let now = Date().timeIntervalSince1970
            UserDefaults.standard.set(now, forKey: Self.vacuumTimestampKey)
            UserDefaults.standard.set(now, forKey: Self.checkpointTimestampKey)
            return .converted
        } catch {
            logger.error("Incremental auto-vacuum switch failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    @discardableResult
    func reclaimFreePages() async throws -> Int64 {
        guard try await db.autoVacuumMode() == DatabaseManager.incrementalAutoVacuumMode else { return 0 }

        let stats = await databaseStorageStats()
        let pagesPerStep = Self.incrementalVacuumPagesPerStep(pageSize: stats.pageSize)
        var remaining = stats.freelistCount
        while remaining > 0 {
            let next = try await db.incrementalVacuum(pages: pagesPerStep)
            guard next < remaining else { break }
            remaining = next
        }
        return (stats.freelistCount - remaining) * stats.pageSize
    }

    func performStartupMaintenance() async {
        guard !isStartupMaintenanceRunning else { return }
        isStartupMaintenanceRunning = true
        defer { isStartupMaintenanceRunning = false }

        // Give initial autoscan/watcher setup time to settle before maintenance can claim the writer.
        try? await Task.sleep(for: .milliseconds(Int(Self.startupInitialDelay * 1000)))

        let becameIdle = await waitForAppToBeIdle(
            maxWait: Self.startupIdleMaxWait,
            pollInterval: Self.startupIdlePollInterval
        )
        guard becameIdle else {
            return
        }

        _ = try? await cleanupAbandonedSnapshots()
        // Journal pruning otherwise runs only after a full scan; at startup it
        // keeps the history at its window even when no scan has run for days.
        await pruneGrowthJournal()

        let appVersion = currentAppVersion()
        let lastVersion = UserDefaults.standard.string(forKey: Self.appVersionKey)
        let versionChanged = lastVersion != appVersion

        await convertToIncrementalAutoVacuumIfNeeded()

        let initialPlan = await currentStartupPlan(versionChanged: versionChanged)
        guard initialPlan.runCleanup else { return }

        _ = try? await backfillRecentCategorySnapshots()
        await performAutoCleanup()

        let plan = await currentStartupPlan(versionChanged: versionChanged)
        do {
            if plan.reclaimFreePages, await !isAppBusy() {
                _ = try await reclaimFreePages()
            }
            if plan.checkpoint {
                try await db.checkpointWalTruncate()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkpointTimestampKey)
            }
        } catch {
            logger.error("Startup maintenance failed: \(error.localizedDescription, privacy: .public)")
        }

        UserDefaults.standard.set(appVersion, forKey: Self.appVersionKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.startupCleanupTimestampKey)
    }

    /// Deletes journal buckets past the retention setting, never inside the
    /// change list's 30-day history (`GrowthJournalService.prune` clamps).
    func pruneGrowthJournal(now: Date = Date()) async {
        let retentionDays = await SettingsStore.shared.categoryHistoryRetentionDays
        await GrowthJournalService.shared.prune(retentionDays: retentionDays, now: now)
    }

    /// Deletes snapshots left behind by process death during a full scan.
    ///
    /// Normal scan failures are cleaned up by ScanService, but a killed process cannot
    /// run that handler. Completed scans rebuild the working set with the snapshot
    /// timestamp; abandoned snapshots are newer than the live working set.
    /// Fresh `.scanning` rows inside the grace window are left alone so launch
    /// cleanup cannot delete an in-flight scan.
    @discardableResult
    func cleanupAbandonedSnapshots() async throws -> Int {
        guard let dbPool = db.dbPool else { return 0 }

        let staleBefore = Date().addingTimeInterval(-Self.abandonedScanGracePeriod)

        return try await dbPool.write { db in
            let snapshotIDs = try Int64.fetchAll(
                db,
                sql: """
                    SELECT s.id
                    FROM snapshot s
                    LEFT JOIN (
                        SELECT trackedPathId, MAX(updatedAt) AS latestWorkingSetUpdate
                        FROM workingSetEntry
                        GROUP BY trackedPathId
                    ) ws ON ws.trackedPathId = s.trackedPathId
                    WHERE (s.lifecycle != ? AND s.createdAt < ?)
                       OR (s.lifecycle = ?
                           AND s.trackedPathId != ''
                           AND ws.latestWorkingSetUpdate IS NOT NULL
                           AND s.id > (
                               SELECT MAX(source.id)
                               FROM snapshot source
                               WHERE source.trackedPathId = s.trackedPathId
                                 AND source.lifecycle = ?
                                 AND source.createdAt <= ws.latestWorkingSetUpdate
                           ))
                    """,
                    arguments: [
                        Snapshot.Lifecycle.complete.rawValue,
                        staleBefore,
                        Snapshot.Lifecycle.complete.rawValue,
                        Snapshot.Lifecycle.complete.rawValue
                    ]
                )

            guard !snapshotIDs.isEmpty else { return 0 }

            let chunkSize = 500
            var deleted = 0
            for startIndex in stride(from: 0, to: snapshotIDs.count, by: chunkSize) {
                let endIndex = min(startIndex + chunkSize, snapshotIDs.count)
                let chunk = Array(snapshotIDs[startIndex..<endIndex])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                try db.execute(
                    sql: "DELETE FROM snapshot WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                deleted += chunk.count
            }

            return deleted
        }
    }

    /// Performs an explicit one-shot maintenance pass and forces WAL checkpoint + VACUUM.
    /// Refuses while a scan/refresh is running so abandoned cleanup cannot delete live work.
    func compactDatabaseNow() async throws -> MaintenanceReport {
        let becameIdle = await waitForAppToBeIdle(
            maxWait: Self.compactIdleMaxWait,
            pollInterval: Self.compactIdlePollInterval
        )
        guard becameIdle else {
            throw CleanupError.appBusy
        }

        let before = databaseFileSizes()
        _ = try await cleanupAbandonedSnapshots()
        let backfilled = try await backfillRecentCategorySnapshots()
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
            backfilledSnapshots: backfilled
        )
    }

    private func currentStartupPlan(versionChanged: Bool) async -> StartupMaintenancePlan {
        let stats = await databaseStorageStats()
        let defaults = UserDefaults.standard
        return Self.startupMaintenancePlan(
            versionChanged: versionChanged,
            walBytes: stats.walBytes,
            freelistBytes: stats.freelistBytes,
            lastCleanupAt: defaults.double(forKey: Self.startupCleanupTimestampKey),
            lastCheckpointAt: defaults.double(forKey: Self.checkpointTimestampKey),
            now: Date().timeIntervalSince1970
        )
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

    private func availableDiskBytes() -> Int64? {
        guard let dbPath = db.databasePath else { return nil }
        let directory = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values?.volumeAvailableCapacity.map { Int64($0) }
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
                || manager.isReconciling
                || manager.isInventoryRefreshInProgress
                || manager.isUpdatingDrilldownIndex
        }
    }

    /// Ensures the latest retained snapshots already have aggregated category totals.
    /// This keeps current inventory and trend calculations fast without re-reading huge snapshots.
    private func backfillRecentCategorySnapshots() async throws -> Int {
        let snapshotIds = try await recentSnapshotIDs()

        var backfilled = 0
        for snapshotId in snapshotIds {
            if try await aggregateCategoryTotalsIfMissing(for: snapshotId) {
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
                        ORDER BY id DESC
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
                    ORDER BY id DESC
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
                    WHERE trackedPathId = ? AND lifecycle = ?
                    ORDER BY id DESC
                    """,
                    arguments: [pathId, Snapshot.Lifecycle.complete.rawValue]
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
                ORDER BY id DESC
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
            _ = try await aggregateCategoryTotalsIfMissing(for: snapshotId)
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
        guard let dbPool = db.dbPool else {
            return false
        }

        let categoryCount = try await dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM categorySnapshot WHERE snapshotId = ?",
                arguments: [snapshotId]
            ) ?? 0
        }
        guard categoryCount == 0 else { return false }

        let totals = try await buildCategoryTotals(for: snapshotId)
        try await db.replaceCategorySnapshots(snapshotId: snapshotId, totals: totals)
        return !totals.isEmpty
    }

    private func buildCategoryTotals(for snapshotId: Int64) async throws -> [GrowthCategory: Int64] {
        var categoryTotals: [GrowthCategory: Int64] = [:]
        let pageSize = 5_000
        var lastEntryId: Int64?

        while true {
            let entries = try await db.fetchEntriesPaginatedUnordered(
                for: snapshotId,
                afterEntryId: lastEntryId,
                limit: pageSize
            )
            guard !entries.isEmpty else { break }

            for entry in entries {
                categoryTotals[GrowthCategory.categorize(path: entry.path), default: 0] += entry.sizeBytes
            }

            lastEntryId = entries.last?.id
        }

        return categoryTotals
    }

    /// Deletes snapshotEntry rows for old snapshots, keeping only the latest full payload per tracked path
    /// Snapshot metadata (and categorySnapshot rows) are preserved for historical trend analysis
    /// - Returns: Number of snapshots that had their entries deleted
    private func cleanupOldSnapshotEntries() async throws -> Int {
        guard let dbPool = db.dbPool else { return 0 }

        return try await dbPool.write { db in
            var totalProcessed = 0

            let pathIds = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT trackedPathId FROM snapshot WHERE trackedPathId != '' ORDER BY trackedPathId"
            )

            for pathId in pathIds {
                let snapshots = try Snapshot.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM snapshot
                    WHERE trackedPathId = ? AND lifecycle = ?
                    ORDER BY id DESC
                    """,
                    arguments: [pathId, Snapshot.Lifecycle.complete.rawValue]
                )

                let toDelete = snapshots.dropFirst(Self.maxSnapshotEntryPayloadsPerPath)
                for snapshot in toDelete {
                    if let snapshotId = snapshot.id, try Self.trimPayload(of: snapshotId, db: db) {
                        totalProcessed += 1
                    }
                }
            }

            let orphanedSnapshots = try Snapshot.fetchAll(
                db,
                sql: """
                SELECT * FROM snapshot
                WHERE trackedPathId = '' OR trackedPathId IS NULL
                ORDER BY id DESC
                """
            )
            let orphanedToDelete = orphanedSnapshots.dropFirst(Self.maxSnapshotEntryPayloadsPerPath)
            for snapshot in orphanedToDelete {
                if let snapshotId = snapshot.id, try Self.trimPayload(of: snapshotId, db: db) {
                    totalProcessed += 1
                }
            }

            return totalProcessed
        }
    }

    private static func trimPayload(of snapshotId: Int64, db: Database) throws -> Bool {
        let entryCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM snapshotEntry WHERE snapshotId = ?",
            arguments: [snapshotId]
        ) ?? 0
        guard entryCount > 0 else { return false }

        try db.execute(
            sql: "UPDATE snapshot SET entryCount = ? WHERE id = ? AND entryCount IS NULL",
            arguments: [entryCount, snapshotId]
        )
        try db.execute(sql: "DELETE FROM snapshotEntry WHERE snapshotId = ?", arguments: [snapshotId])
        return true
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
                        ORDER BY id DESC
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
                    ORDER BY id DESC
                    LIMIT -1 OFFSET ?
                    """,
                arguments: [Self.maxCategoryHistorySnapshotsPerPath]
            )
            snapshotIDsToDelete.formUnion(orphanOverflowIDs)

            let newestCompleteIDs = try Int64.fetchAll(
                db,
                sql: """
                    SELECT s.id
                    FROM snapshot s
                    WHERE s.trackedPathId != ''
                      AND s.lifecycle = ?
                      AND s.id = (
                          SELECT newest.id
                          FROM snapshot newest
                          WHERE newest.trackedPathId = s.trackedPathId
                            AND newest.lifecycle = ?
                          ORDER BY newest.id DESC
                          LIMIT 1
                      )
                    """,
                arguments: [Snapshot.Lifecycle.complete.rawValue, Snapshot.Lifecycle.complete.rawValue]
            )
            snapshotIDsToDelete.subtract(newestCompleteIDs)

            guard !snapshotIDsToDelete.isEmpty else { return 0 }

            let chunkSize = 500
            let orderedSnapshotIDs = snapshotIDsToDelete.sorted()
            var deleted = 0

            for startIndex in stride(from: 0, to: orderedSnapshotIDs.count, by: chunkSize) {
                let endIndex = min(startIndex + chunkSize, orderedSnapshotIDs.count)
                let chunk = Array(orderedSnapshotIDs[startIndex..<endIndex])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")

                // Delete snapshots older than retention or beyond the count cap.
                // Cascades handle category summaries automatically.
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

    private func vacuumDatabase() async throws {
        guard db.dbPool != nil else { return }

        try await db.vacuumIntoIncrementalAutoVacuum()
    }
}

extension DatabaseCleanupService {
    enum CleanupError: Error, LocalizedError {
        case appBusy

        var errorDescription: String? {
            switch self {
            case .appBusy:
                return "Cannot compact while a scan or refresh is running. Try again when Prunr is idle."
            }
        }
    }
}
