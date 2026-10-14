import XCTest
import GRDB
@testable import Prunr

/// Day-one history rebuilt from file dates: which files count, how they are
/// bucketed, and what the change list makes of them.
final class FileDateHistoryTests: PrunrTestCase {
    private static let home = "/Users/tester"
    private static let gb: Int64 = 1_000_000_000
    private static let mb: Int64 = 1_000_000
    private static let hour: TimeInterval = 60 * 60
    private static let day: TimeInterval = 24 * hour

    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func written(at birth: Date, modifiedAfter: TimeInterval = 5 * 60) -> FileDates {
        FileDates(birth: birth.timeIntervalSince1970, modified: birth.timeIntervalSince1970 + modifiedAfter)
    }

    private func add(
        _ history: inout FileDateHistory,
        _ path: String,
        _ bytes: Int64,
        _ dates: FileDates
    ) {
        let (category, subcategory) = GrowthCategory.classify(path: path)
        history.add(path: path, sizeBytes: bytes, category: category, subcategory: subcategory, dates: dates, home: Self.home)
    }

    /// The journal slots the feed would read back, grouped like
    /// `DatabaseManager.fetchJournalSlots`.
    private func slots(_ history: FileDateHistory) -> [JournalSlot] {
        history.deltasByBucketStart.flatMap { bucketStart, deltas in
            deltas.map { key, bytes in
                JournalSlot(
                    unitKey: key.unitKey,
                    category: key.category.rawValue,
                    subcategory: key.subcategory?.rawValue ?? "",
                    source: .files,
                    slot: Int64(bucketStart.timeIntervalSince1970) / JournalSlot.slotSeconds,
                    netBytes: bytes,
                    grossBytes: abs(bytes),
                    firstAt: bucketStart,
                    observedSince: nil
                )
            }
        }
    }

    private func total(_ history: FileDateHistory) -> Int64 {
        history.deltasByBucketStart.values.flatMap(\.values).reduce(0, +)
    }

    // MARK: - Which files count

    func testWrittenOnceFileInTheWindowCountsAtItsBirthSlot() throws {
        let calendar = utc()
        let scanStart = date(10, 12, 16, 38, in: calendar)
        var history = FileDateHistory(scanStart: scanStart, calendar: calendar)
        let birth = date(10, 9, 14, 47, in: calendar)

        add(&history, "/Users/tester/Downloads/ubuntu.iso", 3 * Self.gb, written(at: birth))

        let buckets = history.deltasByBucketStart
        XCTAssertEqual(Array(buckets.keys), [date(10, 9, 14, 30, in: calendar)])
        let deltas = try XCTUnwrap(buckets.values.first)
        XCTAssertEqual(deltas.count, 1)
        let key = try XCTUnwrap(deltas.keys.first)
        XCTAssertEqual(key.category, .downloads)
        XCTAssertEqual(key.unitKey, UnitResolver.resolve(path: "/Users/tester/Downloads/ubuntu.iso", home: Self.home))
        XCTAssertEqual(deltas[key], 3 * Self.gb)
        XCTAssertEqual(history.fileCount, 1)
    }

    func testFilesChangedAfterCreationAreSkipped() {
        let calendar = utc()
        let scanStart = date(10, 12, 16, 38, in: calendar)
        var history = FileDateHistory(scanStart: scanStart, calendar: calendar)
        let birth = date(10, 5, 10, 0, in: calendar)

        add(&history, "/Users/tester/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", 40 * Self.gb,
            written(at: birth, modifiedAfter: 6 * Self.day))
        add(&history, "/Users/tester/dev/acme/db.sqlite", 2 * Self.gb, written(at: birth, modifiedAfter: Self.hour + 1))
        add(&history, "/Users/tester/Downloads/a.zip", 1 * Self.gb, written(at: birth, modifiedAfter: Self.hour))
        add(&history, "/Users/tester/Downloads/b.zip", 2 * Self.gb, written(at: birth, modifiedAfter: -Self.day))

        XCTAssertEqual(history.fileCount, 2, "written within an hour of birth, or last written before it")
        XCTAssertEqual(total(history), 3 * Self.gb)
    }

