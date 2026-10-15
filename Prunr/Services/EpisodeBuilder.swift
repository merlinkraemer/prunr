import Foundation

/// Journal activity for one (unit, category, subcategory, source) in one
/// 30-minute slot, pre-aggregated in SQL (`DatabaseManager.fetchJournalSlots`).
struct JournalSlot: Sendable, Equatable {
    static let slotSeconds: Int64 = 30 * 60

    /// `UnitResolver` key.
    let unitKey: String
    let category: String
    let subcategory: String
    let source: GrowthJournalBucket.Source
    /// Slot index: seconds since 1970 divided by `slotSeconds`.
    let slot: Int64
    let netBytes: Int64
    /// Σ|delta| of the buckets in the slot: how many bytes moved.
    let grossBytes: Int64
    /// Earliest bucket (minute) inside the slot.
    let firstAt: Date
    /// For `scan` slots: start of the window the scan reconciled.
    let observedSince: Date?
}

/// One row: a place that gained or lost another 1 GB since its last row.
struct ChangeEpisode: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String?
    let category: GrowthCategory
    /// Unit root to reveal in Finder; nil when the key has no root.
    let rootPath: String?
    /// Everything since the place's last row, up to the end of `day`.
    let netBytes: Int64
    let grossBytes: Int64
    /// Local start of the day the place crossed the line.
    let day: Date
    /// When most of the day's bytes moved, or when the daily scan found them.
    let time: Date
    /// True when only a daily scan saw the change, so `time` is when it was
    /// found, not when it happened.
    let isApproximateTime: Bool
    /// A shrink whose bytes went to the Trash in the same slots: a move, not
    /// freed space.
    var isMovedToTrash = false
    /// Set when the amount built up over several days: the day it started.
    /// The caption then reads "a little each day since Fri 2 Oct".
    var buildingSince: Date?

    /// Where the row's icon comes from.
    var iconSource: UnitIconSource = .category

    /// Orange in the list: growth of at least `largeGrowthBytes`.
    var isLargeGrowth: Bool { EpisodeBuilder.isLargeGrowth(netBytes) }
}

struct ChangeFeedDay: Identifiable, Equatable, Sendable {
    var id: Date { day }
    let day: Date
    /// Newest first.
    let episodes: [ChangeEpisode]

    /// One group per category with rows this day, biggest change first.
    var groups: [ChangeGroup] {
        Dictionary(grouping: episodes, by: \.category)
            .map { ChangeGroup(day: day, category: $0.key, episodes: $0.value) }
            .sorted { lhs, rhs in
                let lhsSize = abs(lhs.netBytes)
                let rhsSize = abs(rhs.netBytes)
                return lhsSize == rhsSize ? lhs.category.rawValue < rhs.category.rawValue : lhsSize > rhsSize
            }
    }
}

/// One category's rows on one day: a main-list row that opens them.
struct ChangeGroup: Identifiable, Equatable, Sendable {
    let day: Date
    let category: GrowthCategory
    /// Newest first.
    let episodes: [ChangeEpisode]

    var id: String { "\(category.rawValue)@\(Int64(day.timeIntervalSince1970))" }

    var netBytes: Int64 { episodes.reduce(Int64(0)) { $0 + $1.netBytes } }

    /// Orange in the list: growth of at least `largeGrowthBytes`.
    var isLargeGrowth: Bool { EpisodeBuilder.isLargeGrowth(netBytes) }
}

/// The change list: every row back to `GrowthJournalService.historyWindowDays`,
/// grouped by day, and this week's measured total for the header.
struct ChangeFeed: Equatable, Sendable {
    /// Days with rows, newest first.
    let days: [ChangeFeedDay]
    /// Net change of everything this week (today and the six days before),
    /// whether it earned a row or not. The header's number.
    let weekNetBytes: Int64
    /// When the history started (the first complete snapshot); nil if unknown.
    let watchingSince: Date?
    /// True when the shown history holds changes rebuilt from file dates, so
    /// it reaches back before `watchingSince`.
    var hasFileHistory = false
    /// The newest change the watcher recorded; nil when it has seen none.
    var lastLiveChangeAt: Date?

    static let empty = ChangeFeed(days: [], weekNetBytes: 0, watchingSince: nil)

    /// Every row, newest day first.
    var episodes: [ChangeEpisode] { days.flatMap(\.episodes) }

    var hasRows: Bool { !days.isEmpty }

