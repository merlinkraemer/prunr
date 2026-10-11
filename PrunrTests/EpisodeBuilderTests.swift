import XCTest
@testable import Prunr

final class EpisodeBuilderTests: XCTestCase {
    private static let home = "/Users/tester"
    private static let gb: Int64 = 1_000_000_000
    private static let mb: Int64 = 1_000_000
    private static let iso = "download|/Users/tester/Downloads/ubuntu.iso"
    private static let project = "place|/Users/tester/dev/acme"

    private func calendar(_ identifier: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
        in calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func slot(
        _ unitKey: String,
        at date: Date,
        net: Int64,
        gross: Int64? = nil,
        source: GrowthJournalBucket.Source = .watch,
        observedSince: Date? = nil,
        category: String = "downloads",
        subcategory: String = ""
    ) -> JournalSlot {
        JournalSlot(
            unitKey: unitKey,
            category: category,
            subcategory: subcategory,
            source: source,
            slot: Int64(floor(date.timeIntervalSince1970 / Double(JournalSlot.slotSeconds))),
            netBytes: net,
            grossBytes: gross ?? abs(net),
            firstAt: date,
            observedSince: observedSince
        )
    }

    private func build(_ slots: [JournalSlot], now: Date, calendar: Calendar) -> ChangeFeed {
        EpisodeBuilder.build(slots: slots, now: now, calendar: calendar, home: Self.home)
    }

    // MARK: - The core outcome

    func testDownloadIsListedUnderTodayWithTimeAndAmount() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 15, 0, in: utc)
        let feed = build([slot(Self.iso, at: date(2026, 10, 11, 14, 20, in: utc), net: 2 * Self.gb)], now: now, calendar: utc)

        let day = try XCTUnwrap(feed.days.first)
        XCTAssertEqual(feed.days.count, 1)
        XCTAssertEqual(day.day, utc.startOfDay(for: now))
        XCTAssertEqual(EpisodeBuilder.dayLabel(for: day.day, now: now, calendar: utc), "Today")