    func testFilesOutsideTheWindowAreSkipped() {
        let calendar = utc()
        let scanStart = date(10, 12, 16, 38, in: calendar)
        var history = FileDateHistory(scanStart: scanStart, calendar: calendar)
        XCTAssertEqual(history.windowStart, date(9, 13, 0, 0, in: calendar))
        XCTAssertEqual(history.windowStart, GrowthJournalService.historyStart(now: scanStart, calendar: calendar))

        add(&history, "/Users/tester/Downloads/old.iso", 5 * Self.gb, written(at: date(9, 12, 23, 59, in: calendar)))
        add(&history, "/Users/tester/Downloads/first.iso", 1 * Self.gb, written(at: date(9, 13, 0, 0, in: calendar)))
        add(&history, "/Users/tester/Downloads/during-scan.iso", 7 * Self.gb, written(at: scanStart))
        add(&history, "/Users/tester/Downloads/later.iso", 9 * Self.gb, written(at: scanStart.addingTimeInterval(60)))

        XCTAssertEqual(history.fileCount, 1)
        XCTAssertEqual(total(history), 1 * Self.gb)
        XCTAssertTrue(history.deltasByBucketStart.keys.allSatisfy { $0 >= history.windowStart && $0 < scanStart })
    }

    func testTrashAndEmptyFilesAreSkipped() {
        let calendar = utc()
        let scanStart = date(10, 12, 16, 38, in: calendar)
        var history = FileDateHistory(scanStart: scanStart, calendar: calendar)
        let birth = date(10, 10, 9, 0, in: calendar)

        add(&history, "/Users/tester/.Trash/old.iso", 4 * Self.gb, written(at: birth))
        add(&history, "/Users/tester/Downloads/empty.txt", 0, written(at: birth))

        XCTAssertTrue(history.isEmpty)
    }