    /// Day one: nothing earned a row, nothing was rebuilt from file dates and
    /// watching started under 24 hours ago (or its start is unknown). There is
    /// no history to report yet.
    func isDayOne(now: Date) -> Bool {
        guard !hasRows, !hasFileHistory else { return false }
        guard let watchingSince else { return true }
        return now.timeIntervalSince(watchingSince) < 24 * 60 * 60
    }

    /// True when watching started inside the shown history and nothing older
    /// was rebuilt, so the list ends with "Watching since 3 Oct".
    func isShortHistory(now: Date, calendar: Calendar) -> Bool {
        guard !hasFileHistory, let watchingSince else { return false }
        return watchingSince >= GrowthJournalService.historyStart(now: now, calendar: calendar)
    }

    /// The footer's "Watching since today 16:38": watching started today and
    /// the watcher has not recorded a change yet. The first full scan clears
    /// the journal, so every watcher change is newer than the start.
    func watchingSinceToday(now: Date, calendar: Calendar) -> Date? {
        guard lastLiveChangeAt == nil, let watchingSince,
              calendar.isDate(watchingSince, inSameDayAs: now) else { return nil }
        return watchingSince
    }

    /// The date for "Nothing over 1 GB since 28 Sep". Nil when this week has a
    /// row. Otherwise the newest row's day, or without any row the start of
    /// what the list can see.
    func quietSince(now: Date, calendar: Calendar) -> Date? {
        let weekStart = GrowthJournalService.weekStart(now: now, calendar: calendar)
        if let newest = days.first?.day {
            return newest >= weekStart ? nil : newest
        }
        let historyStart = GrowthJournalService.historyStart(now: now, calendar: calendar)
        guard !hasFileHistory else { return historyStart }
        return max(watchingSince ?? historyStart, historyStart)
    }
}

/// What the last read of the change list produced. `nil` (no read finished
/// yet) is unknown, and so is `.failed`; neither may ever read as zero.
enum ChangeFeedResult: Equatable, Sendable {
    case loaded(ChangeFeed)
    case failed

    var feed: ChangeFeed? {
        if case .loaded(let feed) = self { return feed }
        return nil
    }
}

/// The header's "this week" value: unknown, no change, or a signed amount.
enum WeeklyChange: Equatable, Sendable {
    /// Loading, a read error, or no history yet. Shown as "—", never as zero.
    case unknown
    /// History exists and nothing above the presentation floor moved.
    case none
    case bytes(Int64)

    init(_ result: ChangeFeedResult?, now: Date = Date()) {
        guard let feed = result?.feed, !feed.isDayOne(now: now) else {
            self = .unknown
            return
        }
        let net = feed.weekNetBytes
        self = abs(net) < GrowthJournalService.presentationFloorBytes ? .none : .bytes(net)
    }

    /// The amount on the header's right edge: "—", "+48 GB" or "−3 GB".
    /// `.none` has no amount; the header reads "No change".
    var amountText: String? {
        switch self {
        case .unknown:
            return "\u{2014}"
        case .none:
            return nil
        case .bytes(let net):
            return signedBytes(net)
        }
    }
}

/// Turns journal slots into rows. Pure: no I/O, no database, no actor.
///
/// One rule (docs/core-screen-simple-list-model-2026-10-11.md): a place gets
/// a row each time it has gained or lost another `rowThresholdBytes` since its
/// last row.
/// - Slots of one place form runs; a gap of more than 30 minutes ends a run.
///   A run belongs to the local day it started, so activity past midnight
///   stays with its start day.
/// - Per place, a running count adds each day's net, oldest day first. At the
///   end of a day where |count| reaches the line, that day gets one row with
///   the whole count, and the count starts over. Nothing resets at week ends.
///   A change that came and went within one day therefore has no row.
/// - Caption: the clock time when the count started that day or more than half
///   of it moved in one slot that day; otherwise "a little each day since
///   <start day>". A daily-scan slot with an old window reads "found by scan".
/// - Trash growth is a move and never counts; the Trash only counts shrinks,
///   which read "Trash emptied".
///
/// The count is not stored: every build recomputes it from the shown history,
/// so each place's count starts on the oldest shown day.
enum EpisodeBuilder {
    /// The one row line: 1 GB, decimal like every amount in the app.
    static let rowThresholdBytes: Int64 = 1_000_000_000
    /// Growth from this size on is orange; smaller growth stays primary and
    /// shrinks are grey.
    static let largeGrowthBytes: Int64 = 5_000_000_000

    static func isLargeGrowth(_ netBytes: Int64) -> Bool {
        netBytes >= largeGrowthBytes
    }

