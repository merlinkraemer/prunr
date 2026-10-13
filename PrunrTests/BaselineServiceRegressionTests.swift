import XCTest
import GRDB
@testable import Prunr

final class BaselineServiceRegressionTests: PrunrTestCase {

    // MARK: - Signed growth over a fixed window

    private func makeTrackedPath(_ id: UUID) -> TrackedPath {
        TrackedPath(
            id: id,
            url: URL(fileURLWithPath: "/Users/tester/dev", isDirectory: true),
            displayName: "dev"
        )
    }

    /// The header must equal the signed sum of every category delta, including
    /// sub-floor categories that never render a delta line.
    func testGrowthStoriesSumSignedAcrossCategoriesIncludingSubFloor() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = self.makeTrackedPath(trackedPathId)
            let gb: Int64 = 1024 * 1024 * 1024

            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [
                    .init(category: .developer, subcategory: nil, unitKey: "place|/Users/tester/dev"): -20 * gb,
                    .init(category: .downloads, subcategory: nil, unitKey: "place|/Users/tester/dev"): 1 * gb,
                    // Sub-floor: hidden by the row renderer, still in the sum.
                    .init(category: .applications, subcategory: nil, unitKey: "place|/Users/tester/dev"): 800_000
                ],
                at: Date().addingTimeInterval(-3600)
            )

            let stories = await GrowthJournalService.shared.recentGrowthStories(trackedPath: trackedPath)

            XCTAssertEqual(stories[.developer]?.deltaBytes, -20 * gb)
            XCTAssertEqual(stories[.downloads]?.deltaBytes, 1 * gb)
            XCTAssertEqual(stories[.applications]?.deltaBytes, 800_000)

            let signedTotal = stories.values.reduce(Int64(0)) { $0 + $1.deltaBytes }
            XCTAssertEqual(signedTotal, -19 * gb + 800_000)
        }
    }

    /// Grew then cleared inside the window nets to zero — no story at all, not `+8 GB`.
    func testCategoryClearedInWindowProducesNoStory() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = self.makeTrackedPath(trackedPathId)
            let eightGB: Int64 = 8 * 1024 * 1024 * 1024

            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .cachesAndSystem, subcategory: nil, unitKey: "place|/Users/tester/dev"): eightGB],
                at: Date().addingTimeInterval(-7200)
            )
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .cachesAndSystem, subcategory: nil, unitKey: "place|/Users/tester/dev"): -eightGB],
                at: Date().addingTimeInterval(-3600)
            )

            let stories = await GrowthJournalService.shared.recentGrowthStories(trackedPath: trackedPath)
            XCTAssertNil(stories[.cachesAndSystem])
        }
    }

    /// Retention governs pruning only. Lowering it must not change what the
    /// fixed display window counts, and pruning must never reach inside it.
    func testDisplayWindowIsIndependentOfRetentionSetting() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = self.makeTrackedPath(trackedPathId)
            let inWindow: Int64 = 5 * 1024 * 1024
            let outOfWindow: Int64 = 16 * 1024 * 1024 * 1024
            let day: TimeInterval = 24 * 60 * 60

            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .developer, subcategory: nil, unitKey: "place|/Users/tester/dev"): inWindow],
                at: Date().addingTimeInterval(-2 * day)
            )
            // 9 days back: outside the 7-day display window.
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .developer, subcategory: nil, unitKey: "place|/Users/tester/dev"): outOfWindow],
                at: Date().addingTimeInterval(-9 * day)
            )

            let stories = await GrowthJournalService.shared.recentGrowthStories(trackedPath: trackedPath)
            XCTAssertEqual(stories[.developer]?.deltaBytes, inWindow, "the 9-day-old spike must have aged out")

            // A retention shorter than the display window must be clamped, so
            // pruning cannot delete the bucket that is still on screen.
            await GrowthJournalService.shared.prune(retentionDays: 1)

            let afterPrune = await GrowthJournalService.shared.recentGrowthStories(trackedPath: trackedPath)
            XCTAssertEqual(
                afterPrune[.developer]?.deltaBytes,
                inWindow,
                "pruning must never reach inside the display window"
            )
        }
    }

    @MainActor
    func testRetentionSettingIsClampedToHistoryWindow() {
        let previous = SettingsStore.shared.categoryHistoryRetentionDays
        defer { SettingsStore.shared.categoryHistoryRetentionDays = previous }

        SettingsStore.shared.categoryHistoryRetentionDays = 3
        XCTAssertEqual(SettingsStore.shared.categoryHistoryRetentionDays, 30)
        SettingsStore.shared.categoryHistoryRetentionDays = 7
        XCTAssertEqual(SettingsStore.shared.categoryHistoryRetentionDays, 30)
        XCTAssertEqual(GrowthJournalService.historyWindowDays, 30)
    }

    /// Buckets older than 30 local days are pruned (here by the startup
    /// maintenance step), even with a retention setting of 7; the 30 days
    /// the list shows stay.
    func testStartupPruneKeepsThirtyLocalDaysWithSevenDayRetention() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = self.makeTrackedPath(trackedPathId)
            let calendar = Calendar.current
            let now = Date()
            let today = calendar.startOfDay(for: now)
            func daysAgo(_ days: Int) -> Date {
                calendar.date(byAdding: .hour, value: 12, to: calendar.date(byAdding: .day, value: -days, to: today)!)!
            }
            let key = DatabaseManager.JournalDeltaKey(category: .developer, subcategory: nil, unitKey: "place|/Users/tester/dev")
            try await GrowthJournalService.shared.recordDeltas(trackedPath: trackedPath, deltas: [key: 1_000], at: daysAgo(8))
            try await GrowthJournalService.shared.recordDeltas(trackedPath: trackedPath, deltas: [key: 2_000], at: daysAgo(29))
            try await GrowthJournalService.shared.recordDeltas(trackedPath: trackedPath, deltas: [key: 4_000], at: daysAgo(30))
            try await GrowthJournalService.shared.recordDeltas(trackedPath: trackedPath, deltas: [key: 8_000], at: daysAgo(45))

            // Not read: the feed's window starts at local midnight 29 days back.
            let slots = try await DatabaseManager.shared.fetchJournalSlots(
                trackedPathIds: [trackedPathId],
                since: EpisodeBuilder.windowStart(now: now, calendar: calendar)
            )
            XCTAssertEqual(Set(slots.map(\.netBytes)), [1_000, 2_000])

            let previous = await MainActor.run { SettingsStore.shared.categoryHistoryRetentionDays }
            await MainActor.run { SettingsStore.shared.categoryHistoryRetentionDays = 7 }
            await DatabaseCleanupService.shared.pruneGrowthJournal(now: now)
            await MainActor.run { SettingsStore.shared.categoryHistoryRetentionDays = previous }

            let left = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            XCTAssertEqual(Set(left.map(\.deltaBytes)), [1_000, 2_000])
        }
    }
    func testAcceptGrowthPromotesWorkingSetWithoutFilesystemFreeSpace() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = TrackedPath(
                id: trackedPathId,
                url: URL(fileURLWithPath: "/Users/tester/dev", isDirectory: true),
                displayName: "dev"
            )
            let liveFile = trackedPath.url.appendingPathComponent("app/.build/output.bin")

            _ = try await DatabaseManager.shared.replaceWorkingSetSubtree(
                trackedPathId: trackedPathId,
                rootPath: trackedPath.url.path,
                entries: [
                    ScanResult(path: liveFile.path, sizeBytes: 128_000)
                ]
            )
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .developer, subcategory: .buildArtifacts, unitKey: "place|/Users/tester/dev"): 128_000],
                at: Date()
            )

            try await BaselineService.shared.acceptGrowth(for: trackedPath)

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let state = try await dbPool.read { db in
                let snapshotCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM snapshot WHERE trackedPathId = ?",
                    arguments: [trackedPathId.uuidString]
                ) ?? 0
                let freeBytesCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM snapshot WHERE trackedPathId = ? AND freeBytes IS NOT NULL",
                    arguments: [trackedPathId.uuidString]
                ) ?? 0
                let snapshotBytes = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT COALESCE(SUM(se.sizeBytes), 0)
                        FROM snapshotEntry se
                        JOIN snapshot s ON s.id = se.snapshotId
                        WHERE s.trackedPathId = ?
                        """,
                    arguments: [trackedPathId.uuidString]
                ) ?? 0
                let journalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalBucket") ?? 0
                return (snapshotCount, freeBytesCount, snapshotBytes, journalCount)
            }

            XCTAssertEqual(state.0, 1)
            XCTAssertEqual(state.1, 0)
            XCTAssertEqual(state.2, 128_000)
            XCTAssertEqual(state.3, 0)
        }
    }

    func testFirstBaselineClearsStaleRealtimeStateForTrackedPath() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrBaselineFresh")
            defer {
                try? FileManager.default.removeItem(at: tempDirectory)
            }

            let liveFile = tempDirectory.appendingPathComponent("existing.txt")
            try Data(repeating: 0xCD, count: 2_048).write(to: liveFile)

            _ = try await DatabaseManager.shared.replaceWorkingSetSubtree(
                trackedPathId: trackedPathId,
                rootPath: tempDirectory.path,
                entries: [
                    ScanResult(path: liveFile.path, sizeBytes: 2_048),
                    ScanResult(path: tempDirectory.appendingPathComponent("stale.txt").path, sizeBytes: 4_096)
                ]
            )

            try await DatabaseManager.shared.upsertGrowthJournalBuckets(
                trackedPathId: trackedPathId,
                bucketStart: Date(),
                deltas: [.init(category: .other, subcategory: nil, unitKey: "place|/Users/tester/dev"): 6_144]
            )

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")
            _ = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let counts = try await dbPool.read { db in
                let journalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalBucket") ?? 0
                let workingSetCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM workingSetEntry WHERE trackedPathId = ?",
                    arguments: [trackedPathId.uuidString]
                ) ?? 0
                return (journalCount, workingSetCount)
            }

            XCTAssertEqual(counts.0, 0)
            XCTAssertEqual(counts.1, 1)
            try await self.assertDrilldownIndexExact(trackedPathId, "after the first full scan")
        }
    }

    // MARK: - Scan residuals keep watcher timestamps

    private static let mb: Int64 = 1_024 * 1_024

    private static func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: floor(date.timeIntervalSinceReferenceDate / 60) * 60)
    }

    /// Whole-second "now", so dates round-trip through SQLite exactly.
    private static func wholeSecondNow() -> Date {
        Date(timeIntervalSinceReferenceDate: floor(Date().timeIntervalSinceReferenceDate))
    }

    /// Moves a snapshot back in time so a test can place watcher buckets inside
    /// the reconciliation window (the real gap between scans is hours).
    private func backdateSnapshot(_ snapshot: Snapshot, to date: Date) async throws {
        let snapshotId = try XCTUnwrap(snapshot.id)
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE snapshot SET createdAt = ? WHERE id = ?",
                arguments: [date, snapshotId]
            )
        }
    }

    /// The key the watcher writes for a file: its category and its unit.
    private func journalKey(for file: URL) -> DatabaseManager.JournalDeltaKey {
        .init(
            category: GrowthCategory.categorize(path: file.path),
            subcategory: GrowthCategory.subcategorize(path: file.path),
            unitKey: UnitResolver.resolve(path: file.path)
        )
    }

    /// A watch +10 MB at T1 followed by a scan finding +12 MB leaves +10 MB at T1
    /// (watch) and +2 MB at scan start (scan), and the window still sums to the
    /// snapshot delta.
    func testFullScanKeepsWatcherTimestampAndAddsOnlyResidual() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrResidualGrow")
            defer { try? FileManager.default.removeItem(at: tempDirectory) }

            let file = tempDirectory.appendingPathComponent("blob.bin")
            let initialBytes = 4_096
            try Data(repeating: 0xAB, count: initialBytes).write(to: file)
            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")

            let s0 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            let windowStart = Self.wholeSecondNow().addingTimeInterval(-7_200)
            try await self.backdateSnapshot(s0, to: windowStart)

            let watchAt = Date().addingTimeInterval(-3_600)
            let watchBytes = 10 * Self.mb
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [self.journalKey(for: file): watchBytes],
                at: watchAt
            )

            let sizeBefore = try self.diskUsageBytes(at: file)
            try Data(repeating: 0xAB, count: initialBytes + Int(12 * Self.mb)).write(to: file)
            let authoritative = try self.diskUsageBytes(at: file) - sizeBefore
            XCTAssertEqual(authoritative, 12 * Self.mb)

            let s1 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)

            let buckets = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            let watch = buckets.filter { $0.source == .watch }
            let scan = buckets.filter { $0.source == .scan }

            XCTAssertEqual(watch.count, 1)
            XCTAssertEqual(watch.first?.bucketStart, Self.floorToMinute(watchAt), "the scan must not move the watcher's time")
            XCTAssertEqual(watch.first?.deltaBytes, watchBytes)
            XCTAssertNil(watch.first?.observedSince)

            XCTAssertFalse(scan.isEmpty)
            XCTAssertEqual(scan.reduce(Int64(0)) { $0 + $1.deltaBytes }, 2 * Self.mb)
            for bucket in scan {
                XCTAssertEqual(bucket.bucketStart, Self.floorToMinute(s1.createdAt), "residual lands at scan start")
                XCTAssertEqual(bucket.observedSince, windowStart)
            }

            let windowTotal = buckets
                .filter { $0.bucketStart > windowStart && $0.bucketStart <= s1.createdAt }
                .reduce(Int64(0)) { $0 + $1.deltaBytes }
            XCTAssertEqual(windowTotal, authoritative, "window total must equal the snapshot delta")
        }
    }

    /// A watch +10 MB followed by a scan that finds no change leaves a −10 MB residual.
    func testFullScanWritesNegativeResidualWhenWatcherOverCounted() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrResidualZero")
            defer { try? FileManager.default.removeItem(at: tempDirectory) }

            let file = tempDirectory.appendingPathComponent("blob.bin")
            try Data(repeating: 0xAB, count: 4_096).write(to: file)
            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")

            let s0 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            let windowStart = Self.wholeSecondNow().addingTimeInterval(-7_200)
            try await self.backdateSnapshot(s0, to: windowStart)

            let watchAt = Date().addingTimeInterval(-3_600)
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [self.journalKey(for: file): 10 * Self.mb],
                at: watchAt
            )

            let s1 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)

            let buckets = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            let watch = buckets.filter { $0.source == .watch }
            let scan = buckets.filter { $0.source == .scan }

            XCTAssertEqual(watch.map(\.deltaBytes), [10 * Self.mb])
            XCTAssertEqual(watch.first?.bucketStart, Self.floorToMinute(watchAt))
            XCTAssertEqual(scan.count, 1)
            XCTAssertEqual(scan.first?.deltaBytes, -10 * Self.mb)
            XCTAssertEqual(scan.first?.bucketStart, Self.floorToMinute(s1.createdAt))
            XCTAssertEqual(scan.first?.observedSince, windowStart)
            XCTAssertEqual(buckets.reduce(Int64(0)) { $0 + $1.deltaBytes }, 0)
        }
    }

    /// Regression: a full scan must not double-count growth the realtime watcher
    /// already recorded. Both the incremental refresh and `createBaseline` write
    /// to the growth journal, and the journal accumulates. The scan adds only the
    /// residual between its snapshot delta and what the window already holds, so
    /// growth the watcher caught exactly yields no scan row, and repeated
    /// reconciliation cycles keep the total equal to the actual growth.
    func testReconciliationFullScanDoesNotDoubleCountRealtimeGrowth() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrDoubleCount")
            defer { try? FileManager.default.removeItem(at: tempDirectory) }

            let file = tempDirectory.appendingPathComponent("blob.bin")
            let initialBytes = 4_096
            let growthBytes = 3 * Self.mb
            try Data(repeating: 0xAB, count: initialBytes).write(to: file)

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")

            // 1) First baseline (S0) — establishes the reference; no journal yet.
            let s0 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            try await self.backdateSnapshot(s0, to: Self.wholeSecondNow().addingTimeInterval(-7_200))

            // 2) File grows on disk; the realtime watcher records the delta into the
            //    journal (simulated here via recordDeltas, as RecentChangeService does)
            //    inside the window before the next scan.
            let sizeBefore = try self.diskUsageBytes(at: file)
            try Data(repeating: 0xAB, count: initialBytes + Int(growthBytes)).write(to: file)
            XCTAssertEqual(try self.diskUsageBytes(at: file) - sizeBefore, growthBytes)
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [self.journalKey(for: file): growthBytes],
                at: Date().addingTimeInterval(-3_600)
            )

            // 3) Reconciliation full scan (S1) sees the same grown file. The watcher
            //    already accounts for it, so the residual is zero.
            _ = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            // 4) A second reconciliation with nothing new must not add anything either.
            _ = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)

            let buckets = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            XCTAssertTrue(buckets.allSatisfy { $0.source == .watch }, "no residual when the watcher was exact")

            // 5) Displayed growth must equal the ACTUAL growth, not 2x.
            let stories = await GrowthJournalService.shared.recentGrowthStories(
                trackedPath: trackedPath
            )
            let total = stories.values.reduce(Int64(0)) { $0 + $1.deltaBytes }
            XCTAssertEqual(
                total,
                growthBytes,
                "growth should be counted once; got \(total) bytes vs expected \(growthBytes)"
            )
        }
    }

    /// A cancelled scan must leave the journal exactly as it was.
    func testCancelledFullScanWritesNoJournalBuckets() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrResidualCancel")
            defer { try? FileManager.default.removeItem(at: tempDirectory) }

            let file = tempDirectory.appendingPathComponent("blob.bin")
            try Data(repeating: 0xAB, count: 4_096).write(to: file)
            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")

            let s0 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            try await self.backdateSnapshot(s0, to: Self.wholeSecondNow().addingTimeInterval(-7_200))
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [self.journalKey(for: file): 10 * Self.mb],
                at: Date().addingTimeInterval(-3_600)
            )
            try Data(repeating: 0xAB, count: 4_096 + Int(12 * Self.mb)).write(to: file)

            let before = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)

            let scanTask = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            }
            do {
                try await scanTask.value
                XCTFail("a cancelled scan must throw")
            } catch {
                // Expected: cancellation surfaces as an error.
            }

            let after = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            XCTAssertEqual(after, before)
            XCTAssertFalse(after.contains { $0.source == .scan })
        }
    }

    /// Buckets written before v21 read back as watcher buckets, and the identity
    /// index lets a scan residual share a minute and key with a watch bucket.
    func testJournalSourceMigrationTagsExistingBucketsAsWatch() throws {
        let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrMigrationV21")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let dbQueue = try DatabaseQueue(path: tempDirectory.appendingPathComponent("prunr.sqlite").path)
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v20_add_snapshot_lifecycle")

        let trackedPathId = UUID().uuidString
        let bucketStart = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try dbQueue.write { db in
            for (category, delta) in [("other", Int64(1_000)), ("downloads", Int64(-2_000))] {
                try db.execute(
                    sql: """
                        INSERT INTO growthJournalBucket (trackedPathId, bucketStart, category, subcategory, deltaBytes)
                        VALUES (?, ?, ?, '', ?)
                        """,
                    arguments: [trackedPathId, bucketStart, category, delta]
                )
            }
        }

        try migrator.migrate(dbQueue, upTo: "v22_journal_unit")

        try dbQueue.write { db in
            let buckets = try GrowthJournalBucket.fetchAll(
                db,
                sql: "SELECT * FROM growthJournalBucket ORDER BY deltaBytes"
            )
            XCTAssertEqual(buckets.map(\.deltaBytes), [-2_000, 1_000])
            XCTAssertTrue(buckets.allSatisfy { $0.source == .watch })
            XCTAssertTrue(buckets.allSatisfy { $0.observedSince == nil })

            // Same identity but source 'scan' is a separate row, not a conflict.
            try db.execute(
                sql: """
                    INSERT INTO growthJournalBucket
                        (trackedPathId, bucketStart, category, subcategory, deltaBytes, source)
                    VALUES (?, ?, 'other', '', 5, 'scan')
                    """,
                arguments: [trackedPathId, bucketStart]
            )
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalBucket") ?? 0
            XCTAssertEqual(count, 3)
        }
    }

    func testSingleSnapshotInventorySurfacesRealtimeGrowthStory() async throws {
        try await withTemporaryDatabase { trackedPathId, snapshotId in
            let trackedPath = TrackedPath(
                id: trackedPathId,
                url: URL(fileURLWithPath: "/Users/tester/dev", isDirectory: true),
                displayName: "dev"
            )

            try await DatabaseManager.shared.addEntries(
                to: snapshotId,
                entries: [
                    ScanResult(path: "/Users/tester/dev/app/.build/output.bin", sizeBytes: 128_000)
                ]
            )
            try await DatabaseManager.shared.rebuildWorkingSet(
                from: snapshotId,
                trackedPathId: trackedPathId
            )

            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .developer, subcategory: .nodeModules, unitKey: "place|/Users/tester/dev"): 2 * 1_024 * 1_024],
                at: Date()
            )

            let inventory = await BaselineService.shared.getInventoryWithTrends(trackedPath: trackedPath)
            let developer = try XCTUnwrap(inventory.first(where: { $0.category == .developer }))
            XCTAssertEqual(developer.currentSizeBytes, 128_000)
            XCTAssertEqual(developer.recentGrowthStory?.deltaBytes, 2 * 1_024 * 1_024)
        }
    }
}