    /// Bucket starts never fall before the window, also where local midnight
    /// is not on a 30-minute boundary.
    func testBucketsStayInsideTheWindowOffTheHalfHour() throws {
        var kathmandu = Calendar(identifier: .gregorian)
        kathmandu.timeZone = TimeZone(identifier: "Asia/Kathmandu")!
        let scanStart = kathmandu.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 16, minute: 38))!
        var history = FileDateHistory(scanStart: scanStart, calendar: kathmandu)

        add(&history, "/Users/tester/Downloads/a.iso", 1 * Self.gb, written(at: history.windowStart.addingTimeInterval(60)))

        XCTAssertEqual(Array(history.deltasByBucketStart.keys), [history.windowStart])
    }

    // MARK: - Aggregation

    func testAggregatesPerPlaceAndSlot() throws {
        let calendar = utc()
        let scanStart = date(10, 12, 16, 38, in: calendar)
        var history = FileDateHistory(scanStart: scanStart, calendar: calendar)

        for minute in [0, 10, 20] {
            add(&history, "/Users/tester/Documents/Archive/scan \(minute).pdf", 400 * Self.mb, written(at: date(10, 9, 20, minute, in: calendar)))
        }
        add(&history, "/Users/tester/Downloads/a.iso", 2 * Self.gb, written(at: date(10, 9, 20, 5, in: calendar)))
        add(&history, "/Users/tester/Downloads/a.iso", 1 * Self.gb, written(at: date(10, 10, 8, 0, in: calendar)))

        let buckets = history.deltasByBucketStart
        XCTAssertEqual(Set(buckets.keys), [date(10, 9, 20, 0, in: calendar), date(10, 10, 8, 0, in: calendar)])
        let evening = try XCTUnwrap(buckets[date(10, 9, 20, 0, in: calendar)])
        XCTAssertEqual(evening.count, 2, "one entry per place in the slot")
        XCTAssertEqual(evening.values.sorted(), [1_200 * Self.mb, 2 * Self.gb])
        XCTAssertEqual(history.bucketCount, 2)
        XCTAssertEqual(history.totalBytes, 4_200 * Self.mb)

        let feed = EpisodeBuilder.build(slots: slots(history), now: scanStart, calendar: calendar, home: Self.home)
        XCTAssertEqual(feed.days.map(\.day), [date(10, 10, 0, 0, in: calendar), date(10, 9, 0, 0, in: calendar)])
        XCTAssertEqual(feed.days.last?.episodes.map(\.netBytes).sorted(), [1_200 * Self.mb, 2 * Self.gb])
    }

    // MARK: - The change list on day one

    func testDayOneWithFileHistoryShowsRowsAndTheHeaderEqualsThem() throws {
        let calendar = utc()
        let scanStart = date(10, 12, 16, 38, in: calendar)
        let now = scanStart.addingTimeInterval(10 * 60)
        var history = FileDateHistory(scanStart: scanStart, calendar: calendar)

        add(&history, "/Users/tester/Downloads/a.iso", 5_100 * Self.mb, written(at: date(10, 11, 18, 0, in: calendar)))
        add(&history, "/Users/tester/Music/Projects/Live Set.wav", 3_200 * Self.mb, written(at: date(10, 9, 21, 0, in: calendar)))
        add(&history, "/Users/tester/Pictures/Export/trip.mov", 7_200 * Self.mb, written(at: date(10, 1, 12, 0, in: calendar)))

        let feed = EpisodeBuilder.build(
            slots: slots(history), now: now, calendar: calendar, home: Self.home, watchingSince: scanStart
        )

        XCTAssertTrue(feed.hasFileHistory)
        XCTAssertFalse(feed.isDayOne(now: now), "rebuilt rows replace the day-one sentence")
        XCTAssertEqual(feed.episodes.count, 3)

        let weekStart = GrowthJournalService.weekStart(now: now, calendar: calendar)
        let weekRows = feed.episodes.filter { $0.day >= weekStart }.reduce(Int64(0)) { $0 + $1.netBytes }
        XCTAssertEqual(feed.weekNetBytes, 8_300 * Self.mb)
        XCTAssertEqual(feed.weekNetBytes, weekRows, "the header equals the rows")
        XCTAssertEqual(WeeklyChange(.loaded(feed), now: now), .bytes(8_300 * Self.mb))

        XCTAssertFalse(feed.isShortHistory(now: now, calendar: calendar), "no \"Watching since\" under rebuilt rows")
        XCTAssertNil(feed.quietSince(now: now, calendar: calendar))
        XCTAssertEqual(feed.watchingSinceToday(now: now, calendar: calendar), scanStart)
    }

    func testDayOneSentenceOnlyWhenNothingWasRebuilt() {
        let calendar = utc()
        let scanStart = date(10, 12, 16, 38, in: calendar)
        let now = scanStart.addingTimeInterval(10 * 60)

        let nothing = EpisodeBuilder.build(slots: [], now: now, calendar: calendar, home: Self.home, watchingSince: scanStart)
        XCTAssertTrue(nothing.isDayOne(now: now))
        XCTAssertEqual(WeeklyChange(.loaded(nothing), now: now), .unknown)

        var history = FileDateHistory(scanStart: scanStart, calendar: calendar)
        add(&history, "/Users/tester/Downloads/small.zip", 300 * Self.mb, written(at: date(10, 10, 9, 0, in: calendar)))
        let small = EpisodeBuilder.build(
            slots: slots(history), now: now, calendar: calendar, home: Self.home, watchingSince: scanStart
        )
        XCTAssertFalse(small.hasRows)
        XCTAssertFalse(small.isDayOne(now: now))
        XCTAssertEqual(WeeklyChange(.loaded(small), now: now), .bytes(300 * Self.mb))
        XCTAssertEqual(
            small.quietSince(now: now, calendar: calendar),
            GrowthJournalService.historyStart(now: now, calendar: calendar),
            "quiet since the start of the rebuilt history, not since today"
        )
    }

    func testWatchingSinceTodayEndsWithTheFirstLiveChangeOrTheNextDay() {
        let calendar = utc()
        let scanStart = date(10, 12, 16, 38, in: calendar)
        let now = scanStart.addingTimeInterval(30 * 60)
        let live = JournalSlot(
            unitKey: "download|/Users/tester/Downloads/b.zip", category: "downloads", subcategory: "",
            source: .watch, slot: Int64(now.timeIntervalSince1970) / JournalSlot.slotSeconds,
            netBytes: 10 * Self.mb, grossBytes: 10 * Self.mb, firstAt: now.addingTimeInterval(-60), observedSince: nil
        )

        let quiet = EpisodeBuilder.build(slots: [], now: now, calendar: calendar, home: Self.home, watchingSince: scanStart)
        XCTAssertEqual(quiet.watchingSinceToday(now: now, calendar: calendar), scanStart)

        let changed = EpisodeBuilder.build(slots: [live], now: now, calendar: calendar, home: Self.home, watchingSince: scanStart)
        XCTAssertEqual(changed.lastLiveChangeAt, live.firstAt)
        XCTAssertNil(changed.watchingSinceToday(now: now, calendar: calendar))

        let nextDay = date(10, 13, 0, 5, in: calendar)
        XCTAssertNil(quiet.watchingSinceToday(now: nextDay, calendar: calendar))
    }

    // MARK: - First full scan

    private func writeFile(_ url: URL, bytes: Int, birth: Date, modified: Date) throws {
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        try setFileDates(url, birth: birth, modified: modified)
    }

    private func slotStart(_ date: Date) -> Date {
        let seconds = TimeInterval(JournalSlot.slotSeconds)
        return Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / seconds) * seconds)
    }

    /// The first full scan writes the rebuilt history; a later full scan adds
    /// nothing to it, and its residual counts only what is new since the
    /// first snapshot.
    func testFirstBaselineRebuildsHistoryAndLaterScansDoNotCountItAgain() async throws {
        try await withEmptyTemporaryDatabase { [self] trackedPathId in
            let root = try createTrackedPathDirectory(named: "PrunrFileHistory")
            defer { try? FileManager.default.removeItem(at: root) }
            let now = Date()

            let recent = root.appendingPathComponent("recent.bin")
            let recentBirth = now.addingTimeInterval(-3 * Self.day)
            try writeFile(recent, bytes: 2_000_000, birth: recentBirth, modified: recentBirth.addingTimeInterval(120))
            let grown = root.appendingPathComponent("grown.bin")
            try writeFile(grown, bytes: 1_000_000, birth: now.addingTimeInterval(-10 * Self.day), modified: now.addingTimeInterval(-2 * Self.day))
            let ancient = root.appendingPathComponent("ancient.bin")
            let ancientBirth = now.addingTimeInterval(-45 * Self.day)
            try writeFile(ancient, bytes: 1_000_000, birth: ancientBirth, modified: ancientBirth.addingTimeInterval(60))

            let trackedPath = TrackedPath(id: trackedPathId, url: root, displayName: "Temp")
            let s0 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)

            let first = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            let recentBytes = try diskUsageBytes(at: recent)
            XCTAssertTrue(first.allSatisfy { $0.source == .files })
            XCTAssertEqual(first.reduce(Int64(0)) { $0 + $1.deltaBytes }, recentBytes, "only the written-once file in the window")
            XCTAssertEqual(first.map(\.bucketStart), [slotStart(recentBirth)])
            XCTAssertEqual(first.first?.unitKey, UnitResolver.resolve(path: DatabaseManager.normalizePath(recent.path)))
            XCTAssertTrue(first.allSatisfy { $0.bucketStart < s0.createdAt }, "dated before the first snapshot's window")

            let feed = try await GrowthJournalService.shared.changeFeed(trackedPaths: [trackedPath], watchingSince: s0.createdAt)
            XCTAssertTrue(feed.hasFileHistory)
            XCTAssertFalse(feed.isDayOne(now: Date()))
            XCTAssertEqual(feed.weekNetBytes, recentBytes, "This week includes the rebuilt history")

            let added = root.appendingPathComponent("added.bin")
            let addedBirth = now.addingTimeInterval(-2 * Self.day)
            try writeFile(added, bytes: 3_000_000, birth: addedBirth, modified: addedBirth.addingTimeInterval(60))
            let addedBytes = try diskUsageBytes(at: added)

            let s1 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            let second = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            XCTAssertEqual(second.filter { $0.source == .files }, first, "a later full scan never rebuilds")
            let scan = second.filter { $0.source == .scan }
            XCTAssertEqual(scan.reduce(Int64(0)) { $0 + $1.deltaBytes }, addedBytes, "the residual counts only the new file")
            XCTAssertTrue(scan.allSatisfy { $0.bucketStart > s0.createdAt && $0.bucketStart <= s1.createdAt })

            _ = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            let third = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            XCTAssertEqual(third, second, "nothing changed, nothing added")
            XCTAssertEqual(third.reduce(Int64(0)) { $0 + $1.deltaBytes }, recentBytes + addedBytes)
        }
    }

    // MARK: - Scale

    /// A 4M-file scan feeds every file through `add`. Times the in-memory
    /// aggregation and the journal write on a synthetic 2M-file fixture.
    func testLargeFixtureTiming() async throws {
        let calendar = Calendar.current
        let scanStart = Date()
        var history = FileDateHistory(scanStart: scanStart, calendar: calendar)
        let fileCount = 2_000_000
        let places = (0..<400).map { index -> (path: String, category: GrowthCategory, subcategory: GrowthSubcategory?) in
            let path: String
            switch index % 4 {
            case 0: path = "/Users/tester/dev/project\(index)/node_modules/pkg/index.js"
            case 1: path = "/Users/tester/Downloads/file\(index).zip"
            case 2: path = "/Users/tester/Library/Caches/com.example.app\(index)/blob"
            default: path = "/Users/tester/Pictures/Export \(index)/photo.jpg"
            }
            let (category, subcategory) = GrowthCategory.classify(path: path)
            return (path, category, subcategory)
        }
        let span = scanStart.timeIntervalSince(history.windowStart) * 1.5

        let addStart = Date()
        for index in 0..<fileCount {
            let place = places[index % places.count]
            let birth = scanStart.timeIntervalSince1970 - span * Double((index &* 7_919) % 10_000) / 10_000
            let modified = index % 5 == 0 ? birth + 3 * Self.day : birth + 30
            history.add(
                path: place.path,
                sizeBytes: 4_096 + Int64(index % 1_000),
                category: place.category,
                subcategory: place.subcategory,
                dates: FileDates(birth: birth, modified: modified),
                home: Self.home
            )
        }
        let addSeconds = Date().timeIntervalSince(addStart)

        let bucketStart = Date()
        let buckets = history.deltasByBucketStart
        let bucketSeconds = Date().timeIntervalSince(bucketStart)
        let entryCount = buckets.values.reduce(0) { $0 + $1.count }

        var writeSeconds: TimeInterval = 0
        try await withEmptyTemporaryDatabase { trackedPathId in
            let writeStart = Date()
            try await DatabaseManager.shared.upsertGrowthJournalBuckets(
                trackedPathId: trackedPathId,
                deltasByBucketStart: buckets,
                source: .files
            )
            writeSeconds = Date().timeIntervalSince(writeStart)
            let written = try await DatabaseManager.shared.fetchGrowthJournalBuckets(trackedPathId: trackedPathId)
            XCTAssertEqual(written.count, entryCount)
            XCTAssertTrue(written.allSatisfy { $0.source == .files })
        }

        print(String(
            format: "FileDateHistory timing: %d files fed, %d counted, %d slots, %d journal rows; add %.2fs (%.0f ns/file), buckets %.3fs, write %.3fs",
            fileCount, history.fileCount, history.bucketCount, entryCount,
            addSeconds, addSeconds / Double(fileCount) * 1_000_000_000, bucketSeconds, writeSeconds
        ))
        XCTAssertGreaterThan(history.fileCount, 0)
        XCTAssertLessThan(history.fileCount, fileCount)
        XCTAssertLessThanOrEqual(history.bucketCount, GrowthJournalService.historyWindowDays * 48 + 1)
        XCTAssertLessThan(addSeconds, 60)
        XCTAssertLessThan(writeSeconds, 30)
    }
}