        let episode = try XCTUnwrap(day.episodes.first)
        XCTAssertEqual(episode.title, "Downloads · ubuntu.iso")
        XCTAssertEqual(episode.netBytes, 2 * Self.gb)
        XCTAssertEqual(episode.rootPath, "/Users/tester/Downloads/ubuntu.iso")
        XCTAssertEqual(episode.category, .downloads)
        XCTAssertFalse(episode.isApproximateTime)
        XCTAssertEqual(EpisodeBuilder.caption(for: episode, calendar: utc), "14:20")
    }

    // MARK: - Runs and days

    func testGapOverThirtyMinutesSplitsRunAcrossMidnight() {
        let utc = calendar()
        let now = date(2026, 10, 11, 12, 0, in: utc)
        // 23:40 sits in the 23:30 slot, 01:10 in the 01:00 slot: a 60-minute gap.
        let feed = build([
            slot(Self.project, at: date(2026, 10, 9, 23, 40, in: utc), net: 1 * Self.gb),
            slot(Self.project, at: date(2026, 10, 10, 1, 10, in: utc), net: 2 * Self.gb)
        ], now: now, calendar: utc)

        XCTAssertEqual(feed.days.map(\.day), [
            utc.startOfDay(for: date(2026, 10, 10, 12, 0, in: utc)),
            utc.startOfDay(for: date(2026, 10, 9, 12, 0, in: utc))
        ])
        XCTAssertEqual(feed.days.map { $0.episodes.map(\.netBytes) }, [[2 * Self.gb], [1 * Self.gb]])
    }

    func testThirtyMinuteGapStillContinuesTheRun() {
        let utc = calendar()
        let now = date(2026, 10, 11, 12, 0, in: utc)
        // 23:40 (23:30 slot) and 00:40 (00:30 slot): one empty slot, a 30-minute gap.
        let feed = build([
            slot(Self.project, at: date(2026, 10, 9, 23, 40, in: utc), net: 1 * Self.gb),
            slot(Self.project, at: date(2026, 10, 10, 0, 40, in: utc), net: 2 * Self.gb)
        ], now: now, calendar: utc)

        XCTAssertEqual(feed.days.count, 1)
        XCTAssertEqual(feed.days.first?.day, utc.startOfDay(for: date(2026, 10, 9, 12, 0, in: utc)))
        XCTAssertEqual(feed.days.first?.episodes.map(\.netBytes), [3 * Self.gb])
    }

    func testRunPastMidnightStaysOnItsStartDay() {
        let utc = calendar()
        let now = date(2026, 10, 11, 12, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 9, 23, 50, in: utc), net: 1 * Self.gb),
            slot(Self.project, at: date(2026, 10, 10, 0, 5, in: utc), net: 1 * Self.gb),
            slot(Self.project, at: date(2026, 10, 10, 0, 35, in: utc), net: 1 * Self.gb)
        ], now: now, calendar: utc)

        XCTAssertEqual(feed.days.count, 1)
        XCTAssertEqual(feed.days.first?.day, utc.startOfDay(for: date(2026, 10, 9, 12, 0, in: utc)))
        XCTAssertEqual(feed.days.first?.episodes.first?.netBytes, 3 * Self.gb)
    }

    func testSameDayActivityMergesIntoOneRow() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 11, 9, 0, in: utc), net: 1 * Self.gb),
            slot(Self.project, at: date(2026, 10, 11, 15, 0, in: utc), net: 2 * Self.gb)
        ], now: now, calendar: utc)

        let episodes = try XCTUnwrap(feed.days.first?.episodes)
        XCTAssertEqual(feed.days.count, 1)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes.first?.netBytes, 3 * Self.gb)
        XCTAssertEqual(episodes.first?.grossBytes, 3 * Self.gb)
    }

    func testTimeIsTheSlotWhereMostBytesMoved() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 11, 10, 5, in: utc), net: 100 * Self.mb),
            // Most bytes moved here, even though the net is small.
            slot(Self.project, at: date(2026, 10, 11, 10, 35, in: utc), net: 50 * Self.mb, gross: 3 * Self.gb),
            slot(Self.project, at: date(2026, 10, 11, 11, 5, in: utc), net: 200 * Self.mb)
        ], now: now, calendar: utc)

        let episode = feed.days.first?.episodes.first
        XCTAssertEqual(episode?.time, date(2026, 10, 11, 10, 35, in: utc))
        XCTAssertEqual(episode?.netBytes, 350 * Self.mb)
    }

    func testChangeThatCameAndWentWithinTheDayHasNoRow() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 11, 9, 0, in: utc), net: 4 * Self.gb),
            slot(Self.project, at: date(2026, 10, 11, 16, 0, in: utc), net: -4 * Self.gb)
        ], now: now, calendar: utc)

        XCTAssertTrue(feed.isEmpty)
    }

    func testDaysAndRowsAreNewestFirst() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 10, 9, 0, in: utc), net: 1 * Self.gb),
            slot(Self.iso, at: date(2026, 10, 11, 8, 0, in: utc), net: 1 * Self.gb),
            slot(Self.project, at: date(2026, 10, 11, 13, 0, in: utc), net: 1 * Self.gb)
        ], now: now, calendar: utc)

        XCTAssertEqual(feed.days.count, 2)
        XCTAssertEqual(feed.days.first?.episodes.map(\.title), ["acme · dev", "Downloads · ubuntu.iso"])
    }

    func testDaysOutsideTheWeekAreNotListed() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 5, 0, 10, in: utc), net: 1 * Self.gb),
            slot(Self.project, at: date(2026, 10, 4, 20, 0, in: utc), net: 9 * Self.gb)
        ], now: now, calendar: utc)

        XCTAssertEqual(feed.days.map(\.day), [utc.startOfDay(for: date(2026, 10, 5, 12, 0, in: utc))])
    }

    // MARK: - Approximate times

    func testScanResidualWithOldWindowHasApproximateTime() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 9, 0, in: utc)
        let found = date(2026, 10, 11, 3, 10, in: utc)
        let feed = build([
            slot(Self.project, at: found, net: 2 * Self.gb, source: .scan, observedSince: date(2026, 10, 10, 3, 5, in: utc))
        ], now: now, calendar: utc)

        let episode = try XCTUnwrap(feed.days.first?.episodes.first)
        XCTAssertTrue(episode.isApproximateTime)
        XCTAssertEqual(episode.time, found)
        XCTAssertEqual(EpisodeBuilder.caption(for: episode, calendar: utc), "found 03:10 · daily check")
    }

    func testScanResidualWithRecentWindowKeepsItsTime() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 9, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 11, 3, 10, in: utc), net: 2 * Self.gb, source: .scan, observedSince: date(2026, 10, 11, 2, 40, in: utc))
        ], now: now, calendar: utc)

        let episode = try XCTUnwrap(feed.days.first?.episodes.first)
        XCTAssertFalse(episode.isApproximateTime)
        XCTAssertEqual(EpisodeBuilder.caption(for: episode, calendar: utc), "03:10")
    }

    func testWatcherPeakKeepsItsTimeNextToASmallScanResidual() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 11, 3, 10, in: utc), net: 100 * Self.mb, source: .scan, observedSince: date(2026, 10, 10, 3, 0, in: utc)),
            slot(Self.project, at: date(2026, 10, 11, 14, 20, in: utc), net: 5 * Self.gb)
        ], now: now, calendar: utc)

        let episode = try XCTUnwrap(feed.days.first?.episodes.first)
        XCTAssertFalse(episode.isApproximateTime)
        XCTAssertEqual(episode.time, date(2026, 10, 11, 14, 20, in: utc))
        XCTAssertEqual(episode.netBytes, 5 * Self.gb + 100 * Self.mb)
    }

    // MARK: - Merging and legacy rows

    func testSameUnitFromTwoTrackedPathsMerges() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let at = date(2026, 10, 11, 14, 20, in: utc)
        let feed = build([
            slot(Self.iso, at: at, net: 1 * Self.gb),
            slot(Self.iso, at: at.addingTimeInterval(60), net: 2 * Self.gb)
        ], now: now, calendar: utc)

        XCTAssertEqual(feed.days.first?.episodes.count, 1)
        XCTAssertEqual(feed.days.first?.episodes.first?.netBytes, 3 * Self.gb)
    }

    func testLegacyRowsAreOneCoarseRowPerCategoryAndSubcategory() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot("", at: date(2026, 10, 11, 9, 0, in: utc), net: 1 * Self.gb, category: "developer", subcategory: "buildArtifacts"),
            slot("", at: date(2026, 10, 11, 15, 0, in: utc), net: 1 * Self.gb, category: "developer", subcategory: "buildArtifacts"),
            slot("", at: date(2026, 10, 11, 10, 0, in: utc), net: 3 * Self.gb, category: "other"),
            slot("", at: date(2026, 10, 11, 11, 0, in: utc), net: 4 * Self.gb, category: "downloads"),
            slot("", at: date(2026, 10, 11, 12, 0, in: utc), net: 5 * Self.gb, category: "cachesAndSystem")
        ], now: now, calendar: utc)

        let episodes = try XCTUnwrap(feed.days.first?.episodes)
        let byTitle = Dictionary(uniqueKeysWithValues: episodes.map { ($0.title, $0.netBytes) })
        XCTAssertEqual(byTitle, [
            "Build Artifacts": 2 * Self.gb,
            "Files in your folders": 3 * Self.gb,
            "Downloads": 4 * Self.gb,
            "Files in Caches & System": 5 * Self.gb
        ])
        XCTAssertTrue(episodes.allSatisfy { $0.rootPath == nil })
        XCTAssertFalse(episodes.contains { $0.title == "Other" || $0.title.contains("Other") })
    }

    // MARK: - Time zones

    func testInjectedTimeZoneDecidesTheDayAndClock() throws {
        let losAngeles = calendar("America/Los_Angeles")
        let utc = calendar()
        // 02:00 UTC on 11 Oct is 19:00 on 10 Oct in Los Angeles (UTC-7).
        let at = date(2026, 10, 11, 2, 0, in: utc)
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([slot(Self.iso, at: at, net: 1 * Self.gb)], now: now, calendar: losAngeles)

        let day = try XCTUnwrap(feed.days.first)
        XCTAssertEqual(day.day, date(2026, 10, 10, 0, 0, in: losAngeles))
        XCTAssertEqual(EpisodeBuilder.dayLabel(for: day.day, now: now, calendar: losAngeles), "Yesterday")
        let episode = try XCTUnwrap(day.episodes.first)
        XCTAssertEqual(EpisodeBuilder.caption(for: episode, calendar: losAngeles), "19:00")

        let utcFeed = build([slot(Self.iso, at: at, net: 1 * Self.gb)], now: now, calendar: utc)
        XCTAssertEqual(utcFeed.days.first?.day, date(2026, 10, 11, 0, 0, in: utc))
    }

    func testDaylightSavingDayIsOneDay() throws {
        let berlin = calendar("Europe/Berlin")
        // 29 Mar 2026: clocks jump from 02:00 to 03:00. 01:40 CET and 03:10 CEST
        // are 30 real minutes apart, so they form one run.
        let now = date(2026, 3, 30, 12, 0, in: berlin)
        let feed = build([
            slot(Self.project, at: date(2026, 3, 29, 1, 40, in: berlin), net: 1 * Self.gb),
            slot(Self.project, at: date(2026, 3, 29, 3, 10, in: berlin), net: 1 * Self.gb),
            slot(Self.project, at: date(2026, 3, 29, 23, 30, in: berlin), net: 1 * Self.gb),
            slot(Self.iso, at: date(2026, 3, 30, 0, 30, in: berlin), net: 1 * Self.gb)
        ], now: now, calendar: berlin)

        XCTAssertEqual(feed.days.map(\.day), [
            date(2026, 3, 30, 0, 0, in: berlin),
            date(2026, 3, 29, 0, 0, in: berlin)
        ])
        let dstDay = try XCTUnwrap(feed.days.last)
        XCTAssertEqual(dstDay.episodes.map(\.netBytes), [3 * Self.gb])
        XCTAssertEqual(EpisodeBuilder.dayLabel(for: dstDay.day, now: now, calendar: berlin), "Yesterday")
        XCTAssertEqual(EpisodeBuilder.windowStart(now: now, calendar: berlin), date(2026, 3, 24, 0, 0, in: berlin))
    }

    // MARK: - Labels

    func testDayLabels() {
        let utc = calendar()
        let now = date(2026, 10, 11, 9, 0, in: utc) // a Sunday
        func label(_ day: Int, _ month: Int = 10) -> String {
            EpisodeBuilder.dayLabel(for: date(2026, month, day, 12, 0, in: utc), now: now, calendar: utc)
        }
        XCTAssertEqual(label(11), "Today")
        XCTAssertEqual(label(10), "Yesterday")
        XCTAssertEqual(label(9), "Friday")
        XCTAssertEqual(label(5), "Monday")
        XCTAssertEqual(label(4), "4 Oct")
        XCTAssertEqual(label(3), "3 Oct")
    }

    func testCaptionAddsTheNameDetail() {
        let utc = calendar()
        let episode = ChangeEpisode(
            id: "x",
            title: "Safari data",
            detail: "Application Support",
            category: .cachesAndSystem,
            rootPath: "/Users/tester/Library/Application Support/Safari",
            netBytes: Self.gb,
            grossBytes: Self.gb,
            day: date(2026, 10, 11, 0, 0, in: utc),
            time: date(2026, 10, 11, 8, 40, in: utc),
            isApproximateTime: false
        )
        XCTAssertEqual(EpisodeBuilder.caption(for: episode, calendar: utc), "08:40 · Application Support")
    }

    // MARK: - This week (header)

    func testWeekStartIsMidnightSixDaysBack() {
        let utc = calendar()
        let now = date(2026, 10, 11, 9, 30, in: utc)
        XCTAssertEqual(GrowthJournalService.weekStart(now: now, calendar: utc), date(2026, 10, 5, 0, 0, in: utc))
        XCTAssertEqual(EpisodeBuilder.windowStart(now: now, calendar: utc), GrowthJournalService.weekStart(now: now, calendar: utc))
    }

    /// The header equals the rows of the week, signed: growth minus what was
    /// given back.
    func testWeeklyChangeIsTheSignedSumOfTheWeeksRows() {
        let utc = calendar()
        let now = date(2026, 10, 11, 15, 0, in: utc)
        let feed = build([
            slot(Self.iso, at: date(2026, 10, 11, 14, 20, in: utc), net: 50 * Self.gb),
            slot(Self.project, at: date(2026, 10, 7, 10, 0, in: utc), net: -2 * Self.gb, category: "developer"),
            slot(Self.project, at: date(2026, 10, 5, 0, 10, in: utc), net: 300 * Self.mb, category: "developer")
        ], now: now, calendar: utc)

        let weekly = WeeklyChange(.loaded(feed), now: now, calendar: utc)
        XCTAssertEqual(weekly, .bytes(48 * Self.gb + 300 * Self.mb))
        XCTAssertEqual(weekly.amountText, "+\(formattedBytes(48 * Self.gb + 300 * Self.mb))")
        XCTAssertEqual(WeeklyChange(.loaded(feed), now: now, calendar: utc), .bytes(feed.netBytes(since: GrowthJournalService.weekStart(now: now, calendar: utc))))
    }

    func testWeeklyChangeShrinkReadsWithMinusSign() {
        let utc = calendar()
        let now = date(2026, 10, 11, 15, 0, in: utc)
        let feed = build([slot(Self.iso, at: date(2026, 10, 10, 9, 0, in: utc), net: -3 * Self.gb)], now: now, calendar: utc)
        let weekly = WeeklyChange(.loaded(feed), now: now, calendar: utc)
        XCTAssertEqual(weekly, .bytes(-3 * Self.gb))
        XCTAssertEqual(weekly.amountText, "\u{2212}\(formattedBytes(3 * Self.gb))")
    }

    /// Unknown is never zero: no read yet and a failed read both read "—".
    func testWeeklyChangeIsUnknownWithoutALoadedFeed() {
        XCTAssertEqual(WeeklyChange(nil), .unknown)
        XCTAssertEqual(WeeklyChange(.failed), .unknown)
        XCTAssertEqual(WeeklyChange(nil).amountText, "\u{2014}")
        XCTAssertEqual(WeeklyChange(.failed).amountText, "\u{2014}")
    }

    /// A real zero, once history was read, is "no change this week", never "0 MB".
    func testWeeklyChangeOfAnEmptyOrCancelledWeekIsNone() {
        let utc = calendar()
        let now = date(2026, 10, 11, 15, 0, in: utc)
        XCTAssertEqual(WeeklyChange(.loaded(.empty), now: now, calendar: utc), .none)
        XCTAssertNil(WeeklyChange(.loaded(.empty), now: now, calendar: utc).amountText)

        let tiny = build([slot(Self.iso, at: date(2026, 10, 11, 9, 0, in: utc), net: 1_000)], now: now, calendar: utc)
        XCTAssertEqual(WeeklyChange(.loaded(tiny), now: now, calendar: utc), .none)
    }
}