    /// A scan residual whose window started more than this before the scan
    /// cannot say when the change happened.
    static let approximateAfter: TimeInterval = 60 * 60
    /// The source counts as moved to the Trash when the Trash grew by at least
    /// this share (percent) of the shrink in the same slots.
    static let trashMovePercent: Int64 = 90
    /// Slot-index difference that still continues a run (one empty slot = a
    /// 30-minute gap, which is not "over 30 minutes").
    private static let maxRunSlotStep: Int64 = 2

    /// Start of the oldest day the list shows, for the SQL read.
    static func windowStart(now: Date, calendar: Calendar) -> Date {
        GrowthJournalService.historyStart(now: now, calendar: calendar)
    }

    static func build(
        slots: [JournalSlot],
        now: Date,
        calendar: Calendar,
        home: String = UnitResolver.defaultHome,
        watchingSince: Date? = nil
    ) -> ChangeFeed {
        let oldestDay = windowStart(now: now, calendar: calendar)
        let weekStart = GrowthJournalService.weekStart(now: now, calendar: calendar)
        let trashGrowth = trashGrowthBySlot(slots)

        var weekNet: Int64 = 0
        var rowsByDay: [Date: [ChangeEpisode]] = [:]

        for (identity, placeSlots) in Dictionary(grouping: slots, by: \.unitKey) {
            let isTrashPlace = placeSlots.contains { isTrash($0) }
            var count: Int64 = 0
            var gross: Int64 = 0
            var countStart: Date?

            let days = groupByRunStartDay(placeSlots, calendar: calendar)
                .filter { $0.key >= oldestDay }
                .sorted { $0.key < $1.key }
            for (day, daySlots) in days {
                let dayNet = daySlots.reduce(Int64(0)) { $0 + $1.netBytes }
                if day >= weekStart {
                    weekNet += dayNet
                }
                let counted = isTrashPlace
                    ? daySlots.reduce(Int64(0)) { $0 + min($1.netBytes, 0) }
                    : dayNet
                guard counted != 0 else { continue }

                if countStart == nil {
                    countStart = day
                }
                count += counted
                gross += daySlots.reduce(Int64(0)) { $0 + $1.grossBytes }
                if count == 0 {
                    countStart = nil
                    gross = 0
                    continue
                }
                guard abs(count) >= rowThresholdBytes, let start = countStart else { continue }

                let episode = makeEpisode(
                    identity: identity,
                    day: day,
                    daySlots: daySlots,
                    netBytes: count,
                    grossBytes: gross,
                    countStart: start,
                    isTrashPlace: isTrashPlace,
                    trashGrowth: trashGrowth,
                    home: home
                )
                rowsByDay[day, default: []].append(episode)
                count = 0
                gross = 0
                countStart = nil
            }
        }

        let days = rowsByDay
            .map { day, rows in ChangeFeedDay(day: day, episodes: rows.sorted(by: newestFirst)) }
            .sorted { $0.day > $1.day }
        let shownSlots = slots.filter { $0.firstAt >= oldestDay }
        return ChangeFeed(
            days: days,
            weekNetBytes: weekNet,
            watchingSince: watchingSince,
            hasFileHistory: shownSlots.contains { $0.source == .files },
            lastLiveChangeAt: shownSlots.filter { $0.source == .watch }.map(\.firstAt).max()
        )
    }

    // MARK: - Labels

    /// The real date, also for today and yesterday: "Wed 7 Oct".
    static func dayLabel(for day: Date, calendar: Calendar) -> String {
        formatter("EEE d MMM", calendar: calendar).string(from: calendar.startOfDay(for: day))
    }

    /// A place row's single title line: "Xcode build files · Prunr".
    static func rowTitle(for episode: ChangeEpisode) -> String {
        guard let detail = episode.detail, !detail.isEmpty else { return episode.title }
        return "\(episode.title) · \(detail)"
    }

    /// "14:20" when the clock time of the change is known; nil when a daily
    /// scan found it or it built up over several days.
    static func timeCaption(for episode: ChangeEpisode, calendar: Calendar) -> String? {
        guard !episode.isApproximateTime, episode.buildingSince == nil else { return nil }
        return formatter("HH:mm", calendar: calendar).string(from: episode.time)
    }

    /// "Nothing over 1 GB since 28 Sep".
    static func quietLabel(since date: Date, calendar: Calendar) -> String {
        "Nothing over 1 GB since \(formatter("d MMM", calendar: calendar).string(from: date))"
    }

