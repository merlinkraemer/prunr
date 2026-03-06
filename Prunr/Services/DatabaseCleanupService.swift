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

    /// Keep only the latest full snapshot payload for each path.
    /// Current UI/state is driven from category + subcategory aggregates, not old raw entry sets.
    private static let maxSnapshotEntryPayloadsPerPath = 1
    /// Keep the latest two snapshots available for history/reconciliation lookups.
    private static let recentHistorySnapshotsPerPath = 2
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
            if entriesDeleted > 0 {
                print("[DatabaseCleanupService] Auto-cleanup: deleted \(entriesDeleted) old snapshot entries")
            }

            // Remove paths that are no longer referenced by snapshotEntry rows
            let pathsDeleted = try await cleanupOrphanedPaths()
            if pathsDeleted > 0 {
                print("[DatabaseCleanupService] Auto-cleanup: deleted \(pathsDeleted) orphaned paths")
            }

            // Third pass: delete old snapshot rows entirely (and cascading categorySnapshot rows)
            let snapshotsDeleted = try await cleanupOldCategoryHistory()
            if snapshotsDeleted > 0 {
                print("[DatabaseCleanupService] Auto-cleanup: deleted \(snapshotsDeleted) old snapshots")
            }

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
            print("[DatabaseCleanupService] Startup maintenance skipped while app remained busy")
            return
        }

        let backfilled = (try? await backfillRecentCategorySnapshots()) ?? 0
        let backfilledSubcategories = (try? await backfillRecentSubcategorySnapshots()) ?? 0
        if backfilled > 0 {
            print("[DatabaseCleanupService] Startup maintenance: backfilled \(backfilled) recent category snapshots")
        }
        if backfilledSubcategories > 0 {
            print("[DatabaseCleanupService] Startup maintenance: backfilled \(backfilledSubcategories) recent subcategory snapshots")
        }

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
            if try await aggregateCategoryTotalsIfMissing(for: snapshotId) {
                backfilled += 1
            }
        }

        return backfilled
    }

    private func backfillRecentSubcategorySnapshots() async throws -> Int {
        let snapshotIds = try await recentSnapshotIDs()

        var backfilled = 0
        for snapshotId in snapshotIds {
            if try await aggregateSubcategoryTotalsIfMissing(for: snapshotId) {
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
                let toAggregate = snapshots.dropFirst(Self.maxSnapshotEntryPayloadsPerPath)
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
                let orphanedToAggregate = orphanedSnapshots.dropFirst(Self.maxSnapshotEntryPayloadsPerPath)
                for snapshot in orphanedToAggregate {
                    if let snapshotId = snapshot.id {
                        snapshotIdsToAggregate.append(snapshotId)
                    }
                }

                // Aggregate category totals for all identified snapshots
                for snapshotId in snapshotIdsToAggregate {
                    // Check if already aggregated
                    let existingCount = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM categorySnapshot WHERE snapshotId = ?",
                        arguments: [snapshotId]
                    ) ?? 0
                    guard existingCount == 0 else { continue }

                    // Use SQL-based aggregation for speed
                    try self.aggregateCategoriesInSQL(for: snapshotId, db: db)
                }
            }
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
        guard let dbPool = db.dbPool else { return false }

        return try await dbPool.write { db in
            // Check if already aggregated (idempotency guard)
            let existingCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM categorySnapshot WHERE snapshotId = ?",
                arguments: [snapshotId]
            ) ?? 0

            guard existingCount == 0 else { return false }

            // Use SQL-based aggregation for speed (handles most categories)
            // This is 100x faster than row-by-row Swift processing
            let startTime = Date()
            try self.aggregateCategoriesInSQL(for: snapshotId, db: db)
            let elapsed = Date().timeIntervalSince(startTime)

            print("[DatabaseCleanupService] SQL aggregation for snapshot \(snapshotId) completed in \(String(format: "%.2f", elapsed))s")

            return true
        }
    }

    /// Fast SQL-based category aggregation using LIKE patterns
    /// Handles the major categories directly in SQL for 100x speedup
    private nonisolated func aggregateCategoriesInSQL(for snapshotId: Int64, db: Database) throws {
        // SQL-based categorization using lowercased paths
        // Categories match GrowthCategory.categorize() raw values
        let home = FileManager.default.homeDirectoryForCurrentUser.path.lowercased()
        let homeTrash = home + "/.trash"
        let homeDownloads = home + "/downloads"
        let homeDocuments = home + "/documents"
        let homeLibrary = home + "/library"
        let homeLibraryCaches = homeLibrary + "/caches"

        func addLike(_ pattern: String, conditions: inout [String], args: inout [String]) {
            conditions.append("path LIKE ?")
            args.append(pattern)
        }

        func addCondition(_ condition: String, args newArgs: [String], conditions: inout [String], args: inout [String]) {
            conditions.append(condition)
            args.append(contentsOf: newArgs)
        }

        var trashConditions: [String] = []
        var trashArgs: [String] = []
        addLike(homeTrash, conditions: &trashConditions, args: &trashArgs)
        addLike(homeTrash + "/%", conditions: &trashConditions, args: &trashArgs)

        var downloadConditions: [String] = []
        var downloadArgs: [String] = []
        addLike(homeDownloads, conditions: &downloadConditions, args: &downloadArgs)
        addLike(homeDownloads + "/%", conditions: &downloadConditions, args: &downloadArgs)

        var developerConditions: [String] = []
        var developerArgs: [String] = []
        addLike("%/docker.raw%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/docker/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%com.docker%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/library/containers/com.docker%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/node_modules/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/.git/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/.git", conditions: &developerConditions, args: &developerArgs)
        addLike("%/deriveddata/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/target/release%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/target/debug%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/.build/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/.build", conditions: &developerConditions, args: &developerArgs)
        addLike("%/dist/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/build/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/var/lib/postgresql%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/postgres%", conditions: &developerConditions, args: &developerArgs)
        addLike("%postgresql%", conditions: &developerConditions, args: &developerArgs)
        addLike("%.sqlite", conditions: &developerConditions, args: &developerArgs)
        addLike("%.sqlite3", conditions: &developerConditions, args: &developerArgs)
        addLike("%.sqlite-wal", conditions: &developerConditions, args: &developerArgs)
        addLike("%.sqlite-shm", conditions: &developerConditions, args: &developerArgs)
        addLike("%/.venv/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/.venv", conditions: &developerConditions, args: &developerArgs)
        addLike("%/venv/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/.virtualenvs/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/.virtualenvs", conditions: &developerConditions, args: &developerArgs)
        addLike("%/.pyenv/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/.pyenv", conditions: &developerConditions, args: &developerArgs)
        addLike("%/xcode/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/android/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/workspace/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/dev/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/projects/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/code/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/repos/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%/src/%", conditions: &developerConditions, args: &developerArgs)
        addLike("%.dsym", conditions: &developerConditions, args: &developerArgs)
        addLike("%.ipa", conditions: &developerConditions, args: &developerArgs)

        var audioConditions: [String] = []
        var audioArgs: [String] = []
        addLike("%/ableton/%", conditions: &audioConditions, args: &audioArgs)
        addLike("%ableton project info%", conditions: &audioConditions, args: &audioArgs)
        addLike("%.als", conditions: &audioConditions, args: &audioArgs)
        addLike("%/splice/%", conditions: &audioConditions, args: &audioArgs)
        addLike("%/native instruments/%", conditions: &audioConditions, args: &audioArgs)
        addLike("%/kontakt/%", conditions: &audioConditions, args: &audioArgs)
        addLike("%library/application support/native instruments%", conditions: &audioConditions, args: &audioArgs)
        addLike("%/samples/%", conditions: &audioConditions, args: &audioArgs)
        addLike("%/music/samples%", conditions: &audioConditions, args: &audioArgs)
        addLike("%/audio/plug-ins/%", conditions: &audioConditions, args: &audioArgs)
        addLike("%library/audio/%", conditions: &audioConditions, args: &audioArgs)
        addLike("%/components/%", conditions: &audioConditions, args: &audioArgs)
        addLike("%.vst", conditions: &audioConditions, args: &audioArgs)
        addLike("%.vst3", conditions: &audioConditions, args: &audioArgs)
        addLike("%.component", conditions: &audioConditions, args: &audioArgs)
        addLike("%.wav", conditions: &audioConditions, args: &audioArgs)
        addLike("%.aif", conditions: &audioConditions, args: &audioArgs)
        addLike("%.aiff", conditions: &audioConditions, args: &audioArgs)
        addLike("%.mp3", conditions: &audioConditions, args: &audioArgs)
        addLike("%.flac", conditions: &audioConditions, args: &audioArgs)
        addLike("%.ogg", conditions: &audioConditions, args: &audioArgs)
        addLike("%.m4a", conditions: &audioConditions, args: &audioArgs)

        var applicationsConditions: [String] = []
        var applicationsArgs: [String] = []
        addLike("%/applications/%", conditions: &applicationsConditions, args: &applicationsArgs)
        addLike("%.app", conditions: &applicationsConditions, args: &applicationsArgs)
        addLike("%.app/%", conditions: &applicationsConditions, args: &applicationsArgs)
        addLike("/opt/homebrew%", conditions: &applicationsConditions, args: &applicationsArgs)
        addLike("/usr/local/cellar%", conditions: &applicationsConditions, args: &applicationsArgs)
        addLike("/usr/local/caskroom%", conditions: &applicationsConditions, args: &applicationsArgs)
        addLike("%library/caches/homebrew%", conditions: &applicationsConditions, args: &applicationsArgs)
        addLike("%/.npm-global/%", conditions: &applicationsConditions, args: &applicationsArgs)
        addLike("%/.npm-global", conditions: &applicationsConditions, args: &applicationsArgs)
        addLike("%/.bun/%", conditions: &applicationsConditions, args: &applicationsArgs)
        addLike("%/.bun", conditions: &applicationsConditions, args: &applicationsArgs)
        addLike("/usr/local/lib/node_modules%", conditions: &applicationsConditions, args: &applicationsArgs)
        addLike("%/.yarn/%", conditions: &applicationsConditions, args: &applicationsArgs)
        addLike("%/.yarn", conditions: &applicationsConditions, args: &applicationsArgs)

        var mediaConditions: [String] = []
        var mediaArgs: [String] = []
        addLike("%photos library.photoslibrary%", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%/movies/%", conditions: &mediaConditions, args: &mediaArgs)
        addLike(homeDocuments, conditions: &mediaConditions, args: &mediaArgs)
        addLike(homeDocuments + "/%", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.jpg", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.jpeg", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.png", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.heic", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.raw", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.mov", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.mp4", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.mkv", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.avi", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.m4v", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.psd", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.sketch", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.fig", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.ai", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.xd", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.pdf", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.doc", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.docx", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.xls", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.xlsx", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.ppt", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.pptx", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.pages", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.numbers", conditions: &mediaConditions, args: &mediaArgs)
        addLike("%.key", conditions: &mediaConditions, args: &mediaArgs)

        var cacheConditions: [String] = []
        var cacheArgs: [String] = []
        addLike(homeLibraryCaches, conditions: &cacheConditions, args: &cacheArgs)
        addLike(homeLibraryCaches + "/%", conditions: &cacheConditions, args: &cacheArgs)
        addLike("%/library/caches/%", conditions: &cacheConditions, args: &cacheArgs)
        addLike("%/.cache/%", conditions: &cacheConditions, args: &cacheArgs)
        addCondition("(path LIKE ? AND (path LIKE ? OR path LIKE ? OR path LIKE ?))", args: ["%cache%", "%chrome%", "%safari%", "%firefox%"], conditions: &cacheConditions, args: &cacheArgs)
        addLike("%com.spotify%", conditions: &cacheConditions, args: &cacheArgs)
        addLike("%/spotify/%", conditions: &cacheConditions, args: &cacheArgs)
        addLike("%/mail/%", conditions: &cacheConditions, args: &cacheArgs)
        addLike("%com.apple.mail%", conditions: &cacheConditions, args: &cacheArgs)
        addLike("%mail download%", conditions: &cacheConditions, args: &cacheArgs)
        addLike("%attachments%", conditions: &cacheConditions, args: &cacheArgs)
        addCondition("(path LIKE ? AND path NOT LIKE ? AND path NOT LIKE ? AND path NOT LIKE ? AND path NOT LIKE ?)", args: [homeLibrary + "/%", homeLibraryCaches + "/%", "/opt/homebrew%", "/usr/local/cellar%", "/usr/local/caskroom%"], conditions: &cacheConditions, args: &cacheArgs)

        let trashClause = trashConditions.joined(separator: " OR ")
        let downloadsClause = downloadConditions.joined(separator: " OR ")
        let developerClause = developerConditions.joined(separator: " OR ")
        let audioClause = audioConditions.joined(separator: " OR ")
        let applicationsClause = applicationsConditions.joined(separator: " OR ")
        let mediaClause = mediaConditions.joined(separator: " OR ")
        let cacheClause = cacheConditions.joined(separator: " OR ")

        var args: [String] = []
        args.append(contentsOf: trashArgs)
        args.append(contentsOf: downloadArgs)
        args.append(contentsOf: developerArgs)
        args.append(contentsOf: audioArgs)
        args.append(contentsOf: applicationsArgs)
        args.append(contentsOf: mediaArgs)
        args.append(contentsOf: cacheArgs)

        let sql = """
            WITH entries AS (
                SELECT lower(p.path) AS path, se.sizeBytes AS sizeBytes
                FROM snapshotEntry se
                JOIN paths p ON p.id = se.pathId
                WHERE se.snapshotId = ?
            )
            INSERT INTO categorySnapshot (snapshotId, category, totalBytes)
            SELECT
                ? AS snapshotId,
                CASE
                    WHEN \(trashClause) THEN '\(GrowthCategory.trash.rawValue)'
                    WHEN \(downloadsClause) THEN '\(GrowthCategory.downloads.rawValue)'
                    WHEN \(developerClause) THEN '\(GrowthCategory.developer.rawValue)'
                    WHEN \(audioClause) THEN '\(GrowthCategory.audioProduction.rawValue)'
                    WHEN \(applicationsClause) THEN '\(GrowthCategory.applications.rawValue)'
                    WHEN \(mediaClause) THEN '\(GrowthCategory.mediaAndDocuments.rawValue)'
                    WHEN \(cacheClause) THEN '\(GrowthCategory.cachesAndSystem.rawValue)'
                    ELSE '\(GrowthCategory.other.rawValue)'
                END AS category,
                SUM(sizeBytes) AS totalBytes
            FROM entries
            GROUP BY category
            """

        var statementArgs: [DatabaseValueConvertible] = [snapshotId, snapshotId]
        statementArgs.append(contentsOf: args)

        try db.execute(sql: sql, arguments: StatementArguments(statementArgs))
    }

    @discardableResult
    private func aggregateSubcategoryTotalsIfMissing(for snapshotId: Int64) async throws -> Bool {
        guard let dbPool = db.dbPool else { return false }

        let existing = try await dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM subcategorySnapshot WHERE snapshotId = ?",
                arguments: [snapshotId]
            ) ?? 0
        }

        guard existing == 0 else { return false }

        struct Accumulator {
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
                } else if let smallestIndex = topItems.indices.min(by: {
                    topItems[$0].currentSizeBytes < topItems[$1].currentSizeBytes
                }), sizeBytes > topItems[smallestIndex].currentSizeBytes {
                    topItems[smallestIndex] = item
                }
            }
        }

        var grouped: [String: (category: GrowthCategory, subcategory: GrowthSubcategory?, accumulator: Accumulator)] = [:]
        let pageSize = 5_000
        var offset = 0

        while true {
            let entries = try await db.fetchEntriesPaginatedUnordered(for: snapshotId, offset: offset, limit: pageSize)
            guard !entries.isEmpty else { break }

            for entry in entries {
                let category = GrowthCategory.categorize(path: entry.path)
                let subcategory = GrowthCategory.subcategorize(path: entry.path)
                let key = "\(category.rawValue)::\(subcategory?.rawValue ?? "")"

                var value = grouped[key] ?? (category, subcategory, Accumulator())
                value.accumulator.add(path: entry.path, sizeBytes: entry.sizeBytes, subcategory: subcategory)
                grouped[key] = value
            }

            offset += entries.count
        }

        guard !grouped.isEmpty else { return false }

        let rows = grouped.values.map { value in
            let finalized = value.accumulator.topItems.sorted { $0.currentSizeBytes > $1.currentSizeBytes }.map { item in
                GrowthItem(
                    path: item.path,
                    growthBytes: item.currentSizeBytes,
                    currentSizeBytes: item.currentSizeBytes,
                    percentOfParent: value.accumulator.totalBytes > 0
                        ? Double(item.currentSizeBytes) / Double(value.accumulator.totalBytes)
                        : 0,
                    subcategory: value.subcategory
                )
            }

            return DatabaseManager.StoredSubcategorySnapshot(
                category: value.category,
                subcategory: value.subcategory,
                totalBytes: value.accumulator.totalBytes,
                fileCount: value.accumulator.fileCount,
                topItems: finalized
            )
        }

        try await db.replaceSubcategorySnapshots(snapshotId: snapshotId, rows: rows)
        return true
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
                """
            )
            return try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
        }
    }

    /// Vacuums the database to reclaim space
    private func vacuumDatabase() async throws {
        guard let dbPool = db.dbPool else { return }

        print("[DatabaseCleanupService] Running VACUUM...")
        try await dbPool.vacuum()
        print("[DatabaseCleanupService] VACUUM complete")
    }
}
