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
        XCTAssertEqual(GrowthJournalService.weekStart(now: now, calendar: berlin), date(2026, 3, 24, 0, 0, in: berlin))
        XCTAssertEqual(EpisodeBuilder.windowStart(now: now, calendar: berlin), date(2026, 3, 1, 0, 0, in: berlin))
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

    func testWeekStartIsMidnightSixDaysBackAndHistoryTwentyNine() {
        let utc = calendar()
        let now = date(2026, 10, 11, 9, 30, in: utc)
        XCTAssertEqual(GrowthJournalService.weekStart(now: now, calendar: utc), date(2026, 10, 5, 0, 0, in: utc))
        XCTAssertEqual(GrowthJournalService.historyStart(now: now, calendar: utc), date(2026, 9, 12, 0, 0, in: utc))
        XCTAssertEqual(EpisodeBuilder.windowStart(now: now, calendar: utc), GrowthJournalService.historyStart(now: now, calendar: utc))
    }

    /// The header equals this week's rows plus its "smaller changes" row,
    /// signed: growth minus what was given back.
    func testWeeklyChangeIsTheSignedSumOfTheWeeksRowsAndTail() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 15, 0, in: utc)
        let feed = build([
            slot(Self.iso, at: date(2026, 10, 11, 14, 20, in: utc), net: 50 * Self.gb),
            slot(Self.project, at: date(2026, 10, 7, 10, 0, in: utc), net: -2 * Self.gb, category: "developer"),
            slot(Self.project, at: date(2026, 10, 5, 0, 10, in: utc), net: 300 * Self.mb, category: "developer"),
            // Last week: not part of the header.
            slot(Self.project, at: date(2026, 10, 2, 9, 0, in: utc), net: 7 * Self.gb, category: "developer")
        ], now: now, calendar: utc)

        let expected = 48 * Self.gb + 300 * Self.mb
        let weekly = WeeklyChange(.loaded(feed), now: now)
        XCTAssertEqual(weekly, .bytes(expected))
        XCTAssertEqual(weekly.amountText, "+\(formattedBytes(expected))")

        let week = try XCTUnwrap(feed.thisWeek)
        XCTAssertEqual(week.rows.map(\.netBytes), [50 * Self.gb, -2 * Self.gb])
        XCTAssertEqual(week.smaller.map(\.netBytes), [300 * Self.mb])
        XCTAssertEqual(week.rows.reduce(Int64(0)) { $0 + $1.netBytes } + week.smallerNetBytes, expected)
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

    /// A real zero, once history exists, is "no change this week", never "0 MB".
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

    // MARK: - Adaptive cutoff

    func testCutoffFormulaClampsToFloorAndCeiling() {
        XCTAssertEqual(EpisodeBuilder.Cutoff.threshold(grossBytes: 0), 250 * Self.mb)
        XCTAssertEqual(EpisodeBuilder.Cutoff.threshold(grossBytes: 1 * Self.gb), 250 * Self.mb)
        XCTAssertEqual(EpisodeBuilder.Cutoff.threshold(grossBytes: 50 * Self.gb), 1 * Self.gb)
        XCTAssertEqual(EpisodeBuilder.Cutoff.threshold(grossBytes: 500 * Self.gb), 2 * Self.gb)
        XCTAssertEqual(EpisodeBuilder.Cutoff.maxRowsPerDay, 5)
    }

    func testLowActivityWeekUsesTheFloor() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot("place|/Users/tester/a", at: date(2026, 10, 11, 9, 0, in: utc), net: 300 * Self.mb),
            slot("place|/Users/tester/b", at: date(2026, 10, 10, 9, 0, in: utc), net: 250 * Self.mb),
            slot("place|/Users/tester/c", at: date(2026, 10, 9, 9, 0, in: utc), net: 250 * Self.mb - 1)
        ], now: now, calendar: utc)

        let week = try XCTUnwrap(feed.thisWeek)
        XCTAssertEqual(week.cutoffBytes, 250 * Self.mb)
        XCTAssertEqual(week.rows.map(\.netBytes), [300 * Self.mb, 250 * Self.mb])
        XCTAssertEqual(week.smaller.map(\.netBytes), [250 * Self.mb - 1])
    }

    func testBusyWeekUsesTheCeiling() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot("place|/Users/tester/a", at: date(2026, 10, 11, 9, 0, in: utc), net: 200 * Self.gb),
            slot("place|/Users/tester/b", at: date(2026, 10, 10, 9, 0, in: utc), net: 2 * Self.gb),
            slot("place|/Users/tester/c", at: date(2026, 10, 9, 9, 0, in: utc), net: 2 * Self.gb - 1)
        ], now: now, calendar: utc)

        let week = try XCTUnwrap(feed.thisWeek)
        XCTAssertEqual(week.cutoffBytes, 2 * Self.gb)
        XCTAssertEqual(week.rows.map(\.netBytes), [200 * Self.gb, 2 * Self.gb])
        XCTAssertEqual(week.smaller.map(\.netBytes), [2 * Self.gb - 1])
    }

    /// 50 GB moved: the cutoff is exactly 1 GB. At the line is a row, one
    /// byte below goes to the tail.
    func testMidWeekCutoffIsExactlyTwoPercent() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot("place|/Users/tester/at", at: date(2026, 10, 11, 9, 0, in: utc), net: 1 * Self.gb),
            slot("place|/Users/tester/below", at: date(2026, 10, 10, 9, 0, in: utc), net: 1 * Self.gb - 1),
            // Churn: bytes that came and went, net zero.
            slot("place|/Users/tester/churn", at: date(2026, 10, 9, 9, 0, in: utc), net: 0, gross: 48 * Self.gb + 1)
        ], now: now, calendar: utc)

        let week = try XCTUnwrap(feed.thisWeek)
        XCTAssertEqual(week.grossBytes, 50 * Self.gb)
        XCTAssertEqual(week.cutoffBytes, 1 * Self.gb)
        XCTAssertEqual(week.rows.map(\.netBytes), [1 * Self.gb])
        XCTAssertEqual(week.smaller.map(\.netBytes), [1 * Self.gb - 1])
    }

    func testSixthChangeOfADayGoesToTheTail() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        var slots = (1...6).map { index in
            slot("place|/Users/tester/p\(index)", at: date(2026, 10, 11, 8 + index, 0, in: utc), net: Int64(index) * Self.gb)
        }
        slots.append(slot("place|/Users/tester/other", at: date(2026, 10, 10, 9, 0, in: utc), net: 1 * Self.gb))
        let feed = build(slots, now: now, calendar: utc)

        let week = try XCTUnwrap(feed.thisWeek)
        let today = try XCTUnwrap(week.days.first)
        XCTAssertEqual(today.episodes.count, 5)
        XCTAssertEqual(Set(today.episodes.map(\.netBytes)), Set((2...6).map { Int64($0) * Self.gb }))
        XCTAssertEqual(week.days.last?.episodes.map(\.netBytes), [1 * Self.gb], "the cap is per day")
        XCTAssertEqual(week.smaller.map(\.netBytes), [1 * Self.gb])
        XCTAssertEqual(week.smaller.first?.day, utc.startOfDay(for: now))
    }

    /// Rows plus the tail equal the week's net for every week, including a
    /// week with only shrinks and weeks with nothing.
    func testRowsPlusTailEqualTheWeekForEveryWeek() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let fixture: [(Int, Int, Int64)] = [
            // (month, day, net)
            (10, 11, 3 * Self.gb), (10, 11, 120 * Self.mb), (10, 9, -40 * Self.mb), (10, 6, 900 * Self.mb),
            // Last week: only shrinks.
            (10, 3, -5 * Self.gb), (10, 2, -200 * Self.mb), (9, 29, -60 * Self.mb),
            (9, 25, 1 * Self.gb), (9, 22, -1 * Self.gb + 7), (9, 13, 400 * Self.mb), (9, 12, -10 * Self.mb)
        ]
        let slots = fixture.enumerated().map { index, item in
            slot("place|/Users/tester/u\(index)", at: date(2026, item.0, item.1, 10, 0, in: utc), net: item.2)
        }
        let feed = build(slots, now: now, calendar: utc)

        XCTAssertEqual(feed.weeks.count, 5)
        let expectedNets: [Int64] = [
            3 * Self.gb + 120 * Self.mb - 40 * Self.mb + 900 * Self.mb,
            -5 * Self.gb - 200 * Self.mb - 60 * Self.mb,
            1 * Self.gb - 1 * Self.gb + 7,
            0,
            400 * Self.mb - 10 * Self.mb
        ]
        XCTAssertEqual(feed.weeks.map(\.netBytes), expectedNets)
        for week in feed.weeks {
            let rows = week.rows.reduce(Int64(0)) { $0 + $1.netBytes }
            let smaller = week.smaller.reduce(Int64(0)) { $0 + $1.netBytes }
            XCTAssertEqual(rows + week.smallerNetBytes, week.netBytes, "week \(week.index)")
            XCTAssertEqual(smaller, week.smallerNetBytes, "week \(week.index)")
        }
        XCTAssertEqual(feed.weeks[1].rows.map(\.netBytes), [-5 * Self.gb])
        XCTAssertEqual(feed.weeks[1].smallerNetBytes, -260 * Self.mb)
        XCTAssertTrue(feed.weeks[3].isEmpty)
    }

    // MARK: - Trash

    private static let trash = "trash|/Users/tester/.Trash"

    func testMoveToTrashIsCaptionedAndTrashGrowthIsNoRow() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.project, at: date(2026, 10, 11, 14, 5, in: utc), net: -3 * Self.gb, category: "developer"),
            slot(Self.trash, at: date(2026, 10, 11, 14, 6, in: utc), net: 3 * Self.gb, category: "trash")
        ], now: now, calendar: utc, watchingSince: date(2026, 10, 1, 3, 0, in: utc))

        let week = try XCTUnwrap(feed.thisWeek)
        XCTAssertFalse(week.rows.contains { $0.category == .trash && $0.netBytes > 0 }, "no orange Trash row")
        let source = try XCTUnwrap(week.rows.first)
        XCTAssertEqual(week.rows.count, 1)
        XCTAssertEqual(source.netBytes, -3 * Self.gb)
        XCTAssertTrue(source.isMovedToTrash)
        XCTAssertEqual(EpisodeBuilder.caption(for: source, calendar: utc), "14:05 · moved to Trash")
        XCTAssertEqual(week.smaller.map(\.category), [.trash])
        XCTAssertEqual(week.smallerNetBytes, 3 * Self.gb)
        XCTAssertEqual(week.netBytes, 0, "the sum is unchanged by the move")
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

        let source = try XCTUnwrap(feed.thisWeek?.rows.first { $0.netBytes < 0 })
        XCTAssertEqual(source.netBytes, -3 * Self.gb)
        XCTAssertFalse(source.isMovedToTrash)
    }

    func testEmptyingTheTrashIsAGreyRow() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.trash, at: date(2026, 10, 11, 9, 0, in: utc), net: -4 * Self.gb, category: "trash")
        ], now: now, calendar: utc)

        let row = try XCTUnwrap(feed.thisWeek?.rows.first)
        XCTAssertEqual(row.title, "Trash emptied")
        XCTAssertEqual(row.netBytes, -4 * Self.gb)
        XCTAssertFalse(row.isMovedToTrash)
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

    /// Calm: nothing notable this week, but small changes still reach the
    /// tail and older weeks keep their rows.
    func testCalmWeekKeepsItsTailAndOlderWeeks() throws {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([
            slot(Self.iso, at: date(2026, 10, 10, 12, 0, in: utc), net: 80 * Self.mb),
            slot(Self.project, at: date(2026, 9, 30, 12, 0, in: utc), net: 6 * Self.gb)
        ], now: now, calendar: utc, watchingSince: date(2026, 9, 1, 3, 0, in: utc))

        XCTAssertFalse(feed.isDayOne(now: now))
        let week = try XCTUnwrap(feed.thisWeek)
        XCTAssertTrue(week.days.isEmpty)
        XCTAssertEqual(week.smaller.count, 1)
        XCTAssertEqual(week.smallerNetBytes, 80 * Self.mb)
        XCTAssertEqual(feed.weeks[1].rows.map(\.netBytes), [6 * Self.gb])
        XCTAssertEqual(EpisodeBuilder.dayLabel(for: feed.weeks[1].days[0].day, now: now, calendar: utc), "30 Sep")
        XCTAssertFalse(feed.isShortHistory(now: now, calendar: utc))
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

    func testTailLabels() {
        let utc = calendar()
        let now = date(2026, 10, 11, 20, 0, in: utc)
        let feed = build([], now: now, calendar: utc)
        XCTAssertEqual(feed.weeks.map { EpisodeBuilder.weekSpanLabel(for: $0, calendar: utc) }, [
            "5 \u{2013} 11 Oct", "28 Sep \u{2013} 4 Oct", "21 \u{2013} 27 Sep", "14 \u{2013} 20 Sep", "12 \u{2013} 13 Sep"
        ])
        XCTAssertEqual(EpisodeBuilder.smallerChangesTitle(count: 1), "in 1 smaller change")
        XCTAssertEqual(EpisodeBuilder.smallerChangesTitle(count: 9), "in 9 smaller changes")
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
}
