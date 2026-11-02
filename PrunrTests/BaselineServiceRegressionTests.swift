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
            try self.dateBeforeHistory(liveFile)

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
            try self.dateBeforeHistory(file)
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

    func testClearedHistoryStaysClearedThroughTheNextScan() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrClearHistory")
            defer {
                try? FileManager.default.removeItem(at: tempDirectory)
                HistoryStart.reset()
            }

            let file = tempDirectory.appendingPathComponent("blob.bin")
            let initialBytes = 4_096
            try Data(repeating: 0xAB, count: initialBytes).write(to: file)
            try self.dateBeforeHistory(file)
            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")

            let s0 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            try await self.backdateSnapshot(s0, to: Self.wholeSecondNow().addingTimeInterval(-7_200))
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [self.journalKey(for: file): 10 * Self.mb],
                at: Date().addingTimeInterval(-3_600)
            )
            try Data(repeating: 0xAB, count: initialBytes + Int(12 * Self.mb)).write(to: file)

            let clearedAt = Date()
            try await BaselineService.shared.clearHistory()
            let afterClear = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            XCTAssertTrue(afterClear.isEmpty)
            let kept = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPathId)
            XCTAssertEqual(kept.map(\.id), [s0.id], "the baseline stays")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(HistoryStart.stored()), clearedAt.addingTimeInterval(-1))

            let s1 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            let afterScan = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            XCTAssertTrue(afterScan.isEmpty, "changes from before the clear must not come back as a scan residual")
            XCTAssertFalse(afterScan.contains { $0.source == .files }, "no file-date history after a clear")

            let sizeBefore = try self.diskUsageBytes(at: file)
            try Data(repeating: 0xAB, count: initialBytes + Int(15 * Self.mb)).write(to: file)
            let newGrowth = try self.diskUsageBytes(at: file) - sizeBefore
            _ = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            let later = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            XCTAssertEqual(later.reduce(Int64(0)) { $0 + $1.deltaBytes }, newGrowth, "changes after the clear show")
            XCTAssertFalse(later.isEmpty)
            XCTAssertTrue(later.allSatisfy { abs(($0.observedSince ?? .distantPast).timeIntervalSince(s1.createdAt)) < 1 })
        }
    }

    func testOnlyScanWindowsThatStartAfterTheClearKeepTheirResidual() throws {
        let suite = "PrunrTests.HistoryClear.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clearedAt = Date(timeIntervalSince1970: 5_000)

        XCTAssertTrue(HistoryStart.scanWindowKeepsResidual(windowStart: Date(timeIntervalSince1970: 1_000), defaults: defaults))
        HistoryStart.clear(at: clearedAt, defaults: defaults)
        XCTAssertEqual(HistoryStart.stored(defaults: defaults), clearedAt)
        XCTAssertFalse(HistoryStart.scanWindowKeepsResidual(windowStart: Date(timeIntervalSince1970: 4_999), defaults: defaults))
        XCTAssertTrue(HistoryStart.scanWindowKeepsResidual(windowStart: clearedAt, defaults: defaults))
        HistoryStart.reset(defaults: defaults)
        XCTAssertNil(HistoryStart.cleared(defaults: defaults))
    }

    /// A watch +10 MB followed by a scan that finds no change leaves a −10 MB residual.
    func testFullScanWritesNegativeResidualWhenWatcherOverCounted() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrResidualZero")
            defer { try? FileManager.default.removeItem(at: tempDirectory) }

            let file = tempDirectory.appendingPathComponent("blob.bin")
            try Data(repeating: 0xAB, count: 4_096).write(to: file)
            try self.dateBeforeHistory(file)
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
            try self.dateBeforeHistory(file)

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
            try self.dateBeforeHistory(file)
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

    func testDeniedFolderCarriesForwardWithoutShrinkOrLaterGrowth() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrDeniedCarry")
            let locked = tempDirectory.appendingPathComponent("locked", isDirectory: true)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
                try? FileManager.default.removeItem(at: tempDirectory)
            }
            let readable = tempDirectory.appendingPathComponent("open/notes.txt")
            let secret = locked.appendingPathComponent("deep/secret.mov")
            for (url, bytes) in [(readable, 8_192), (secret, 65_536)] {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x5A, count: bytes).write(to: url)
                try self.dateBeforeHistory(url)
            }
            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")
            let secretBytes = try self.diskUsageBytes(at: secret)
            let readableBytes = try self.diskUsageBytes(at: readable)

            let s0 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath, ignoredNames: [])
            try await self.backdateSnapshot(s0, to: Self.wholeSecondNow().addingTimeInterval(-7_200))

            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            let skipLog = ScanSkipLog()
            let s1 = try await BaselineService.shared.createBaseline(
                trackedPath: trackedPath,
                ignoredNames: [],
                skipLog: skipLog
            )
            XCTAssertEqual(s1.lifecycle, .complete)
            XCTAssertEqual(skipLog.locationLabels, ["locked"])

            let afterDenied = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            XCTAssertTrue(afterDenied.filter { $0.source == .scan }.isEmpty, "a denied folder must not be journaled as a shrink")
            let pathsWhileDenied = try await self.workingSetPaths(trackedPathId: trackedPathId)
            XCTAssertTrue(pathsWhileDenied.contains { $0.hasSuffix("/locked/deep/secret.mov") }, "the working set keeps the denied folder")
            let entryCount = try await DatabaseManager.shared.fetchEntryCount(for: try XCTUnwrap(s1.id))
            XCTAssertEqual(entryCount, 2)
            let totals = try await DatabaseManager.shared.fetchWorkingSetCategoryTotals(for: trackedPathId)
            XCTAssertEqual(totals.reduce(Int64(0)) { $0 + $1.currentSizeBytes }, secretBytes + readableBytes)

            try await self.backdateSnapshot(s1, to: Self.wholeSecondNow().addingTimeInterval(-3_600))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            let s2 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath, ignoredNames: [])

            let afterRestored = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            XCTAssertTrue(afterRestored.filter { $0.source == .scan }.isEmpty, "regained access must not be journaled as growth")
            let restoredCount = try await DatabaseManager.shared.fetchEntryCount(for: try XCTUnwrap(s2.id))
            XCTAssertEqual(restoredCount, 2)
            let pathsRestored = try await self.workingSetPaths(trackedPathId: trackedPathId)
            XCTAssertTrue(pathsRestored.contains { $0.hasSuffix("/locked/deep/secret.mov") })
        }
    }

    func testOutermostPathsDropsNestedAndDuplicatePaths() {
        XCTAssertEqual(
            ScanService.outermostPaths(["/a/b/c", "/a/b", "/a/b-old", "/a/b/", "/x"]),
            ["/a/b", "/a/b-old", "/x"]
        )
    }

    func testAgeCleanupKeepsNewestCompleteSnapshotAndItsEntries() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let entries = [ScanResult(path: "/Users/tester/dev/app/a.bin", sizeBytes: 1_000)]
            let now = Date()
            var completeIds: [Int64] = []
            for daysAgo in [90, 60, 45] {
                let id = try await self.insertSnapshotRow(
                    trackedPathId: trackedPathId,
                    createdAt: now.addingTimeInterval(TimeInterval(-daysAgo * 24 * 3_600)),
                    lifecycle: .complete
                )
                try await DatabaseManager.shared.addEntries(to: id, entries: entries)
                completeIds.append(id)
            }
            for minutesAgo in [2, 1] {
                let id = try await self.insertSnapshotRow(
                    trackedPathId: trackedPathId,
                    createdAt: now.addingTimeInterval(TimeInterval(-minutesAgo * 60)),
                    lifecycle: .scanning
                )
                try await DatabaseManager.shared.addEntries(to: id, entries: entries)
            }

            let previous = await MainActor.run { SettingsStore.shared.categoryHistoryRetentionDays }
            await MainActor.run { SettingsStore.shared.categoryHistoryRetentionDays = 30 }
            await DatabaseCleanupService.shared.performAutoCleanup()
            await MainActor.run { SettingsStore.shared.categoryHistoryRetentionDays = previous }

            let kept = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPathId)
            XCTAssertEqual(kept.map(\.id), [completeIds.last], "the newest complete snapshot survives the age cutoff")
            let keptEntries = try await DatabaseManager.shared.fetchEntryCount(for: try XCTUnwrap(completeIds.last))
            XCTAssertEqual(keptEntries, 1, "scanning rows must not push the newest complete payload out")
            let hasBaseline = await BaselineService.shared.hasBaseline()
            XCTAssertTrue(hasBaseline)
        }
    }

    /// A failure after the working set is rebuilt must leave the new snapshot
    /// unpublished, so the retry still diffs against the previous baseline.
    func testFailureBeforePublishKeepsPreviousBaselineAndJournalsWindowOnRetry() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrPublishLast")
            defer { try? FileManager.default.removeItem(at: tempDirectory) }

            let file = tempDirectory.appendingPathComponent("blob.bin")
            try Data(repeating: 0xAB, count: 4_096).write(to: file)
            try self.dateBeforeHistory(file)
            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")

            let s0 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            try await self.backdateSnapshot(s0, to: Self.wholeSecondNow().addingTimeInterval(-7_200))
            try Data(repeating: 0xAB, count: 4_096 + Int(3 * Self.mb)).write(to: file)

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            try await dbPool.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER failJournalInsert BEFORE INSERT ON growthJournalBucket
                    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
                    """)
            }
            do {
                _ = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
                XCTFail("the injected journal failure must surface")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("injected failure"))
            }

            try await dbPool.write { db in
                try db.execute(sql: "DROP TRIGGER failJournalInsert")
            }

            let snapshots = try await dbPool.read { db in
                try Row.fetchAll(db, sql: "SELECT id, lifecycle FROM snapshot WHERE trackedPathId = ?", arguments: [trackedPathId.uuidString])
                    .map { (id: $0["id"] as Int64, lifecycle: $0["lifecycle"] as String) }
            }
            XCTAssertEqual(snapshots.map(\.id), [try XCTUnwrap(s0.id)])
            XCTAssertEqual(snapshots.map(\.lifecycle), [Snapshot.Lifecycle.complete.rawValue])

            _ = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)

            let buckets = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            XCTAssertEqual(buckets.filter { $0.source == .scan }.reduce(Int64(0)) { $0 + $1.deltaBytes }, 3 * Self.mb)
        }
    }

    func testDiskUsageOfSparseFileIsAllocatedBytesNotLogicalSize() throws {
        let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrSparse")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let file = tempDirectory.appendingPathComponent("sparse.bin")
        let logicalBytes = 16 * Self.mb
        let descriptor = open(file.path, O_CREAT | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(ftruncate(descriptor, off_t(logicalBytes)), 0)
        close(descriptor)

        var fileStat = stat()
        XCTAssertEqual(lstat(file.path, &fileStat), 0)
        XCTAssertEqual(Int64(fileStat.st_size), logicalBytes)
        XCTAssertEqual(
            FileScanner.diskUsageBytes(for: fileStat),
            Int64(fileStat.st_blocks) * Int64(DEV_BSIZE)
        )
        XCTAssertLessThan(FileScanner.diskUsageBytes(for: fileStat), logicalBytes)
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

    private func workingSetPaths(trackedPathId: UUID) async throws -> [String] {
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
        let trackedPathIdText = trackedPathId.uuidString
        return try await dbPool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT p.path
                    FROM workingSetEntry w
                    JOIN paths p ON p.id = w.pathId
                    WHERE w.trackedPathId = ?
                    ORDER BY p.path
                    """,
                arguments: [trackedPathIdText]
            )
        }
    }

    private func rowCount(_ table: String) async throws -> Int {
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
        return try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private func insertStrayWorkingSetEntry(trackedPathId: UUID, path: String) async throws {
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
        let trackedPathIdText = trackedPathId.uuidString
        try await dbPool.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO paths (path) VALUES (?)", arguments: [path])
            let pathId = try XCTUnwrap(
                Int64.fetchOne(db, sql: "SELECT id FROM paths WHERE path = ?", arguments: [path])
            )
            try db.execute(
                sql: "INSERT INTO workingSetEntry (trackedPathId, pathId, sizeBytes, updatedAt) VALUES (?, ?, 1, ?)",
                arguments: [trackedPathIdText, pathId, Date()]
            )
        }
    }

    private func setFreeBytes(snapshotId: Int64, freeBytes: Int64?) async throws {
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE snapshot SET freeBytes = ? WHERE id = ?",
                arguments: [freeBytes, snapshotId]
            )
        }
    }

    func testDiskAccountingThrowsInsufficientWithOneSnapshotAndSumsCategoryDeltas() async throws {
        try await withTemporaryDatabase { trackedPathId, previousId in
            let trackedPath = self.makeTrackedPath(trackedPathId)

            do {
                _ = try await BaselineService.shared.getDiskAccounting(trackedPath: trackedPath)
                XCTFail("one snapshot is not enough to account for disk changes")
            } catch BaselineService.BaselineError.insufficientSnapshots {
            } catch {
                XCTFail("unexpected error \(error)")
            }

            try await DatabaseManager.shared.replaceCategorySnapshots(
                snapshotId: previousId,
                totals: [.developer: 10 * Self.mb, .downloads: 5 * Self.mb]
            )
            try await self.setFreeBytes(snapshotId: previousId, freeBytes: 100 * Self.mb)

            let current = try await DatabaseManager.shared.createSnapshot(
                trackedPathId: trackedPathId,
                freeBytes: 90 * Self.mb
            )
            let currentId = try XCTUnwrap(current.id)
            try await DatabaseManager.shared.replaceCategorySnapshots(
                snapshotId: currentId,
                totals: [.developer: 14 * Self.mb, .downloads: 3 * Self.mb, .applications: 2 * Self.mb]
            )

            let accounting = try await BaselineService.shared.getDiskAccounting(trackedPath: trackedPath)

            XCTAssertEqual(accounting.explainedDelta, 4 * Self.mb)
            XCTAssertEqual(accounting.previousFreeSpace, 100 * Self.mb)
            XCTAssertEqual(accounting.currentFreeSpace, 90 * Self.mb)
            XCTAssertEqual(accounting.freeSpaceDelta, -10 * Self.mb)
            XCTAssertEqual(accounting.unexplainedDelta, 6 * Self.mb)
        }
    }

    func testDiskAccountingUsesOnlyTheTwoNewestSnapshots() async throws {
        try await withTemporaryDatabase { trackedPathId, oldestId in
            let trackedPath = self.makeTrackedPath(trackedPathId)
            try await DatabaseManager.shared.replaceCategorySnapshots(
                snapshotId: oldestId,
                totals: [.developer: 100 * Self.mb]
            )

            var previousTotal = 8 * Self.mb
            for total in [8 * Self.mb, 11 * Self.mb] {
                previousTotal = total
                let snapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
                let snapshotId = try XCTUnwrap(snapshot.id)
                try await DatabaseManager.shared.replaceCategorySnapshots(
                    snapshotId: snapshotId,
                    totals: [.developer: total]
                )
            }

            let accounting = try await BaselineService.shared.getDiskAccounting(trackedPath: trackedPath)

            XCTAssertEqual(previousTotal, 11 * Self.mb)
            XCTAssertEqual(accounting.explainedDelta, 3 * Self.mb)
        }
    }

    func testDiskAccountingWithoutFreeBytesReportsOnlyExplainedDelta() async throws {
        try await withTemporaryDatabase { trackedPathId, previousId in
            let trackedPath = self.makeTrackedPath(trackedPathId)

            try await DatabaseManager.shared.replaceCategorySnapshots(
                snapshotId: previousId,
                totals: [.developer: 8 * Self.mb]
            )
            let current = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let currentId = try XCTUnwrap(current.id)
            try await DatabaseManager.shared.replaceCategorySnapshots(
                snapshotId: currentId,
                totals: [.developer: 3 * Self.mb]
            )

            let accounting = try await BaselineService.shared.getDiskAccounting(trackedPath: trackedPath)

            XCTAssertEqual(accounting.explainedDelta, -5 * Self.mb)
            XCTAssertNil(accounting.freeSpaceDelta)
            XCTAssertNil(accounting.unexplainedDelta)
        }
    }

    func testResetBaselineClearsSnapshotsWorkingSetJournalAndHistoryStart() async throws {
        try await withTemporaryDatabase { trackedPathId, firstSnapshotId in
            let trackedPath = self.makeTrackedPath(trackedPathId)
            let otherTrackedPathId = UUID()
            let entries = [
                ScanResult(path: "/Users/tester/dev/app/a.bin", sizeBytes: 1_000),
                ScanResult(path: "/Users/tester/dev/app/b.bin", sizeBytes: 2_000)
            ]

            try await DatabaseManager.shared.addEntries(to: firstSnapshotId, entries: entries)
            let secondSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let secondSnapshotId = try XCTUnwrap(secondSnapshot.id)
            try await DatabaseManager.shared.addEntries(to: secondSnapshotId, entries: entries)
            let otherSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: otherTrackedPathId)
            let otherSnapshotId = try XCTUnwrap(otherSnapshot.id)
            try await DatabaseManager.shared.addEntries(to: otherSnapshotId, entries: entries)

            try await DatabaseManager.shared.rebuildWorkingSet(from: secondSnapshotId, trackedPathId: trackedPathId)
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .developer, subcategory: nil, unitKey: "place|/Users/tester/dev"): Self.mb],
                at: Date()
            )
            HistoryStart.restart(at: Date())

            let workingSetBefore = try await self.workingSetPaths(trackedPathId: trackedPathId)
            XCTAssertEqual(workingSetBefore.count, 2)

            try await BaselineService.shared.resetBaseline()

            let remainingSnapshots = try await DatabaseManager.shared.fetchAllSnapshots()
            XCTAssertTrue(remainingSnapshots.isEmpty)
            for snapshotId in [firstSnapshotId, secondSnapshotId, otherSnapshotId] {
                let entryCount = try await DatabaseManager.shared.fetchEntryCount(for: snapshotId)
                XCTAssertEqual(entryCount, 0)
            }
            let workingSetAfter = try await self.workingSetPaths(trackedPathId: trackedPathId)
            XCTAssertTrue(workingSetAfter.isEmpty)
            let workingSetTotals = try await self.rowCount("workingSetCategoryTotal")
            XCTAssertEqual(workingSetTotals, 0)
            let journalBuckets = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            XCTAssertTrue(journalBuckets.isEmpty)
            XCTAssertNil(HistoryStart.stored())
            let hasBaseline = await BaselineService.shared.hasBaseline()
            XCTAssertFalse(hasBaseline)
        }
    }

    func testDrillDownReturnsOnlyDirectChildrenWithSummedSubtrees() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = self.makeTrackedPath(trackedPathId)
            let root = "/Users/tester/dev"

            let before = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let beforeId = try XCTUnwrap(before.id)
            try await DatabaseManager.shared.addEntries(to: beforeId, entries: [
                ScanResult(path: "\(root)/app/a.bin", sizeBytes: 100),
                ScanResult(path: "\(root)/app/sub/b.bin", sizeBytes: 100),
                ScanResult(path: "\(root)/app/shrunk.bin", sizeBytes: 500),
                ScanResult(path: "\(root)/other/c.bin", sizeBytes: 100)
            ])

            let after = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let afterId = try XCTUnwrap(after.id)
            try await DatabaseManager.shared.addEntries(to: afterId, entries: [
                ScanResult(path: "\(root)/app/a.bin", sizeBytes: 300),
                ScanResult(path: "\(root)/app/sub/b.bin", sizeBytes: 150),
                ScanResult(path: "\(root)/app/sub/d.bin", sizeBytes: 70),
                ScanResult(path: "\(root)/app/shrunk.bin", sizeBytes: 100),
                ScanResult(path: "\(root)/other/c.bin", sizeBytes: 100),
                ScanResult(path: "\(root)/other2/e.bin", sizeBytes: 40),
                ScanResult(path: "\(root)/application/x.bin", sizeBytes: 10),
                ScanResult(path: "\(root)/node_modules/pkg/y.bin", sizeBytes: 900)
            ])

            let items = try await BaselineService.shared.drillDown(path: "\(root)/app", trackedPath: trackedPath)

            XCTAssertEqual(items.map(\.path), ["\(root)/app/a.bin", "\(root)/app/sub"])
            XCTAssertEqual(items.map(\.growthBytes), [200, 120])
            XCTAssertEqual(items.map(\.currentSizeBytes), [300, 220])
            XCTAssertEqual(items[0].percentOfParent, 200.0 / 320.0, accuracy: 0.0001)
            XCTAssertEqual(items[1].percentOfParent, 120.0 / 320.0, accuracy: 0.0001)

            let boundaryItems = try await BaselineService.shared.drillDown(
                path: "\(root)/node_modules",
                trackedPath: trackedPath
            )
            XCTAssertTrue(boundaryItems.isEmpty)
        }
    }

    func testResolveGrowthComparisonSkipsTinyAndHalfSizedSnapshots() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            func makeEntries(_ count: Int, prefix: String) -> [ScanResult] {
                (0..<count).map { ScanResult(path: "/Users/tester/dev/\(prefix)/f-\($0).bin", sizeBytes: 10) }
            }

            let resolvedWithoutSnapshots = try await BaselineService.shared.resolveGrowthComparisonSnapshots(
                trackedPathId: trackedPathId
            )
            XCTAssertNil(resolvedWithoutSnapshots)

            var snapshotIds: [Int64] = []
            for (prefix, count) in [("old", 200), ("half", 120), ("tiny", 90), ("latest", 300)] {
                let snapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
                let snapshotId = try XCTUnwrap(snapshot.id)
                try await DatabaseManager.shared.addEntries(to: snapshotId, entries: makeEntries(count, prefix: prefix))
                snapshotIds.append(snapshotId)
            }

            let resolved = try await BaselineService.shared.resolveGrowthComparisonSnapshots(
                trackedPathId: trackedPathId
            )
            XCTAssertEqual(
                resolved,
                BaselineService.GrowthComparisonSnapshots(
                    currentSnapshotId: snapshotIds[3],
                    baselineSnapshotId: snapshotIds[0]
                )
            )

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let oldId = snapshotIds[0]
            try await dbPool.write { db in
                try db.execute(sql: "DELETE FROM snapshotEntry WHERE snapshotId = ?", arguments: [oldId])
            }

            let withoutComparable = try await BaselineService.shared.resolveGrowthComparisonSnapshots(
                trackedPathId: trackedPathId
            )
            XCTAssertEqual(
                withoutComparable,
                BaselineService.GrowthComparisonSnapshots(
                    currentSnapshotId: snapshotIds[3],
                    baselineSnapshotId: nil
                )
            )
        }
    }

    func testFailedInlineScanRestoresWorkingSetFromLatestCompleteSnapshot() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrFailedInlineScan")
            defer { try? FileManager.default.removeItem(at: tempDirectory) }
            try Data(repeating: 0xAB, count: 4_096).write(to: tempDirectory.appendingPathComponent("blob.bin"))

            let baseline = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let baselineId = try XCTUnwrap(baseline.id)
            try await DatabaseManager.shared.addEntries(to: baselineId, entries: [
                ScanResult(path: "/Users/tester/dev/keep-1.bin", sizeBytes: 10),
                ScanResult(path: "/Users/tester/dev/keep-2.bin", sizeBytes: 20)
            ])
            try await DatabaseManager.shared.rebuildWorkingSet(from: baselineId, trackedPathId: trackedPathId)
            try await self.insertStrayWorkingSetEntry(trackedPathId: trackedPathId, path: "/Users/tester/dev/stray.bin")

            let scanTask = Task {
                _ = try await ScanService.shared.scan(
                    path: tempDirectory.path,
                    trackedPathId: trackedPathId,
                    ignoredNames: [],
                    alsoWriteWorkingSet: true,
                    progress: { _ in withUnsafeCurrentTask { $0?.cancel() } }
                )
            }
            do {
                try await scanTask.value
                XCTFail("a cancelled scan must throw")
            } catch {
            }

            let workingSet = try await self.workingSetPaths(trackedPathId: trackedPathId)
            XCTAssertEqual(workingSet, ["/Users/tester/dev/keep-1.bin", "/Users/tester/dev/keep-2.bin"])

            let scanningSnapshots = try await self.rowCountWhere(
                "snapshot",
                condition: "lifecycle = 'scanning'"
            )
            XCTAssertEqual(scanningSnapshots, 0)
            let snapshots = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPathId)
            XCTAssertEqual(snapshots.compactMap(\.id), [baselineId])
        }
    }

    func testFailedInlineScanWithoutPriorSnapshotClearsWorkingSet() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrFailedFirstInlineScan")
            defer { try? FileManager.default.removeItem(at: tempDirectory) }
            try Data(repeating: 0xAB, count: 4_096).write(to: tempDirectory.appendingPathComponent("blob.bin"))

            try await self.insertStrayWorkingSetEntry(trackedPathId: trackedPathId, path: "/Users/tester/dev/stray.bin")

            let scanTask = Task {
                _ = try await ScanService.shared.scan(
                    path: tempDirectory.path,
                    trackedPathId: trackedPathId,
                    ignoredNames: [],
                    alsoWriteWorkingSet: true,
                    progress: { _ in withUnsafeCurrentTask { $0?.cancel() } }
                )
            }
            do {
                try await scanTask.value
                XCTFail("a cancelled scan must throw")
            } catch {
            }

            let workingSet = try await self.workingSetPaths(trackedPathId: trackedPathId)
            XCTAssertTrue(workingSet.isEmpty)
            let snapshotRows = try await self.rowCount("snapshot")
            XCTAssertEqual(snapshotRows, 0)
        }
    }

    private func rowCountWhere(_ table: String, condition: String) async throws -> Int {
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
        return try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(condition)") ?? 0
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

    // MARK: - Journal prune, snapshot dates, reset leftovers, cancel, disk space

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func insertSnapshotRow(
        trackedPathId: UUID,
        createdAt: Date,
        lifecycle: Snapshot.Lifecycle
    ) async throws -> Int64 {
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
        let trackedPathIdText = trackedPathId.uuidString
        return try await dbPool.write { db -> Int64 in
            try db.execute(
                sql: "INSERT INTO snapshot (trackedPathId, createdAt, lifecycle) VALUES (?, ?, ?)",
                arguments: [trackedPathIdText, createdAt, lifecycle.rawValue]
            )
            return db.lastInsertedRowID
        }
    }

    private func seedJournalBuckets(
        trackedPathId: UUID,
        at dates: [Date],
        unitKey: String = "place|/Users/tester/dev"
    ) async throws {
        for date in dates {
            try await DatabaseManager.shared.upsertGrowthJournalBuckets(
                trackedPathId: trackedPathId,
                bucketStart: date,
                deltas: [.init(category: .developer, subcategory: nil, unitKey: unitKey): 1_000]
            )
        }
    }

    private func journalBucketStarts(trackedPathId: UUID) async throws -> [Date] {
        try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            .map(\.bucketStart)
            .sorted()
    }

    private func pruneFixture() -> (now: Date, cutoff: Date, calendar: Calendar) {
        let calendar = utcCalendar
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        let cutoff = calendar.date(from: DateComponents(year: 2026, month: 5, day: 17))!
        return (now, cutoff, calendar)
    }

    func testPruneKeepsBucketOnExactCutoffAndDropsOlder() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let fixture = self.pruneFixture()
            let justBefore = fixture.cutoff.addingTimeInterval(-1)

            try await self.seedJournalBuckets(
                trackedPathId: trackedPathId,
                at: [justBefore],
                unitKey: "place|/Users/tester/other"
            )
            try await self.seedJournalBuckets(
                trackedPathId: trackedPathId,
                at: [fixture.cutoff, fixture.now]
            )

            await GrowthJournalService.shared.prune(
                retentionDays: GrowthJournalService.historyWindowDays,
                now: fixture.now,
                calendar: fixture.calendar
            )

            let remaining = try await self.journalBucketStarts(trackedPathId: trackedPathId)
            XCTAssertEqual(remaining, [fixture.cutoff, fixture.now])
        }
    }

    func testPruneClampsShortRetentionToHistoryWindow() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let fixture = self.pruneFixture()
            let insideWindow = fixture.now.addingTimeInterval(-10 * 24 * 60 * 60)
            let outsideWindow = fixture.cutoff.addingTimeInterval(-24 * 60 * 60)

            try await self.seedJournalBuckets(
                trackedPathId: trackedPathId,
                at: [outsideWindow, insideWindow]
            )

            await GrowthJournalService.shared.prune(
                retentionDays: 1,
                now: fixture.now,
                calendar: fixture.calendar
            )

            let remaining = try await self.journalBucketStarts(trackedPathId: trackedPathId)
            XCTAssertEqual(remaining, [insideWindow])
        }
    }

    func testPruneWithLongRetentionKeepsBucketsBeyondHistoryWindow() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let fixture = self.pruneFixture()
            let sixtyDaysAgo = fixture.now.addingTimeInterval(-60 * 24 * 60 * 60)
            let ninetyOneDaysAgo = fixture.now.addingTimeInterval(-91 * 24 * 60 * 60)

            try await self.seedJournalBuckets(
                trackedPathId: trackedPathId,
                at: [ninetyOneDaysAgo, sixtyDaysAgo]
            )

            await GrowthJournalService.shared.prune(
                retentionDays: 90,
                now: fixture.now,
                calendar: fixture.calendar
            )

            let remaining = try await self.journalBucketStarts(trackedPathId: trackedPathId)
            XCTAssertEqual(remaining, [sixtyDaysAgo])
        }
    }

    func testOldestCompleteSnapshotDateIgnoresScanningSnapshotsAndOtherPaths() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let otherPathId = UUID()
            let trackedPath = self.makeTrackedPath(trackedPathId)
            let otherPath = self.makeTrackedPath(otherPathId)
            let base = Date(timeIntervalSince1970: 1_800_000_000)

            let noSnapshots = try await GrowthJournalService.shared.oldestCompleteSnapshotDate(
                trackedPaths: [trackedPath]
            )
            XCTAssertNil(noSnapshots)

            _ = try await self.insertSnapshotRow(
                trackedPathId: trackedPathId,
                createdAt: base.addingTimeInterval(-5 * 3_600),
                lifecycle: .scanning
            )
            let onlyScanning = try await GrowthJournalService.shared.oldestCompleteSnapshotDate(
                trackedPaths: [trackedPath]
            )
            XCTAssertNil(onlyScanning)

            _ = try await self.insertSnapshotRow(
                trackedPathId: trackedPathId,
                createdAt: base.addingTimeInterval(-3 * 3_600),
                lifecycle: .complete
            )
            _ = try await self.insertSnapshotRow(
                trackedPathId: trackedPathId,
                createdAt: base.addingTimeInterval(-3_600),
                lifecycle: .complete
            )
            _ = try await self.insertSnapshotRow(
                trackedPathId: otherPathId,
                createdAt: base.addingTimeInterval(-9 * 3_600),
                lifecycle: .complete
            )

            let oldestForPath = try await GrowthJournalService.shared.oldestCompleteSnapshotDate(
                trackedPaths: [trackedPath]
            )
            XCTAssertEqual(
                try XCTUnwrap(oldestForPath).timeIntervalSince1970,
                base.addingTimeInterval(-3 * 3_600).timeIntervalSince1970,
                accuracy: 0.001
            )

            let oldestForBoth = try await GrowthJournalService.shared.oldestCompleteSnapshotDate(
                trackedPaths: [trackedPath, otherPath]
            )
            XCTAssertEqual(
                try XCTUnwrap(oldestForBoth).timeIntervalSince1970,
                base.addingTimeInterval(-9 * 3_600).timeIntervalSince1970,
                accuracy: 0.001
            )

            let noPaths = try await GrowthJournalService.shared.oldestCompleteSnapshotDate(trackedPaths: [])
            XCTAssertNil(noPaths)
        }
    }

    func testDeltasSinceLastSnapshotSumsSignedPerCategoryFromSnapshotDateOnward() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = self.makeTrackedPath(trackedPathId)
            let otherPath = self.makeTrackedPath(UUID())
            let since = Date(timeIntervalSince1970: 1_800_000_000)
            let unitKey = "place|/Users/tester/dev"

            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [
                    .init(category: .developer, subcategory: nil, unitKey: unitKey): 400,
                    .init(category: .downloads, subcategory: nil, unitKey: unitKey): 5
                ],
                at: since.addingTimeInterval(-120)
            )
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .developer, subcategory: nil, unitKey: unitKey): 100],
                at: since
            )
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .developer, subcategory: nil, unitKey: unitKey): -30],
                at: since.addingTimeInterval(60)
            )
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: otherPath,
                deltas: [.init(category: .developer, subcategory: nil, unitKey: unitKey): 999],
                at: since.addingTimeInterval(60)
            )

            let deltas = await GrowthJournalService.shared.deltasSinceLastSnapshot(
                trackedPath: trackedPath,
                since: since
            )

            XCTAssertEqual(deltas, [.developer: 70])
        }
    }

    func testResetBaselineLeavesFreshScanningSnapshotAndCleanupRemovesItOnceStale() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let entries = [ScanResult(path: "/Users/tester/dev/app/a.bin", sizeBytes: 1_000)]

            let complete = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let completeId = try XCTUnwrap(complete.id)
            try await DatabaseManager.shared.addEntries(to: completeId, entries: entries)

            let scanningId = try await self.insertSnapshotRow(
                trackedPathId: trackedPathId,
                createdAt: Date(),
                lifecycle: .scanning
            )
            try await DatabaseManager.shared.addEntries(to: scanningId, entries: entries)

            try await BaselineService.shared.resetBaseline()

            let completeSnapshots = try await DatabaseManager.shared.fetchAllSnapshots()
            XCTAssertTrue(completeSnapshots.isEmpty)
            let hasBaseline = await BaselineService.shared.hasBaseline()
            XCTAssertFalse(hasBaseline)
            let scanningAfterReset = try await self.rowCountWhere("snapshot", condition: "lifecycle = 'scanning'")
            XCTAssertEqual(scanningAfterReset, 1)

            let deletedWhileFresh = try await DatabaseCleanupService.shared.cleanupAbandonedSnapshots()
            XCTAssertEqual(deletedWhileFresh, 0)

            let staleCreatedAt = Date().addingTimeInterval(-(DatabaseCleanupService.abandonedScanGracePeriod + 60))
            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE snapshot SET createdAt = ? WHERE id = ?",
                    arguments: [staleCreatedAt, scanningId]
                )
            }

            let deletedWhenStale = try await DatabaseCleanupService.shared.cleanupAbandonedSnapshots()
            XCTAssertEqual(deletedWhenStale, 1)
            let snapshotRows = try await self.rowCount("snapshot")
            XCTAssertEqual(snapshotRows, 0)
            let leftoverEntries = try await DatabaseManager.shared.fetchEntryCount(for: scanningId)
            XCTAssertEqual(leftoverEntries, 0)
        }
    }

    func testCancelScanWithNoActiveScanDoesNotAffectNextScan() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrCancelIdleScan")
            defer { try? FileManager.default.removeItem(at: tempDirectory) }
            try Data(repeating: 0xAB, count: 4_096).write(to: tempDirectory.appendingPathComponent("blob.bin"))

            await ScanService.shared.cancelScan()

            let snapshot = try await ScanService.shared.scan(
                path: tempDirectory.path,
                trackedPathId: trackedPathId,
                ignoredNames: [],
                progress: nil
            )

            let snapshotId = try XCTUnwrap(snapshot.id)
            let completeSnapshots = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPathId)
            XCTAssertEqual(completeSnapshots.compactMap(\.id), [snapshotId])
            let entryCount = try await DatabaseManager.shared.fetchEntryCount(for: snapshotId)
            XCTAssertGreaterThan(entryCount, 0)
        }
    }

    func testDiskSpaceForExistingFolderReportsFreeWithinTotal() throws {
        let directory = try createTrackedPathDirectory(named: "PrunrDiskSpace")
        defer { try? FileManager.default.removeItem(at: directory) }

        let free = try XCTUnwrap(DiskSpaceService.shared.getFreeSpace(for: directory))
        let total = try XCTUnwrap(DiskSpaceService.shared.getTotalSpace(for: directory))

        XCTAssertGreaterThan(free, 0)
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThanOrEqual(free, total)
        XCTAssertFalse(try XCTUnwrap(DiskSpaceService.shared.getFreeSpaceFormatted(for: directory)).isEmpty)
    }

    func testDiskSpaceForMissingFolderReportsUnknown() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrunrMissing-\(UUID().uuidString)", isDirectory: true)

        XCTAssertNil(DiskSpaceService.shared.getFreeSpace(for: missing))
        XCTAssertNil(DiskSpaceService.shared.getTotalSpace(for: missing))
        XCTAssertNil(DiskSpaceService.shared.getFreeSpaceFormatted(for: missing))
        XCTAssertNil(DiskSpaceService.shared.getSpace(for: missing))
    }
}
