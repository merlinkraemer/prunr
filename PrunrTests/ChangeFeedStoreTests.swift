import XCTest
import GRDB
@testable import Prunr

/// Journal writes keyed by place (unit), the multi-path feed read, the
/// update-day upgrade and the read cost of the change list.
final class ChangeFeedStoreTests: PrunrTestCase {
    private static let mb: Int64 = 1_024 * 1_024
    private static let home = UnitResolver.defaultHome

    private static func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: floor(date.timeIntervalSinceReferenceDate / 60) * 60)
    }

    /// Whole-second "now", so dates round-trip through SQLite exactly.
    private static func wholeSecondNow() -> Date {
        Date(timeIntervalSinceReferenceDate: floor(Date().timeIntervalSinceReferenceDate))
    }

    private func journalBuckets(_ trackedPathId: UUID) async throws -> [GrowthJournalBucket] {
        try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
    }

    // MARK: - Write paths

    /// A watcher refresh of a new file writes exactly one bucket, keyed by the
    /// file's unit.
    func testWatcherRefreshWritesOneUnitKeyedBucketForNewFile() async throws {
        try await withTemporaryDatabase { [self] trackedPathId, snapshotId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrUnitWatch")
            defer { try? FileManager.default.removeItem(at: tempDirectory) }

            let existing = tempDirectory.appendingPathComponent("existing.txt")
            try Data(repeating: 0x01, count: 128).write(to: existing)
            try await DatabaseManager.shared.addEntries(
                to: snapshotId,
                entries: [ScanResult(path: existing.path, sizeBytes: 128)]
            )
            try await DatabaseManager.shared.rebuildWorkingSet(from: snapshotId, trackedPathId: trackedPathId)

            let newFile = tempDirectory.appendingPathComponent("new.iso")
            try Data(repeating: 0x02, count: 64 * 1_024).write(to: newFile)

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")
            let result = await RecentChangeService.shared.refreshChangedPaths([newFile], trackedPath: trackedPath)
            guard case .updated(let deltas) = result else {
                XCTFail("a new file should update incrementally")
                return
            }

            let expectedUnit = UnitResolver.resolve(path: newFile.path)
            XCTAssertFalse(expectedUnit.isEmpty)
            XCTAssertEqual(Set(deltas.keys.map(\.unitKey)), [expectedUnit])

            let buckets = try await self.journalBuckets(trackedPathId)
            XCTAssertEqual(buckets.count, 1)
            XCTAssertEqual(buckets.first?.unitKey, expectedUnit)
            XCTAssertEqual(buckets.first?.source, .watch)
            XCTAssertEqual(buckets.first?.deltaBytes, try self.diskUsageBytes(at: newFile))
        }
    }

    /// The watcher's single-file path for a new item under ~/Downloads writes one
    /// "download" bucket, and the feed lists it under today. No file is created
    /// in the real Downloads folder: the working set is fed a synthetic entry.
    func testNewDownloadIsRecordedAndListedUnderToday() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let homeURL = URL(fileURLWithPath: Self.home, isDirectory: true)
            let trackedPath = TrackedPath(id: trackedPathId, url: homeURL, displayName: "Home")
            let name = "prunr-fixture-\(UUID().uuidString.prefix(8)).iso"
            let path = homeURL.appendingPathComponent("Downloads/\(name)").path
            let size = 2_048 * Self.mb
            let now = Date()

            let deltas = try await DatabaseManager.shared.replaceWorkingSetFile(
                trackedPathId: trackedPathId,
                entry: ScanResult(path: path, sizeBytes: size),
                updatedAt: now
            )
            try await GrowthJournalService.shared.recordDeltas(trackedPath: trackedPath, deltas: deltas, at: now)

            let expectedUnit = "download|\(path)"
            let buckets = try await self.journalBuckets(trackedPathId)
            XCTAssertEqual(buckets.count, 1)
            XCTAssertEqual(buckets.first?.unitKey, expectedUnit)
            XCTAssertEqual(buckets.first?.category, GrowthCategory.downloads.rawValue)

            let feed = try await GrowthJournalService.shared.changeFeed(trackedPaths: [trackedPath], now: now)
            let day = try XCTUnwrap(feed.days.first)
            XCTAssertEqual(EpisodeBuilder.dayLabel(for: day.day, now: now, calendar: .current), "Today")
            let episode = try XCTUnwrap(day.episodes.first)
            XCTAssertEqual(episode.title, "Downloads · \(name)")
            XCTAssertEqual(episode.netBytes, size)
            XCTAssertEqual(episode.rootPath, path)
            XCTAssertEqual(episode.time, Self.floorToMinute(now))
        }
    }

    /// Subtree refreshes group their deltas by `prunr_unit(path)` in SQL, so the
    /// function must be registered on the pool's connections.
    func testSubtreeRefreshGroupsDeltasByUnitInSQL() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let downloads = URL(fileURLWithPath: Self.home, isDirectory: true).appendingPathComponent("Downloads")
            let tag = UUID().uuidString.prefix(8)
            let folder = downloads.appendingPathComponent("prunr-fixture-\(tag)").path
            let single = downloads.appendingPathComponent("prunr-fixture-\(tag).iso").path

            let deltas = try await DatabaseManager.shared.replaceWorkingSetSubtree(
                trackedPathId: trackedPathId,
                rootPath: downloads.path,
                entries: [
                    ScanResult(path: "\(folder)/a.bin", sizeBytes: 100),
                    ScanResult(path: "\(folder)/nested/b.bin", sizeBytes: 200),
                    ScanResult(path: single, sizeBytes: 50)
                ]
            )

            var byUnit: [String: Int64] = [:]
            for (key, bytes) in deltas {
                byUnit[key.unitKey, default: 0] += bytes
            }
            XCTAssertEqual(byUnit, [
                "download|\(folder)": 300,
                "download|\(single)": 50
            ])
            XCTAssertEqual(UnitResolver.resolve(path: "\(folder)/nested/b.bin"), "download|\(folder)")
        }
    }

    // MARK: - Feed read

    func testFeedMergesTheSameUnitAcrossTrackedPaths() async throws {
        try await withEmptyTemporaryDatabase { firstId in
            let secondId = UUID()
            let first = TrackedPath(id: firstId, url: URL(fileURLWithPath: "/Volumes/A"), displayName: "A")
            let second = TrackedPath(id: secondId, url: URL(fileURLWithPath: "/Volumes/B"), displayName: "B")
            let unit = "place|/Users/tester/dev"
            let key = DatabaseManager.JournalDeltaKey(category: .developer, subcategory: nil, unitKey: unit)
            let now = Date()

            try await GrowthJournalService.shared.recordDeltas(trackedPath: first, deltas: [key: 300 * Self.mb], at: now)
            try await GrowthJournalService.shared.recordDeltas(trackedPath: second, deltas: [key: 200 * Self.mb], at: now)

            let slots = try await DatabaseManager.shared.fetchJournalSlots(
                trackedPathIds: [firstId, secondId],
                since: now.addingTimeInterval(-3_600)
            )
            XCTAssertEqual(slots.count, 1, "SQL pre-aggregation merges both paths into one slot")
            XCTAssertEqual(slots.first?.netBytes, 500 * Self.mb)
            XCTAssertEqual(slots.first?.grossBytes, 500 * Self.mb)

            let feed = try await GrowthJournalService.shared.changeFeed(trackedPaths: [first, second], now: now)
            XCTAssertEqual(feed.days.flatMap(\.episodes).map(\.netBytes), [500 * Self.mb])

            let onlyFirst = try await GrowthJournalService.shared.changeFeed(trackedPaths: [first], now: now)
            XCTAssertEqual(onlyFirst.days.flatMap(\.episodes).map(\.netBytes), [300 * Self.mb])
        }
    }

    func testSlotsCarryNetGrossAndEarliestMinute() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = TrackedPath(id: trackedPathId, url: URL(fileURLWithPath: "/Volumes/A"), displayName: "A")
            let key = DatabaseManager.JournalDeltaKey(category: .developer, subcategory: nil, unitKey: "place|/Users/tester/dev")
            // 10:05 and 10:20 share the 10:00 slot; 10:31 starts the next one.
            let base = Date(timeIntervalSince1970: TimeInterval(1_791_000_000 / 1_800 * 1_800))
            try await GrowthJournalService.shared.recordDeltas(trackedPath: trackedPath, deltas: [key: 4 * Self.mb], at: base.addingTimeInterval(5 * 60))
            try await GrowthJournalService.shared.recordDeltas(trackedPath: trackedPath, deltas: [key: -1 * Self.mb], at: base.addingTimeInterval(20 * 60))
            try await GrowthJournalService.shared.recordDeltas(trackedPath: trackedPath, deltas: [key: 2 * Self.mb], at: base.addingTimeInterval(31 * 60))

            let slots = try await DatabaseManager.shared.fetchJournalSlots(trackedPathIds: [trackedPathId], since: base)
                .sorted { $0.slot < $1.slot }
            XCTAssertEqual(slots.map(\.netBytes), [3 * Self.mb, 2 * Self.mb])
            XCTAssertEqual(slots.map(\.grossBytes), [5 * Self.mb, 2 * Self.mb])
            XCTAssertEqual(slots.map(\.firstAt), [base.addingTimeInterval(5 * 60), base.addingTimeInterval(31 * 60)])
            XCTAssertEqual(slots[1].slot - slots[0].slot, 1)
        }
    }

    // MARK: - This week: header, list and categories agree

    /// The header number equals the sum of this week's slots and the sum of
    /// the categories view's "this week" deltas, across several categories and
    /// two tracked paths, with growth, shrink, a legacy row and an old spike
    /// outside the week.
    func testHeaderEqualsWeekSlotsAndCategoryDeltas() async throws {
        try await withEmptyTemporaryDatabase { firstId in
            let secondId = UUID()
            let first = TrackedPath(id: firstId, url: URL(fileURLWithPath: "/Volumes/A"), displayName: "A")
            let second = TrackedPath(id: secondId, url: URL(fileURLWithPath: "/Volumes/B"), displayName: "B")
            let now = Self.wholeSecondNow()
            let day: TimeInterval = 24 * 60 * 60
            let gb = 1_024 * Self.mb
            let journal = GrowthJournalService.shared

            func key(_ category: GrowthCategory, _ unit: String) -> DatabaseManager.JournalDeltaKey {
                DatabaseManager.JournalDeltaKey(category: category, subcategory: nil, unitKey: unit)
            }

            try await journal.recordDeltas(trackedPath: first, deltas: [key(.developer, "place|/Users/tester/dev/acme"): 3 * gb], at: now.addingTimeInterval(-3_600))
            try await journal.recordDeltas(trackedPath: first, deltas: [key(.downloads, "download|/Users/tester/Downloads/a.iso"): 2 * gb], at: now.addingTimeInterval(-2 * day))
            try await journal.recordDeltas(trackedPath: first, deltas: [key(.cachesAndSystem, ""): -1 * gb], at: now.addingTimeInterval(-3 * day))
            try await journal.recordDeltas(trackedPath: second, deltas: [key(.mediaAndDocuments, "place|/Users/tester/Documents/Archive"): 500 * Self.mb], at: now.addingTimeInterval(-4 * day))
            try await journal.recordDeltas(trackedPath: second, deltas: [key(.developer, "place|/Users/tester/dev/acme"): -700 * Self.mb], at: now.addingTimeInterval(-2 * 3_600))
            // Outside the week: counted by nobody.
            try await journal.recordDeltas(trackedPath: second, deltas: [key(.developer, "place|/Users/tester/dev/old"): 9 * gb], at: now.addingTimeInterval(-9 * day))

            let expected = 3 * gb + 2 * gb - 1 * gb + 500 * Self.mb - 700 * Self.mb

            let feed = try await journal.changeFeed(trackedPaths: [first, second], now: now)
            let header = WeeklyChange(.loaded(feed), now: now)
            XCTAssertEqual(header, .bytes(expected))

            let slots = try await DatabaseManager.shared.fetchJournalSlots(
                trackedPathIds: [firstId, secondId],
                since: GrowthJournalService.weekStart(now: now)
            )
            XCTAssertEqual(slots.reduce(Int64(0)) { $0 + $1.netBytes }, expected)

            var categoryTotal: Int64 = 0
            for trackedPath in [first, second] {
                let stories = await journal.recentGrowthStories(trackedPath: trackedPath, now: now)
                categoryTotal += stories.values.reduce(Int64(0)) { $0 + $1.deltaBytes }
            }
            XCTAssertEqual(categoryTotal, expected)
        }
    }

    /// A subcategory that shrank keeps its negative total, so the drill adds
    /// up to its category row.
    func testSubcategoryTotalsKeepNegativeValues() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = TrackedPath(id: trackedPathId, url: URL(fileURLWithPath: "/Volumes/A"), displayName: "A")
            let now = Self.wholeSecondNow()
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [
                    .init(category: .developer, subcategory: .docker): 400 * Self.mb,
                    .init(category: .developer, subcategory: .nodeModules): -900 * Self.mb
                ],
                at: now.addingTimeInterval(-3_600)
            )

            let totals = try await DatabaseManager.shared.fetchGrowthJournalTotalsBySubcategory(
                trackedPathId: trackedPathId,
                category: .developer,
                since: GrowthJournalService.weekStart(now: now)
            )
            XCTAssertEqual(totals[.docker], 400 * Self.mb)
            XCTAssertEqual(totals[.nodeModules], -900 * Self.mb)

            let serviceTotals = await GrowthJournalService.shared.subcategoryGrowthTotals(
                trackedPath: trackedPath,
                category: .developer,
                now: now
            )
            XCTAssertEqual(serviceTotals.values.reduce(0, +), -500 * Self.mb)
        }
    }

    // MARK: - Upgrade day

    /// v20 data (buckets without a unit), then a scan after the migration: the
    /// residual is computed and written at category grain, so the update day
    /// shows no unit-keyed "found" rows.
    func testUpgradeFromV20ProducesOnlyCoarseResiduals() async throws {
        // Separate folders: the database folder counts as Prunr-internal and is
        // never scanned.
        let directory = try createTrackedPathDirectory(named: "PrunrUpgradeV20DB")
        let trackedURL = try createTrackedPathDirectory(named: "PrunrUpgradeV20Tracked")
        defer {
            try? DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: trackedURL)
        }

        let file = trackedURL.appendingPathComponent("blob.bin")
        let initialBytes = 4_096
        try Data(repeating: 0xAB, count: initialBytes).write(to: file)
        let sizeBefore = try diskUsageBytes(at: file)

        let trackedPathId = UUID()
        let dbPath = directory.appendingPathComponent("prunr.sqlite").path
        let windowStart = Self.wholeSecondNow().addingTimeInterval(-7_200)
        let watchAt = Self.floorToMinute(Date().addingTimeInterval(-3_600))
        let watchBytes = 10 * Self.mb
        let (category, subcategory) = GrowthCategory.classify(path: file.path)

        do {
            let queue = try DatabaseQueue(path: dbPath)
            try DatabaseManager.makeMigrator().migrate(queue, upTo: "v20_add_snapshot_lifecycle")
            let filePath = file.path
            try await queue.write { db in
                try db.execute(
                    sql: "INSERT INTO snapshot (createdAt, trackedPathId, lifecycle) VALUES (?, ?, 'complete')",
                    arguments: [windowStart, trackedPathId.uuidString]
                )
                let snapshotId = db.lastInsertedRowID
                try db.execute(sql: "INSERT INTO paths (path) VALUES (?)", arguments: [filePath])
                let pathId = db.lastInsertedRowID
                try db.execute(
                    sql: "INSERT INTO snapshotEntry (snapshotId, pathId, sizeBytes) VALUES (?, ?, ?)",
                    arguments: [snapshotId, pathId, sizeBefore]
                )
                try db.execute(
                    sql: """
                        INSERT INTO growthJournalBucket (trackedPathId, bucketStart, category, subcategory, deltaBytes)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [trackedPathId.uuidString, watchAt, category.rawValue, subcategory?.rawValue ?? "", watchBytes]
                )
            }
            try queue.close()
        }

        try DatabaseManager.shared.initialize(at: dbPath)

        try Data(repeating: 0xAB, count: initialBytes + Int(12 * Self.mb)).write(to: file)
        let authoritative = try diskUsageBytes(at: file) - sizeBefore

        let trackedPath = TrackedPath(id: trackedPathId, url: trackedURL, displayName: "Tracked")
        _ = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)

        let buckets = try await journalBuckets(trackedPathId)
        let legacy = buckets.filter { $0.source == .watch }
        let scan = buckets.filter { $0.source == .scan }

        XCTAssertEqual(legacy.map(\.unitKey), [""], "migrated rows keep an empty unit")
        XCTAssertEqual(legacy.map(\.deltaBytes), [watchBytes])
        XCTAssertFalse(scan.isEmpty)
        XCTAssertTrue(scan.allSatisfy { $0.unitKey.isEmpty }, "update-day residuals stay coarse")
        XCTAssertEqual(scan.reduce(Int64(0)) { $0 + $1.deltaBytes }, authoritative - watchBytes)
        XCTAssertEqual(buckets.reduce(Int64(0)) { $0 + $1.deltaBytes }, authoritative)

        let feed = try await GrowthJournalService.shared.changeFeed(trackedPaths: [trackedPath])
        let episodes = feed.episodes
        XCTAssertFalse(episodes.isEmpty)
        XCTAssertTrue(episodes.allSatisfy { $0.rootPath == nil }, "no unit-keyed rows on the update day")
    }

    /// Rows written before v22 read back with an empty unit, and the identity
    /// index lets the same minute and category hold one row per unit.
    func testJournalUnitMigrationKeepsOldRowsAtCategoryGrain() throws {
        let directory = try createTrackedPathDirectory(named: "PrunrMigrationV22")
        defer { try? FileManager.default.removeItem(at: directory) }

        let queue = try DatabaseQueue(path: directory.appendingPathComponent("prunr.sqlite").path)
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(queue, upTo: "v21_journal_source")

        let trackedPathId = UUID().uuidString
        let bucketStart = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO growthJournalBucket (trackedPathId, bucketStart, category, subcategory, deltaBytes)
                    VALUES (?, ?, 'downloads', '', 1000)
                    """,
                arguments: [trackedPathId, bucketStart]
            )
        }

        try migrator.migrate(queue)

        try queue.write { db in
            let buckets = try GrowthJournalBucket.fetchAll(db, sql: "SELECT * FROM growthJournalBucket")
            XCTAssertEqual(buckets.map(\.unitKey), [""])

            try db.execute(
                sql: """
                    INSERT INTO growthJournalBucket (trackedPathId, bucketStart, category, subcategory, deltaBytes, unitKey)
                    VALUES (?, ?, 'downloads', '', 5, 'download|/Users/tester/Downloads/a.iso')
                    """,
                arguments: [trackedPathId, bucketStart]
            )
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalBucket"), 2)
        }
        try queue.close()
    }

    // MARK: - Cost

    /// SQL read plus build over 200k buckets in the window. The number is
    /// reported, not asserted (look for "CHANGE_FEED_MEASURE" in the test log).
    func testMeasureFeedReadAndBuildOn200kBuckets() throws {
        let directory = try createTrackedPathDirectory(named: "PrunrFeedMeasure")
        defer {
            try? DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: directory)
        }
        try DatabaseManager.shared.initialize(at: directory.appendingPathComponent("prunr.sqlite").path)
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)

        let trackedPathIds = [UUID(), UUID()]
        let now = Date()
        let calendar = Calendar.current
        let since = EpisodeBuilder.windowStart(now: now, calendar: calendar)
        let unitCount = 2_000
        let bucketsPerUnit = 100
        let windowMinutes = max(1, Int(now.timeIntervalSince(since) / 60) - 1)

        try dbPool.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO growthJournalBucket
                    (trackedPathId, bucketStart, category, subcategory, deltaBytes, source, unitKey)
                VALUES (?, ?, ?, '', ?, 'watch', ?)
                """)
            for unit in 0..<unitCount {
                let unitKey = "place|/Users/tester/projects/p\(unit)"
                let trackedPathId = trackedPathIds[unit % trackedPathIds.count].uuidString
                for index in 0..<bucketsPerUnit {
                    // Spread each unit's minutes across the week, distinct per unit.
                    let minute = (unit * 7 + index * (windowMinutes / bucketsPerUnit)) % windowMinutes
                    let bucketStart = since.addingTimeInterval(TimeInterval(minute * 60))
                    let delta = Int64((index % 3 == 0 ? -1 : 1) * (1_000 + unit + index) * 1_024)
                    try statement.execute(arguments: [trackedPathId, bucketStart, "developer", delta, unitKey])
                }
            }
        }
        let bucketCount = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalBucket") ?? 0
        }
        XCTAssertEqual(bucketCount, unitCount * bucketsPerUnit)

        func readAndBuild() throws -> (slots: Int, rows: Int) {
            let slots = try dbPool.read { db in
                try DatabaseManager.fetchJournalSlots(db: db, trackedPathIds: trackedPathIds, since: since)
            }
            let feed = EpisodeBuilder.build(slots: slots, now: now, calendar: calendar)
            return (slots.count, feed.episodes.count)
        }

        // First run, timed per phase: the SQL read, then the pure build.
        let readStarted = Date()
        let slots = try dbPool.read { db in
            try DatabaseManager.fetchJournalSlots(db: db, trackedPathIds: trackedPathIds, since: since)
        }
        let buildStarted = Date()
        let feed = EpisodeBuilder.build(slots: slots, now: now, calendar: calendar)
        let finished = Date()
        func ms(_ from: Date, _ to: Date) -> String { String(format: "%.1f", to.timeIntervalSince(from) * 1_000) }
        let line = "CHANGE_FEED_MEASURE window_days=\(GrowthJournalService.historyWindowDays) buckets=\(bucketCount) slots=\(slots.count) rows=\(feed.episodes.count) sql_ms=\(ms(readStarted, buildStarted)) build_ms=\(ms(buildStarted, finished)) first_run_ms=\(ms(readStarted, finished))"
        // Both streams, so the line reaches the xcodebuild log whichever one
        // the runner keeps.
        print(line)
        NSLog("%@", line)
        XCTAssertGreaterThan(feed.episodes.count, 0)

        measure {
            _ = try? readAndBuild()
        }
    }
}
