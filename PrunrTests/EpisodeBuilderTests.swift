import XCTest
import SwiftUI
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

    private func clock(_ date: Date, _ calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
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

    private func build(
        _ slots: [JournalSlot],
        now: Date,
        calendar: Calendar,
        watchingSince: Date? = nil
    ) -> ChangeFeed {
        EpisodeBuilder.build(slots: slots, now: now, calendar: calendar, home: Self.home, watchingSince: watchingSince)
    }

    // MARK: - The core outcome

    func testDownloadIsListedUnderTodayWithTimeAndAmount() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 15, 0, in: utc)
        let feed = build([slot(Self.iso, at: date(2026, 10, 11, 14, 20, in: utc), net: 2 * Self.gb)], now: now, calendar: utc)

        let day = try XCTUnwrap(feed.days.first)
        XCTAssertEqual(feed.days.count, 1)
        XCTAssertEqual(day.day, utc.startOfDay(for: now))
        XCTAssertEqual(EpisodeBuilder.dayLabel(for: day.day, calendar: utc), "Sun 11 Oct")

        let episode = try XCTUnwrap(day.episodes.first)
        XCTAssertEqual(episode.title, "Downloads · ubuntu.iso")
        XCTAssertEqual(episode.netBytes, 2 * Self.gb)
        XCTAssertEqual(episode.rootPath, "/Users/tester/Downloads/ubuntu.iso")
        XCTAssertEqual(episode.category, .downloads)
        XCTAssertFalse(episode.isApproximateTime)
        XCTAssertEqual(clock(episode.time, utc), "14:20")
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

    func testTimeIsTheSlotWithTheBiggestNetThatDay() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 11, 10, 5, in: utc), net: 300 * Self.mb),
            // Most bytes moved here.
            slot(Self.project, at: date(2026, 10, 11, 10, 35, in: utc), net: 1_500 * Self.mb),
            slot(Self.project, at: date(2026, 10, 11, 11, 5, in: utc), net: 200 * Self.mb)
        ], now: now, calendar: utc)

        let episode = feed.days.first?.episodes.first
        XCTAssertEqual(episode?.time, date(2026, 10, 11, 10, 35, in: utc))
        XCTAssertEqual(episode?.netBytes, 2 * Self.gb)
    }

    func testChangeThatCameAndWentWithinTheDayHasNoRow() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 11, 9, 0, in: utc), net: 4 * Self.gb),
            slot(Self.project, at: date(2026, 10, 11, 16, 0, in: utc), net: -4 * Self.gb)
        ], now: now, calendar: utc)

        XCTAssertTrue(feed.episodes.isEmpty)
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

    /// The list reaches back 30 local days: today plus the 29 before it.
    func testDaysOutsideTheHistoryAreNotListed() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 9, 12, 0, 10, in: utc), net: 1 * Self.gb),
            slot(Self.project, at: date(2026, 9, 11, 20, 0, in: utc), net: 9 * Self.gb)
        ], now: now, calendar: utc)

        XCTAssertEqual(feed.days.map(\.day), [utc.startOfDay(for: date(2026, 9, 12, 12, 0, in: utc))])
        XCTAssertEqual(feed.episodes.map(\.netBytes), [1 * Self.gb])
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
    }

    func testScanResidualWithRecentWindowKeepsItsTime() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 9, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 11, 3, 10, in: utc), net: 2 * Self.gb, source: .scan, observedSince: date(2026, 10, 11, 2, 40, in: utc))
        ], now: now, calendar: utc)

        let episode = try XCTUnwrap(feed.days.first?.episodes.first)
        XCTAssertFalse(episode.isApproximateTime)
        XCTAssertEqual(clock(episode.time, utc), "03:10")
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

    // MARK: - Merging

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
        XCTAssertEqual(EpisodeBuilder.dayLabel(for: day.day, calendar: losAngeles), "Sat 10 Oct")
        let episode = try XCTUnwrap(day.episodes.first)
        XCTAssertEqual(clock(episode.time, losAngeles), "19:00")

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
        XCTAssertEqual(EpisodeBuilder.dayLabel(for: dstDay.day, calendar: berlin), "Sun 29 Mar")
        XCTAssertEqual(GrowthJournalService.weekStart(now: now, calendar: berlin), date(2026, 3, 24, 0, 0, in: berlin))
        XCTAssertEqual(EpisodeBuilder.windowStart(now: now, calendar: berlin), date(2026, 3, 1, 0, 0, in: berlin))
    }

    // MARK: - Labels

    /// Real dates, also for today and yesterday.
    func testDayLabelsAreRealDates() {
        let utc = calendar()
        func label(_ day: Int, _ month: Int = 10) -> String {
            EpisodeBuilder.dayLabel(for: date(2026, month, day, 12, 0, in: utc), calendar: utc)
        }
        XCTAssertEqual(label(11), "Sun 11 Oct")
        XCTAssertEqual(label(10), "Sat 10 Oct")
        XCTAssertEqual(label(7), "Wed 7 Oct")
        XCTAssertEqual(label(2), "Fri 2 Oct")
        XCTAssertEqual(label(28, 9), "Mon 28 Sep")
    }

    // MARK: - This week (header)

    func testWeekStartIsMidnightSixDaysBackAndHistoryTwentyNine() {
        let utc = calendar()
        let now = date(2026, 10, 11, 9, 30, in: utc)
        XCTAssertEqual(GrowthJournalService.weekStart(now: now, calendar: utc), date(2026, 10, 5, 0, 0, in: utc))
        XCTAssertEqual(GrowthJournalService.historyStart(now: now, calendar: utc), date(2026, 9, 12, 0, 0, in: utc))
        XCTAssertEqual(EpisodeBuilder.windowStart(now: now, calendar: utc), GrowthJournalService.historyStart(now: now, calendar: utc))
    }

    /// The header is everything this week, signed, whether it earned a row or
    /// not: rows are only what reached 1 GB, so they need not add up to it.
    func testWeeklyChangeCountsEverythingThisWeek() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 15, 0, in: utc)
        let feed = build([
            slot(Self.iso, at: date(2026, 10, 11, 14, 20, in: utc), net: 50 * Self.gb),
            slot(Self.project, at: date(2026, 10, 7, 10, 0, in: utc), net: -2 * Self.gb, category: "developer"),
            slot("place|/Users/tester/b", at: date(2026, 10, 5, 0, 10, in: utc), net: 300 * Self.mb, category: "developer"),
            // Last week: a row, but not part of the header.
            slot("place|/Users/tester/c", at: date(2026, 10, 2, 9, 0, in: utc), net: 7 * Self.gb, category: "developer")
        ], now: now, calendar: utc)

        let expected = 48 * Self.gb + 300 * Self.mb
        XCTAssertEqual(feed.weekNetBytes, expected)
        let weekly = WeeklyChange(.loaded(feed), now: now)
        XCTAssertEqual(weekly, .bytes(expected))
        XCTAssertEqual(weekly.amountText, "+\(formattedBytes(expected))")
        XCTAssertEqual(feed.episodes.map(\.netBytes), [50 * Self.gb, -2 * Self.gb, 7 * Self.gb])
    }

    func testWeeklyChangeShrinkReadsWithMinusSign() {
        let utc = calendar()
        let now = date(2026, 10, 11, 15, 0, in: utc)
        let feed = build([slot(Self.iso, at: date(2026, 10, 10, 9, 0, in: utc), net: -3 * Self.gb)], now: now, calendar: utc)
        let weekly = WeeklyChange(.loaded(feed), now: now)
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

    /// A real zero, once history exists, reads "No change", never "0 MB".
    func testTrueZeroReadsNoChangeThisWeekOnceHistoryExists() {
        let utc = calendar()
        let now = date(2026, 10, 11, 15, 0, in: utc)
        let since = date(2026, 10, 8, 3, 0, in: utc)

        let quiet = build([], now: now, calendar: utc, watchingSince: since)
        XCTAssertEqual(WeeklyChange(.loaded(quiet), now: now), .none)
        XCTAssertNil(WeeklyChange(.loaded(quiet), now: now).amountText)

        let tiny = build([slot(Self.iso, at: date(2026, 10, 11, 9, 0, in: utc), net: 1_000)], now: now, calendar: utc, watchingSince: since)
        XCTAssertEqual(WeeklyChange(.loaded(tiny), now: now), .none)

        let cancelledOut = build([
            slot(Self.iso, at: date(2026, 10, 9, 9, 0, in: utc), net: 3 * Self.gb),
            slot(Self.project, at: date(2026, 10, 10, 9, 0, in: utc), net: -3 * Self.gb)
        ], now: now, calendar: utc, watchingSince: since)
        XCTAssertEqual(WeeklyChange(.loaded(cancelledOut), now: now), .none)
    }

    /// No history yet (day one, or no start known) reads "—", not "no change".
    func testNoHistoryYetReadsUnknown() {
        let utc = calendar()
        let now = date(2026, 10, 11, 15, 0, in: utc)
        XCTAssertEqual(WeeklyChange(.loaded(.empty), now: now), .unknown)

        let dayOne = build(
            [slot(Self.iso, at: date(2026, 10, 11, 14, 0, in: utc), net: 20 * Self.mb)],
            now: now, calendar: utc, watchingSince: date(2026, 10, 11, 9, 0, in: utc)
        )
        XCTAssertEqual(WeeklyChange(.loaded(dayOne), now: now), .unknown)

        // A big change on day one is a row, and the header counts it.
        let bigDayOne = build(
            [slot(Self.iso, at: date(2026, 10, 11, 14, 0, in: utc), net: 4 * Self.gb)],
            now: now, calendar: utc, watchingSince: date(2026, 10, 11, 9, 0, in: utc)
        )
        XCTAssertEqual(WeeklyChange(.loaded(bigDayOne), now: now), .bytes(4 * Self.gb))
    }

    // MARK: - The 1 GB rule

    func testBigEventIsOneRowThatDayWithItsTime() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let docker = "place|/Users/tester/Library/Containers/com.docker.docker"
        let feed = build([
            slot(docker, at: date(2026, 10, 6, 14, 20, in: utc), net: 30 * Self.gb, category: "developer"),
            slot(docker, at: date(2026, 10, 6, 14, 50, in: utc), net: 1 * Self.gb, category: "developer")
        ], now: now, calendar: utc)

        XCTAssertEqual(feed.days.count, 1)
        let row = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(feed.episodes.count, 1)
        XCTAssertEqual(row.day, date(2026, 10, 6, 0, 0, in: utc))
        XCTAssertEqual(row.netBytes, 31 * Self.gb)
        XCTAssertNil(row.buildingSince)
        XCTAssertEqual(clock(row.time, utc), "14:20")
    }

    /// 250 MB a day from Fri 2 Oct: one row on Mon 5 Oct, when the place has
    /// used a whole gigabyte, carrying all four days. Tuesday's 250 MB waits.
    func testSlowGrowthGetsOneRowOnTheDayItCrossesTheLine() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build((2...6).map { day in
            slot(Self.project, at: date(2026, 10, day, 10, 0, in: utc), net: 250 * Self.mb)
        }, now: now, calendar: utc)

        let row = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(feed.episodes.count, 1)
        XCTAssertEqual(row.day, date(2026, 10, 5, 0, 0, in: utc))
        XCTAssertEqual(row.netBytes, 1 * Self.gb)
        XCTAssertEqual(row.buildingSince, date(2026, 10, 2, 0, 0, in: utc))
        XCTAssertEqual(EpisodeBuilder.dayLabel(for: try XCTUnwrap(row.buildingSince), calendar: utc), "Fri 2 Oct")
        XCTAssertFalse(row.isLargeGrowth)
        // The header still counts all of this week's growth.
        XCTAssertEqual(feed.weekNetBytes, 500 * Self.mb)
    }

    /// The count never resets on its own: the next gigabyte is the next row.
    func testCountKeepsRunningAfterARow() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build((1...8).map { day in
            slot(Self.project, at: date(2026, 10, day, 10, 0, in: utc), net: 250 * Self.mb)
        }, now: now, calendar: utc)

        XCTAssertEqual(feed.days.map(\.day), [date(2026, 10, 8, 0, 0, in: utc), date(2026, 10, 4, 0, 0, in: utc)])
        XCTAssertEqual(feed.episodes.map(\.buildingSince), [date(2026, 10, 5, 0, 0, in: utc), date(2026, 10, 1, 0, 0, in: utc)])
    }

    /// Slow growth that ends in a big step reads as the step, with its time.
    func testBigStepAfterSlowGrowthKeepsItsTime() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 8, 10, 0, in: utc), net: 300 * Self.mb),
            slot(Self.project, at: date(2026, 10, 9, 10, 0, in: utc), net: 300 * Self.mb),
            slot(Self.project, at: date(2026, 10, 10, 15, 0, in: utc), net: 2 * Self.gb)
        ], now: now, calendar: utc)

        let row = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(feed.episodes.count, 1)
        XCTAssertEqual(row.netBytes, 2_600 * Self.mb)
        XCTAssertNil(row.buildingSince)
        XCTAssertEqual(clock(row.time, utc), "15:00")
    }

    /// A place that gains and loses 1.2 GB day after day gets a row each time.
    func testChurnGetsARowForEachCrossing() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 8, 10, 0, in: utc), net: 1_200 * Self.mb),
            slot(Self.project, at: date(2026, 10, 9, 10, 0, in: utc), net: -1_200 * Self.mb),
            slot(Self.project, at: date(2026, 10, 10, 10, 0, in: utc), net: 1_200 * Self.mb)
        ], now: now, calendar: utc)

        XCTAssertEqual(feed.episodes.map(\.netBytes), [1_200 * Self.mb, -1_200 * Self.mb, 1_200 * Self.mb])
        XCTAssertEqual(feed.episodes.map(\.isLargeGrowth), [false, false, false])
    }

    func testTheLineIsExactlyOneGigabyte() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot("place|/Users/tester/at", at: date(2026, 10, 11, 9, 0, in: utc), net: 1 * Self.gb),
            slot("place|/Users/tester/below", at: date(2026, 10, 10, 9, 0, in: utc), net: 1 * Self.gb - 1),
            slot("place|/Users/tester/shrink", at: date(2026, 10, 9, 9, 0, in: utc), net: -1 * Self.gb)
        ], now: now, calendar: utc)

        XCTAssertEqual(feed.episodes.map(\.netBytes), [1 * Self.gb, -1 * Self.gb])
        XCTAssertEqual(EpisodeBuilder.rowThresholdBytes, 1 * Self.gb)
    }

    /// Orange only for growth of 5 GB or more; smaller growth and shrinks
    /// are not.
    func testOrangeOnlyForGrowthOfFiveGigabytes() {
        func episode(_ net: Int64) -> ChangeEpisode {
            ChangeEpisode(
                id: "x", title: "x", detail: nil, category: .other, rootPath: nil,
                netBytes: net, grossBytes: abs(net), day: Date(), time: Date(), isApproximateTime: false
            )
        }
        XCTAssertEqual(EpisodeBuilder.largeGrowthBytes, 5 * Self.gb)
        XCTAssertTrue(episode(5 * Self.gb).isLargeGrowth)
        XCTAssertTrue(episode(31 * Self.gb).isLargeGrowth)
        XCTAssertFalse(episode(5 * Self.gb - 1).isLargeGrowth)
        XCTAssertFalse(episode(1 * Self.gb).isLargeGrowth)
        XCTAssertFalse(episode(-8 * Self.gb).isLargeGrowth)
        XCTAssertTrue(EpisodeBuilder.isLargeGrowth(5 * Self.gb), "the header uses the same line")
        XCTAssertFalse(EpisodeBuilder.isLargeGrowth(4_900 * Self.mb))
    }

    /// Each place's count starts on the oldest shown day: growth before the
    /// 30 days does not count toward a row inside them.
    func testCountStartsOnTheOldestShownDay() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 9, 11, 10, 0, in: utc), net: 800 * Self.mb),
            slot(Self.project, at: date(2026, 9, 12, 10, 0, in: utc), net: 800 * Self.mb)
        ], now: now, calendar: utc)

        XCTAssertTrue(feed.episodes.isEmpty)
    }

    // MARK: - Trash

    private static let trash = "trash|/Users/tester/.Trash"

    func testMoveToTrashIsMarkedAndTrashGrowthIsNoRow() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 11, 14, 5, in: utc), net: -3 * Self.gb, category: "developer"),
            slot(Self.trash, at: date(2026, 10, 11, 14, 6, in: utc), net: 3 * Self.gb, category: "trash")
        ], now: now, calendar: utc, watchingSince: date(2026, 10, 1, 3, 0, in: utc))

        XCTAssertFalse(feed.episodes.contains { $0.category == .trash }, "no orange Trash row")
        let source = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(feed.episodes.count, 1)
        XCTAssertEqual(source.netBytes, -3 * Self.gb)
        XCTAssertTrue(source.isMovedToTrash)
        XCTAssertEqual(clock(source.time, utc), "14:05")
        XCTAssertEqual(feed.weekNetBytes, 0, "the sum is unchanged by the move")
        XCTAssertEqual(WeeklyChange(.loaded(feed), now: now), .none)
    }

    func testShrinkIsNotAMoveWhenTheTrashTookLessThanNinetyPercent() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 11, 14, 5, in: utc), net: -3 * Self.gb, category: "developer"),
            slot(Self.trash, at: date(2026, 10, 11, 14, 6, in: utc), net: 2 * Self.gb, category: "trash"),
            // A later slot does not count.
            slot(Self.trash, at: date(2026, 10, 11, 18, 0, in: utc), net: 2 * Self.gb, category: "trash")
        ], now: now, calendar: utc)

        let source = try XCTUnwrap(feed.episodes.first { $0.netBytes < 0 })
        XCTAssertEqual(feed.episodes.count, 1)
        XCTAssertEqual(source.netBytes, -3 * Self.gb)
        XCTAssertFalse(source.isMovedToTrash)
    }

    func testEmptyingTheTrashIsAGreyRow() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.trash, at: date(2026, 10, 11, 9, 0, in: utc), net: -4 * Self.gb, category: "trash")
        ], now: now, calendar: utc)

        let row = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(row.title, "Trash emptied")
        XCTAssertEqual(row.netBytes, -4 * Self.gb)
        XCTAssertFalse(row.isLargeGrowth)
        XCTAssertFalse(row.isMovedToTrash)
    }

    /// Trash growth never counts toward its own row, so emptying it shows
    /// everything that left.
    func testEmptiedAfterGrowthShowsTheWholeShrink() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.trash, at: date(2026, 10, 9, 9, 0, in: utc), net: 600 * Self.mb, category: "trash"),
            slot(Self.trash, at: date(2026, 10, 10, 9, 0, in: utc), net: 3 * Self.gb, category: "trash"),
            slot(Self.trash, at: date(2026, 10, 11, 9, 0, in: utc), net: -4 * Self.gb, category: "trash")
        ], now: now, calendar: utc)

        XCTAssertEqual(feed.episodes.map(\.netBytes), [-4 * Self.gb])
        XCTAssertEqual(feed.episodes.first?.title, "Trash emptied")
    }

    // MARK: - States

    func testDayOneWhileTheListIsEmpty() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let since = date(2026, 10, 11, 9, 0, in: utc)

        XCTAssertTrue(build([], now: now, calendar: utc, watchingSince: since).isDayOne(now: now))
        // Small changes alone do not end day one.
        let small = build([slot(Self.iso, at: date(2026, 10, 11, 12, 0, in: utc), net: 30 * Self.mb)], now: now, calendar: utc, watchingSince: since)
        XCTAssertTrue(small.isDayOne(now: now))
        // A big change shows as a row at once.
        let big = build([slot(Self.iso, at: date(2026, 10, 11, 12, 0, in: utc), net: 3 * Self.gb)], now: now, calendar: utc, watchingSince: since)
        XCTAssertFalse(big.isDayOne(now: now))
        XCTAssertEqual(big.days.first?.episodes.map(\.netBytes), [3 * Self.gb])
        // After 24 hours it is no longer day one, even with nothing listed.
        XCTAssertFalse(build([], now: now, calendar: utc, watchingSince: date(2026, 10, 10, 19, 0, in: utc)).isDayOne(now: now))
    }

    /// No row in the last 7 days: one line dates the newest row, and older
    /// rows still show below it.
    func testQuietWeekSaysNothingOverOneGigabyteSince() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.iso, at: date(2026, 10, 10, 12, 0, in: utc), net: 80 * Self.mb),
            slot(Self.project, at: date(2026, 9, 28, 12, 0, in: utc), net: 6 * Self.gb)
        ], now: now, calendar: utc, watchingSince: date(2026, 9, 1, 3, 0, in: utc))

        XCTAssertFalse(feed.isDayOne(now: now))
        let since = try XCTUnwrap(feed.quietSince(now: now, calendar: utc))
        XCTAssertEqual(EpisodeBuilder.quietLabel(since: since, calendar: utc), "Nothing over 1 GB since 28 Sep")
        XCTAssertEqual(feed.episodes.map(\.netBytes), [6 * Self.gb])
        XCTAssertEqual(feed.weekNetBytes, 80 * Self.mb)
        XCTAssertFalse(feed.isShortHistory(now: now, calendar: utc))

        // No row at all: the line dates the start of what the list can see.
        let none = build([], now: now, calendar: utc, watchingSince: date(2026, 9, 1, 3, 0, in: utc))
        XCTAssertEqual(none.quietSince(now: now, calendar: utc), date(2026, 9, 12, 0, 0, in: utc))
        let recent = build([], now: now, calendar: utc, watchingSince: date(2026, 10, 3, 3, 10, in: utc))
        XCTAssertEqual(recent.quietSince(now: now, calendar: utc), date(2026, 10, 3, 3, 10, in: utc))

        // A row this week: no line. The week starts six days before today.
        let busy = build([slot(Self.iso, at: date(2026, 10, 5, 0, 10, in: utc), net: 2 * Self.gb)], now: now, calendar: utc)
        XCTAssertNil(busy.quietSince(now: now, calendar: utc))
    }

    func testShortHistoryEndsWithWatchingSince() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let since = date(2026, 10, 3, 3, 10, in: utc)
        let feed = build([slot(Self.iso, at: date(2026, 10, 5, 12, 0, in: utc), net: 1 * Self.gb)], now: now, calendar: utc, watchingSince: since)

        XCTAssertTrue(feed.isShortHistory(now: now, calendar: utc))
        XCTAssertEqual(EpisodeBuilder.watchingSinceLabel(since, calendar: utc), "Watching since 3 Oct")
        // Watching since the first shown day still counts as short; before it does not.
        XCTAssertTrue(build([], now: now, calendar: utc, watchingSince: date(2026, 9, 12, 0, 0, in: utc)).isShortHistory(now: now, calendar: utc))
        XCTAssertFalse(build([], now: now, calendar: utc, watchingSince: date(2026, 9, 11, 23, 0, in: utc)).isShortHistory(now: now, calendar: utc))
    }

    // MARK: - History start

    func testHistoryStartIsRememberedAcrossSnapshotPruning() throws {
        let suite = "PrunrTests.HistoryStart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let utc = calendar()
        let first = date(2026, 9, 1, 3, 10, in: utc)
        let later = date(2026, 9, 20, 3, 10, in: utc)

        XCTAssertNil(HistoryStart.remember(oldestSnapshot: nil, defaults: defaults))
        XCTAssertEqual(HistoryStart.remember(oldestSnapshot: first, defaults: defaults), first)
        // The first snapshot was pruned: the oldest left is newer, the start is not.
        XCTAssertEqual(HistoryStart.remember(oldestSnapshot: later, defaults: defaults), first)
        HistoryStart.reset(defaults: defaults)
        XCTAssertEqual(HistoryStart.remember(oldestSnapshot: later, defaults: defaults), later)
    }

    /// Tests run inside the app: the default store must be the test suite, so
    /// nothing a test does reaches the owner's real "Watching since".
    func testHistoryStartNeverWritesTheRealDefaultsUnderTests() {
        let realBefore = UserDefaults.standard.object(forKey: HistoryStart.defaultsKey) as? Date
        defer { HistoryStart.reset() }

        XCTAssertFalse(HistoryStart.store === UserDefaults.standard)
        HistoryStart.reset()
        let early = date(1990, 1, 1, 0, 0, in: calendar())
        XCTAssertEqual(HistoryStart.remember(oldestSnapshot: early), early)
        HistoryStart.reset()

        XCTAssertEqual(UserDefaults.standard.object(forKey: HistoryStart.defaultsKey) as? Date, realBefore)
    }

    // MARK: - Captions (drilldown second line)

    private func episode(
        _ id: String,
        _ category: GrowthCategory,
        _ net: Int64,
        at time: Date,
        detail: String? = nil,
        rootPath: String? = nil,
        calendar: Calendar,
        approximate: Bool = false,
        movedToTrash: Bool = false,
        buildingSince: Date? = nil
    ) -> ChangeEpisode {
        ChangeEpisode(
            id: id,
            title: id,
            detail: detail,
            category: category,
            rootPath: rootPath,
            netBytes: net,
            grossBytes: abs(net),
            day: calendar.startOfDay(for: time),
            time: time,
            isApproximateTime: approximate,
            isMovedToTrash: movedToTrash,
            buildingSince: buildingSince
        )
    }

    func testPlaceDetailGoesToTheContentsCaptionAndTheRowCaptionIsOnlyTheTime() {
        let utc = calendar()
        let row = episode("Docker disk", .developer, Self.gb, at: date(2026, 10, 11, 8, 40, in: utc),
                          detail: "images, containers, volumes",
                          rootPath: "/Users/tester/Library/Containers/com.docker.docker", calendar: utc)
        XCTAssertEqual(row.title, "Docker disk")
        XCTAssertEqual(EpisodeBuilder.timeCaption(for: row, calendar: utc), "08:40")
        XCTAssertEqual(
            EpisodeBuilder.contentsCaption(for: row, headerTitle: "Docker disk", home: Self.home),
            "images, containers, volumes · ~/Library/Containers/com.docker.docker"
        )
        XCTAssertEqual(EpisodeBuilder.tildePath("/Volumes/X/a", home: Self.home), "/Volumes/X/a")
    }

    func testPlaceRowHasNoCaptionWithoutAKnownTime() {
        let utc = calendar()
        let at = date(2026, 10, 5, 14, 5, in: utc)
        let scanned = episode("a", .developer, Self.gb, at: at, detail: "ignored", calendar: utc, approximate: true)
        XCTAssertNil(EpisodeBuilder.timeCaption(for: scanned, calendar: utc))

        let slow = episode("b", .mediaAndDocuments, Self.gb, at: at, calendar: utc,
                           buildingSince: date(2026, 10, 2, 0, 0, in: utc))
        XCTAssertNil(EpisodeBuilder.timeCaption(for: slow, calendar: utc))

        let moved = episode("c", .downloads, -3 * Self.gb, at: at, calendar: utc, movedToTrash: true)
        XCTAssertEqual(EpisodeBuilder.timeCaption(for: moved, calendar: utc), "14:05")
    }

    func testRowsFoundByScanHaveNoTime() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 15, 0, in: utc)
        let found = date(2026, 10, 11, 3, 0, in: utc)
        let feed = build([
            slot(Self.iso, at: found, net: 2 * Self.gb, source: .scan, observedSince: date(2026, 10, 10, 3, 0, in: utc))
        ], now: now, calendar: utc)
        let row = try XCTUnwrap(feed.episodes.first)
        XCTAssertNil(EpisodeBuilder.timeCaption(for: row, calendar: utc))
    }

    // MARK: - Groups (main list)

    func testDayGroupsOneRowPerCategoryBiggestFirst() throws {
        let utc = calendar()
        let at = date(2026, 10, 5, 12, 0, in: utc)
        let day = ChangeFeedDay(day: utc.startOfDay(for: at), episodes: [
            episode("xcode", .developer, 1_300 * Self.mb, at: at.addingTimeInterval(300), calendar: utc),
            episode("iso", .downloads, 5 * Self.gb, at: at.addingTimeInterval(200), calendar: utc),
            episode("node", .developer, 800 * Self.mb, at: at.addingTimeInterval(100), calendar: utc),
            episode("mail", .mediaAndDocuments, 1_400 * Self.mb, at: at, calendar: utc)
        ])

        let groups = day.groups
        XCTAssertEqual(groups.map(\.category), [.downloads, .developer, .mediaAndDocuments])
        let developer = try XCTUnwrap(groups.first { $0.category == .developer })
        XCTAssertEqual(developer.netBytes, 2_100 * Self.mb)
        XCTAssertEqual(developer.episodes.map(\.id), ["xcode", "node"], "rows stay newest first")
        XCTAssertEqual(developer.day, day.day)
        XCTAssertFalse(developer.isLargeGrowth)
    }

    func testGroupIsOrangeOnlyForGrowthOfFiveGigabytes() {
        let utc = calendar()
        let at = date(2026, 10, 5, 12, 0, in: utc)
        func group(_ nets: [Int64]) -> ChangeGroup {
            ChangeGroup(
                day: utc.startOfDay(for: at),
                category: .developer,
                episodes: nets.enumerated().map { episode("\($0.offset)", .developer, $0.element, at: at, calendar: utc) }
            )
        }
        XCTAssertTrue(group([5 * Self.gb]).isLargeGrowth)
        XCTAssertTrue(group([3 * Self.gb, 2 * Self.gb]).isLargeGrowth)
        XCTAssertFalse(group([6 * Self.gb, -1_500 * Self.mb]).isLargeGrowth)
        XCTAssertFalse(group([Self.gb]).isLargeGrowth)
        XCTAssertFalse(group([-8 * Self.gb]).isLargeGrowth)
        XCTAssertEqual(group([2 * Self.gb, -1_500 * Self.mb]).netBytes, 500 * Self.mb)
    }

    func testGroupIDsDifferPerCategoryAndDay() {
        let utc = calendar()
        let monday = date(2026, 10, 5, 0, 0, in: utc)
        let tuesday = date(2026, 10, 6, 0, 0, in: utc)
        let a = ChangeGroup(day: monday, category: .developer, episodes: [])
        let b = ChangeGroup(day: tuesday, category: .developer, episodes: [])
        let c = ChangeGroup(day: monday, category: .downloads, episodes: [])
        XCTAssertEqual(Set([a.id, b.id, c.id]).count, 3)
    }

    private func group(_ places: [(id: String, rootPath: String?)]) -> ChangeGroup {
        let utc = calendar()
        let at = date(2026, 10, 5, 12, 0, in: utc)
        return ChangeGroup(
            day: utc.startOfDay(for: at),
            category: .developer,
            episodes: places.map { episode($0.id, .developer, Self.gb, at: at, rootPath: $0.rootPath, calendar: utc) }
        )
    }

    func testGroupRowsWithSeveralPlacesOpenTheDaysPlaces() {
        let pathless = group([("somewhere", nil)])
        let several = group([("a", "/Users/tester/a"), ("b", nil)])
        let bothWithPaths = group([("a", "/Users/tester/a"), ("b", "/Users/tester/b")])
        for row in [pathless, several, bothWithPaths] {
            XCTAssertEqual(FeedPage.feed.opening(row), .group(row))
            XCTAssertEqual(FeedPage.group(row).parent, .feed)
        }
    }

    func testGroupRowWithOnePlaceOpensItsContentsAndBackReturnsToTheList() throws {
        let one = group([("xcode", "/Users/tester/Library/Developer/Xcode/DerivedData")])
        let place = try XCTUnwrap(one.episodes.first)
        let page = FeedPage.feed.opening(one)

        XCTAssertEqual(FeedPage.soloPlace(of: one), place)
        XCTAssertEqual(page, .place(one, place))
        XCTAssertEqual(page.place, place)
        XCTAssertEqual(page.parent, .feed)
        XCTAssertNil(FeedPage.soloPlace(of: group([("a", "/Users/tester/a"), ("b", "/Users/tester/b")])))
    }

    func testPlaceRowsWithAPathOpenTheirContents() throws {
        let day = group([("a", "/Users/tester/a"), ("b", nil)])
        let withPath = try XCTUnwrap(day.episodes.first { $0.id == "a" })
        let pathless = try XCTUnwrap(day.episodes.first { $0.id == "b" })

        XCTAssertTrue(FeedPage.opensContents(withPath))
        XCTAssertFalse(FeedPage.opensContents(pathless))
        XCTAssertEqual(FeedPage.group(day).opening(withPath), .place(day, withPath))
        XCTAssertEqual(FeedPage.group(day).opening(pathless), .group(day))
        XCTAssertEqual(FeedPage.feed.opening(withPath), .feed)
    }

    func testBackGoesUpOneLevelAndTheFooterKeepsTheRowsDate() throws {
        let day = group([("a", "/Users/tester/a"), ("b", "/Users/tester/b")])
        let place = try XCTUnwrap(day.episodes.first)
        let page = FeedPage.group(day).opening(place)

        XCTAssertEqual(page.depth, 2)
        XCTAssertEqual(page.group?.day, day.day)
        XCTAssertEqual(page.place, place)
        XCTAssertEqual(page.parent, .group(day))
        XCTAssertEqual(page.parent.parent, .feed)
        XCTAssertEqual(FeedPage.feed.parent, .feed)
    }

    func testEveryPageHasItsOwnIdentity() throws {
        let day = group([("a", "/Users/tester/a"), ("b", "/Users/tester/b")])
        let a = try XCTUnwrap(day.episodes.first { $0.id == "a" })
        let b = try XCTUnwrap(day.episodes.first { $0.id == "b" })
        let ids = [FeedPage.feed, .group(day), .place(day, a), .place(day, b)].map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryLevelPushesWithTheSameSlide() {
        XCTAssertEqual(PushSlide.offset(isIncoming: true, forward: true, progress: 0, width: 300), 300)
        XCTAssertEqual(PushSlide.offset(isIncoming: false, forward: true, progress: 0, width: 300), 0)
        XCTAssertEqual(PushSlide.offset(isIncoming: true, forward: true, progress: 1, width: 300), 0)
        XCTAssertEqual(PushSlide.offset(isIncoming: false, forward: true, progress: 1, width: 300), -300)
        XCTAssertEqual(PushSlide.offset(isIncoming: true, forward: false, progress: 0, width: 300), -300)
        XCTAssertEqual(PushSlide.offset(isIncoming: false, forward: false, progress: 1, width: 300), 300)
    }

    func testDeeperPagesPushAndShallowerPagesPop() throws {
        let day = group([("a", "/Users/tester/a"), ("b", "/Users/tester/b")])
        let a = try XCTUnwrap(day.episodes.first { $0.id == "a" })
        XCTAssertTrue(ListPage.isPush(from: .feed(.feed), to: .feed(.group(day))))
        XCTAssertTrue(ListPage.isPush(from: .feed(.group(day)), to: .feed(.place(day, a))))
        XCTAssertFalse(ListPage.isPush(from: .feed(.place(day, a)), to: .feed(.group(day))))
        XCTAssertTrue(ListPage.isPush(from: .feed(.group(day)), to: .categories))
        XCTAssertFalse(ListPage.isPush(from: .categories, to: .feed(.feed)))
    }

    func testContextMenuOnlyOnRowsWithAPath() {
        XCTAssertEqual(RowPathAction.actions(forPath: "/Users/tester/a"), [.showInFinder, .copyPath])
        XCTAssertEqual(RowPathAction.actions(forPath: nil), [])
        XCTAssertEqual(RowPathAction.showInFinder.title, "Show in Finder")
        XCTAssertEqual(RowPathAction.copyPath.title, "Copy Path")
    }

    func testFinderSelectsOrdinaryPathsAndOpensHiddenICloudContainerFolders() {
        let home = "/Users/tester"
        let whatsApp = "/Users/tester/Library/Mobile Documents/57T9237FN3~net~whatsapp~WhatsApp"
        XCTAssertEqual(
            FinderReveal.target(forPath: "/Users/tester/dev/app/build", isDirectory: true, home: home),
            .select(URL(fileURLWithPath: "/Users/tester/dev/app/build"))
        )
        XCTAssertEqual(
            FinderReveal.target(forPath: whatsApp + "/Accounts", isDirectory: true, home: home),
            .open(URL(fileURLWithPath: whatsApp + "/Accounts"))
        )
        XCTAssertEqual(
            FinderReveal.target(forPath: whatsApp + "/Accounts/backup.db", isDirectory: false, home: home),
            .open(URL(fileURLWithPath: whatsApp + "/Accounts"))
        )
        XCTAssertEqual(
            FinderReveal.target(forPath: whatsApp, isDirectory: true, home: home),
            .open(URL(fileURLWithPath: whatsApp))
        )
        XCTAssertEqual(
            FinderReveal.target(forPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/Notes.txt", isDirectory: false, home: home),
            .select(URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/Notes.txt"))
        )
        XCTAssertEqual(
            FinderReveal.target(forPath: "/Users/tester/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault", isDirectory: true, home: home),
            .select(URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault"))
        )
    }

    func testMainListRowIsNamedAfterThePageItOpens() {
        let solo = group([("Build files", "/Users/tester/dev/app/build")])
        XCTAssertEqual(solo.rowTitle, "Build files")
        XCTAssertEqual(solo.rowIconSource, UnitIconSource.category)

        let several = group([("a", "/Users/tester/a"), ("b", "/Users/tester/b")])
        XCTAssertEqual(several.rowTitle, GrowthCategory.developer.displayName)
        XCTAssertNil(several.rowIconSource)

        let pathless = group([("somewhere", nil)])
        XCTAssertEqual(pathless.rowTitle, GrowthCategory.developer.displayName)
        XCTAssertNil(pathless.rowIconSource)
    }

    func testThePagerKeepsTheRetainedPageMountedBehindTheShownOne() {
        struct Page: Identifiable, Equatable { let id: String }
        let feed = Page(id: "feed")
        let group = Page(id: "group")
        let place = Page(id: "place")
        XCTAssertEqual(PushSlide.mountedPages(retained: feed, outgoing: nil, shown: feed), [feed])
        XCTAssertEqual(PushSlide.mountedPages(retained: feed, outgoing: feed, shown: group), [feed, group])
        XCTAssertEqual(PushSlide.mountedPages(retained: feed, outgoing: nil, shown: place), [feed, place])
        XCTAssertEqual(PushSlide.mountedPages(retained: feed, outgoing: group, shown: place), [feed, group, place])
        XCTAssertEqual(PushSlide.mountedPages(retained: nil, outgoing: group, shown: place), [group, place])
    }

    // MARK: - Signs and the storage balance

    func testRowAmountsReadWithSigns() {
        XCTAssertEqual(signedBytes(9 * Self.gb), "+\(formattedBytes(9 * Self.gb))")
        XCTAssertEqual(signedBytes(-4 * Self.gb), "\u{2212}\(formattedBytes(4 * Self.gb))")
        XCTAssertEqual(signedBytes(300 * Self.mb), "+\(formattedBytes(300 * Self.mb))")
        XCTAssertEqual(spokenChangeAmount(-4 * Self.gb), "down \(formattedBytes(4 * Self.gb))")
    }

    func testUsedOfCapacityUsesTheCapacitysUnit() {
        XCTAssertEqual(StorageBalance.usedOfCapacity(1_730 * Self.gb, 2_000 * Self.gb), "1.73 of 2 TB")
        XCTAssertEqual(StorageBalance.usedOfCapacity(1_981 * Self.gb, 2_000 * Self.gb), "1.98 of 2 TB")
        XCTAssertEqual(StorageBalance.usedOfCapacity(312 * Self.gb, 500 * Self.gb), "312 of 500 GB")
        XCTAssertEqual(StorageBalance.usedOfCapacity(45_300 * Self.mb, 64 * Self.gb), "45.3 of 64 GB")
    }

    private static let capacity: Int64 = 2_000 * gb

    private func history(_ utc: Calendar) -> StorageHistory {
        StorageHistory(records: [
            FreeSpaceRecord(recordedAt: date(2026, 10, 5, 9, 0, in: utc), freeBytes: 400 * Self.gb),
            FreeSpaceRecord(recordedAt: date(2026, 10, 5, 22, 0, in: utc), freeBytes: 320 * Self.gb),
            FreeSpaceRecord(recordedAt: date(2026, 10, 7, 10, 0, in: utc), freeBytes: 300 * Self.gb)
        ])
    }

    func testUsedStorageAtEndOfADayReadsThatDaysLastSnapshot() throws {
        let utc = calendar()
        let storage = try XCTUnwrap(history(utc).usedStorage(
            atEndOf: date(2026, 10, 5, 0, 0, in: utc), capacityBytes: Self.capacity, calendar: utc
        ))
        XCTAssertEqual(storage.usedBytes, 1_680 * Self.gb)
        XCTAssertEqual(storage.recordedAt, date(2026, 10, 5, 22, 0, in: utc))
        XCTAssertTrue(storage.isFromThatDay)
    }

    func testDayWithoutSnapshotKeepsTheNearestOlderOneAndSaysSo() throws {
        let utc = calendar()
        let monday = date(2026, 10, 6, 0, 0, in: utc)
        let storage = try XCTUnwrap(history(utc).usedStorage(atEndOf: monday, capacityBytes: Self.capacity, calendar: utc))
        XCTAssertEqual(storage.usedBytes, 1_680 * Self.gb)
        XCTAssertFalse(storage.isFromThatDay)

        let balance = StorageBalance.recorded(day: monday, storage: storage, capacityBytes: Self.capacity)
        XCTAssertEqual(balance.amountText, "~1.68 of 2 TB")
        XCTAssertEqual(balance.olderRecordNote(calendar: utc), "Last recorded Mon 5 Oct")
        XCTAssertEqual(balance.historicUsedBytes, 1_680 * Self.gb)
    }

    func testDayBeforeTheFirstSnapshotHasNoValue() {
        let utc = calendar()
        let day = date(2026, 10, 4, 0, 0, in: utc)
        XCTAssertNil(history(utc).usedStorage(atEndOf: day, capacityBytes: Self.capacity, calendar: utc))
        XCTAssertNil(StorageHistory.empty.usedStorage(atEndOf: day, capacityBytes: Self.capacity, calendar: utc))

        let balance = StorageBalance.recorded(day: day, storage: nil, capacityBytes: Self.capacity)
        XCTAssertEqual(balance.amountText, "\u{2014}")
        XCTAssertNil(balance.historicUsedBytes)
        XCTAssertEqual(balance.title(calendar: utc), "Sun 4 Oct")
    }

    func testHeaderShowsNowAtTheTopAndTheRecordedDateWhileScrolled() {
        let utc = calendar()
        let now = date(2026, 10, 11, 15, 0, in: utc)
        let feed = build([
            slot(Self.iso, at: date(2026, 10, 11, 9, 0, in: utc), net: 3 * Self.gb),
            slot(Self.project, at: date(2026, 10, 5, 10, 0, in: utc), net: 2 * Self.gb, category: "developer")
        ], now: now, calendar: utc)
        let used = 1_730 * Self.gb
        func balance(_ anchor: Date?) -> StorageBalance {
            StorageBalance.make(
                scrollAnchor: anchor, feed: feed, history: history(utc),
                usedBytes: used, capacityBytes: Self.capacity, now: now, calendar: utc
            )
        }

        let top = StorageBalance.current(usedBytes: used, capacityBytes: Self.capacity)
        XCTAssertEqual(balance(nil), top)
        XCTAssertEqual(balance(utc.startOfDay(for: now)), top)
        XCTAssertEqual(top.title(calendar: utc), "Used")
        XCTAssertEqual(top.amountText, "1.73 of 2 TB")
        XCTAssertFalse(top.isScrolled)
        XCTAssertNil(top.historicUsedBytes)

        let monday = date(2026, 10, 5, 0, 0, in: utc)
        let scrolled = balance(monday)
        XCTAssertTrue(scrolled.isScrolled)
        XCTAssertEqual(scrolled.title(calendar: utc), "Mon 5 Oct")
        XCTAssertEqual(scrolled.amountText, "1.68 of 2 TB")
        XCTAssertNil(scrolled.olderRecordNote(calendar: utc))

        XCTAssertEqual(balance(date(2026, 10, 3, 0, 0, in: utc)), top)
    }

    func testQuietLineIsTheTopWhenThisWeekHasNoRow() {
        let utc = calendar()
        let now = date(2026, 10, 11, 15, 0, in: utc)
        let feed = build([slot(Self.iso, at: date(2026, 10, 2, 9, 0, in: utc), net: 3 * Self.gb)], now: now, calendar: utc)
        let friday = date(2026, 10, 2, 0, 0, in: utc)
        XCTAssertEqual(ChangeFeedRows.topAnchor(for: feed, now: now, calendar: utc), ChangeFeedRows.quietLineID)

        let atQuietLine = StorageBalance.make(
            scrollAnchor: ChangeFeedRows.quietLineID, feed: feed, history: history(utc),
            usedBytes: 1, capacityBytes: Self.capacity, now: now, calendar: utc
        )
        XCTAssertFalse(atQuietLine.isScrolled)

        let atFirstDay = StorageBalance.make(
            scrollAnchor: friday, feed: feed, history: nil,
            usedBytes: 1, capacityBytes: Self.capacity, now: now, calendar: utc
        )
        XCTAssertTrue(atFirstDay.isScrolled)
        XCTAssertEqual(atFirstDay.amountText, "\u{2014}")
    }

    // MARK: - Estimated history

    func testOnlyFileHistoryRowsAreAllEstimated() {
        let utc = calendar()
        let now = date(2026, 10, 20, 12, 0, in: utc)
        let slots = [
            slot(Self.iso, at: date(2026, 10, 10, 9, 0, in: utc), net: 3 * Self.gb, source: .files),
            slot(Self.project, at: date(2026, 10, 12, 9, 0, in: utc), net: 2 * Self.gb, source: .files)
        ]

        let feed = build(slots, now: now, calendar: utc, watchingSince: now)

        XCTAssertTrue(feed.hasEstimatedRows)
        XCTAssertTrue(feed.measuredDays.isEmpty)
        XCTAssertEqual(feed.estimatedDays, feed.days)
        XCTAssertEqual(feed.quietLineSince(now: now, calendar: utc), EpisodeBuilder.windowStart(now: now, calendar: utc))
    }

    func testMeasuredTodayStaysAboveEstimatedOlderDays() {
        let utc = calendar()
        let now = date(2026, 10, 20, 12, 0, in: utc)
        let slots = [
            slot(Self.iso, at: date(2026, 10, 10, 9, 0, in: utc), net: 3 * Self.gb, source: .files),
            slot(Self.project, at: date(2026, 10, 20, 9, 0, in: utc), net: 2 * Self.gb, source: .watch)
        ]

        let feed = build(slots, now: now, calendar: utc, watchingSince: date(2026, 10, 20, 8, 0, in: utc))

        XCTAssertTrue(feed.hasEstimatedRows)
        XCTAssertEqual(feed.measuredDays.map(\.day), [date(2026, 10, 20, 0, 0, in: utc)])
        XCTAssertEqual(feed.estimatedDays.map(\.day), [date(2026, 10, 10, 0, 0, in: utc)])
        XCTAssertEqual(feed.measuredDays.flatMap(\.episodes).map(\.isEstimated), [false])
        XCTAssertEqual(feed.estimatedDays.flatMap(\.episodes).map(\.isEstimated), [true])
        XCTAssertNil(feed.quietLineSince(now: now, calendar: utc))
    }

    func testDayMixingBothSourcesShowsEachRowInOneSectionOnly() {
        let utc = calendar()
        let now = date(2026, 10, 20, 18, 0, in: utc)
        let slots = [
            slot(Self.iso, at: date(2026, 10, 20, 7, 0, in: utc), net: 3 * Self.gb, source: .files),
            slot(Self.project, at: date(2026, 10, 20, 15, 0, in: utc), net: 2 * Self.gb, source: .watch)
        ]

        let feed = build(slots, now: now, calendar: utc, watchingSince: date(2026, 10, 20, 12, 0, in: utc))
        let measured = feed.measuredDays.flatMap(\.episodes).map(\.id)
        let estimated = feed.estimatedDays.flatMap(\.episodes).map(\.id)

        XCTAssertEqual(measured.count, 1)
        XCTAssertEqual(estimated.count, 1)
        XCTAssertTrue(Set(measured).isDisjoint(with: estimated))
        XCTAssertEqual(Set(measured + estimated), Set(feed.episodes.map(\.id)))
    }

    func testEstimatedOnlyMeasuredQuietLineIgnoresEstimatedRowThisWeek() {
        let utc = calendar()
        let now = date(2026, 10, 20, 12, 0, in: utc)
        let slots = [slot(Self.iso, at: date(2026, 10, 19, 9, 0, in: utc), net: 3 * Self.gb, source: .files)]

        let feed = build(slots, now: now, calendar: utc, watchingSince: now)

        XCTAssertNil(feed.quietSince(now: now, calendar: utc))
        XCTAssertNotNil(feed.quietLineSince(now: now, calendar: utc))
    }

    func testNoFileHistoryMeansNoSections() {
        let utc = calendar()
        let now = date(2026, 10, 20, 12, 0, in: utc)
        let slots = [
            slot(Self.iso, at: date(2026, 10, 18, 9, 0, in: utc), net: 3 * Self.gb, source: .watch),
            slot(Self.project, at: date(2026, 10, 19, 9, 0, in: utc), net: 2 * Self.gb, source: .scan)
        ]

        let feed = build(slots, now: now, calendar: utc, watchingSince: date(2026, 10, 1, 0, 0, in: utc))

        XCTAssertFalse(feed.hasFileHistory)
        XCTAssertFalse(feed.hasEstimatedRows)
        XCTAssertEqual(feed.quietLineSince(now: now, calendar: utc), feed.quietSince(now: now, calendar: utc))
        XCTAssertFalse(feed.episodes.contains(where: \.isEstimated))
    }

    func testEstimatedDaysOutsideTheWindowLeaveNoSections() {
        let utc = calendar()
        let now = date(2026, 12, 20, 12, 0, in: utc)
        let slots = [
            slot(Self.iso, at: date(2026, 10, 10, 9, 0, in: utc), net: 3 * Self.gb, source: .files),
            slot(Self.project, at: date(2026, 12, 19, 9, 0, in: utc), net: 2 * Self.gb, source: .watch)
        ]

        let feed = build(slots, now: now, calendar: utc, watchingSince: date(2026, 10, 10, 12, 0, in: utc))

        XCTAssertFalse(feed.hasFileHistory)
        XCTAssertFalse(feed.hasEstimatedRows)
    }
}