    /// "Watching since 3 Oct".
    static func watchingSinceLabel(_ date: Date, calendar: Calendar) -> String {
        "Watching since \(formatter("d MMM", calendar: calendar).string(from: date))"
    }

    // MARK: - Private

    private static func isTrash(_ slot: JournalSlot) -> Bool {
        UnitKey(rawValue: slot.unitKey)?.kind == .trash
    }

    /// How much the Trash grew in each slot.
    private static func trashGrowthBySlot(_ slots: [JournalSlot]) -> [Int64: Int64] {
        var growth: [Int64: Int64] = [:]
        for slot in slots where isTrash(slot) {
            growth[slot.slot, default: 0] += slot.netBytes
        }
        return growth.filter { $0.value > 0 }
    }

    /// Splits a unit's slots into runs and buckets each run under the local day
    /// its first activity happened.
    private static func groupByRunStartDay(
        _ slots: [JournalSlot],
        calendar: Calendar
    ) -> [Date: [JournalSlot]] {
        let sorted = slots.sorted {
            $0.slot == $1.slot ? $0.firstAt < $1.firstAt : $0.slot < $1.slot
        }
        var result: [Date: [JournalSlot]] = [:]
        var run: [JournalSlot] = []

        func closeRun() {
            guard let first = run.first else { return }
            let start = run.map(\.firstAt).min() ?? first.firstAt
            result[calendar.startOfDay(for: start), default: []].append(contentsOf: run)
            run.removeAll()
        }

        for slot in sorted {
            if let last = run.last, slot.slot - last.slot > maxRunSlotStep {
                closeRun()
            }
            run.append(slot)
        }
        closeRun()
        return result
    }

    private static func makeEpisode(
        identity: String,
        day: Date,
        daySlots: [JournalSlot],
        netBytes: Int64,
        grossBytes: Int64,
        countStart: Date,
        isTrashPlace: Bool,
        trashGrowth: [Int64: Int64],
        home: String
    ) -> ChangeEpisode {
        let first = daySlots[0]

        let bySlot = Dictionary(grouping: daySlots, by: \.slot)
        let netOfSlot = bySlot.mapValues { $0.reduce(Int64(0)) { $0 + $1.netBytes } }
        let peakIndex = netOfSlot.max { lhs, rhs in
            abs(lhs.value) == abs(rhs.value) ? lhs.key < rhs.key : abs(lhs.value) < abs(rhs.value)
        }?.key ?? first.slot
        let peakSlots = bySlot[peakIndex] ?? [first]
        let peakNet = netOfSlot[peakIndex] ?? 0
        let time = peakSlots.map(\.firstAt).min() ?? first.firstAt

        let isOneGo = countStart == day || abs(peakNet) * 2 > abs(netBytes)
        let approximate = isOneGo && peakSlots.allSatisfy { isApproximateSlot($0) }

        let name = UnitNamer.name(forKey: first.unitKey, home: home)
        var title = name.standaloneTitle
        let detail = name.context
        let category = name.category
        let rootPath = UnitKey(rawValue: first.unitKey)?.rootPath

        if isTrashPlace {
            title = "Trash emptied"
        }

        var movedToTrash = false
        if netBytes < 0 && !isTrashPlace {
            let trashIn = Set(daySlots.map(\.slot)).reduce(Int64(0)) { $0 + (trashGrowth[$1] ?? 0) }
            movedToTrash = trashIn * 100 >= -netBytes * trashMovePercent
        }

        return ChangeEpisode(
            id: "\(identity)@\(Int64(day.timeIntervalSince1970))",
            title: title,
            detail: detail,
            category: category,
            rootPath: rootPath,
            netBytes: netBytes,
            grossBytes: grossBytes,
            day: day,
            time: time,
            isApproximateTime: approximate,
            isMovedToTrash: movedToTrash,
            buildingSince: isOneGo ? nil : countStart,
            iconSource: name.icon
        )
    }

    private static func isApproximateSlot(_ slot: JournalSlot) -> Bool {
        guard slot.source == .scan else { return false }
        guard let observedSince = slot.observedSince else { return true }
        return slot.firstAt.timeIntervalSince(observedSince) > approximateAfter
    }

    private static func newestFirst(_ lhs: ChangeEpisode, _ rhs: ChangeEpisode) -> Bool {
        lhs.time == rhs.time ? lhs.id < rhs.id : lhs.time > rhs.time
    }

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = format
        return formatter
    }
}
