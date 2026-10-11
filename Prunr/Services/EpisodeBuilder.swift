import Foundation

/// Journal activity for one (unit, category, subcategory, source) in one
/// 30-minute slot, pre-aggregated in SQL (`DatabaseManager.fetchJournalSlots`).
struct JournalSlot: Sendable, Equatable {
    static let slotSeconds: Int64 = 30 * 60

    /// `UnitResolver` key, or `''` for legacy/coarse rows.
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

/// One place's net change on one local day.
struct ChangeEpisode: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String?
    let category: GrowthCategory
    /// Unit root to reveal in Finder; nil for legacy category-level rows.
    let rootPath: String?
    let netBytes: Int64
    let grossBytes: Int64
    /// Local start of the day the activity started.
    let day: Date
    /// When most of the bytes moved, or when the daily scan found them.
    let time: Date
    /// True when only a daily scan saw the change, so `time` is when it was
    /// found, not when it happened.
    let isApproximateTime: Bool
    /// A shrink whose bytes went to the Trash in the same slots: a move, not
    /// freed space.
    var isMovedToTrash = false
}

struct ChangeFeedDay: Identifiable, Equatable, Sendable {
    var id: Date { day }
    let day: Date
    /// Newest first.
    let episodes: [ChangeEpisode]
}

/// One 7-day stretch of the list: its notable rows by day, and everything
/// else, which the "in N smaller changes" row carries.
struct ChangeFeedWeek: Identifiable, Equatable, Sendable {
    var id: Int { index }
    /// 0 is this week (today and the previous six days), 1 the week before.
    let index: Int
    /// Local midnight of the oldest day in the week.
    let start: Date
    /// Local midnight of the newest day in the week.
    let end: Date
    /// Days with rows, newest first.
    let days: [ChangeFeedDay]
    /// Changes without a row of their own, biggest first.
    let smaller: [ChangeEpisode]
    /// Net change of every slot in the week.
    let netBytes: Int64
    /// Bytes moved in the week; sets the row cutoff.
    let grossBytes: Int64
    /// Smallest |net| that earned a row this week.
    let cutoffBytes: Int64

    var rows: [ChangeEpisode] { days.flatMap(\.episodes) }

    /// The "smaller changes" amount: exactly the week's net minus its rows, so
    /// rows plus this always equal the week.
    var smallerNetBytes: Int64 {
        netBytes - rows.reduce(Int64(0)) { $0 + $1.netBytes }
    }

    var isEmpty: Bool { days.isEmpty && smaller.isEmpty }
}

/// The change list: this week first, then older weeks back to
/// `GrowthJournalService.historyWindowDays`.
struct ChangeFeed: Equatable, Sendable {
    /// Newest first; `weeks.first` is this week.
    let weeks: [ChangeFeedWeek]
    /// When the history started (the first complete snapshot); nil if unknown.
    let watchingSince: Date?

    static let empty = ChangeFeed(weeks: [], watchingSince: nil)

    var thisWeek: ChangeFeedWeek? { weeks.first { $0.index == 0 } }

    /// Days with rows across all weeks, newest first.
    var days: [ChangeFeedDay] { weeks.flatMap(\.days) }

    /// Every change, rows and smaller ones.
    var episodes: [ChangeEpisode] { weeks.flatMap { $0.rows + $0.smaller } }

    var hasRows: Bool { weeks.contains { !$0.days.isEmpty } }

    /// Day one: nothing earned a row yet and watching started under 24 hours
    /// ago (or its start is unknown). There is no history to report yet.
    func isDayOne(now: Date) -> Bool {
        guard !hasRows else { return false }
        guard let watchingSince else { return true }
        return now.timeIntervalSince(watchingSince) < 24 * 60 * 60
    }

    /// True when watching started inside the shown history, so the list ends
    /// with "Watching since 3 Oct".
    func isShortHistory(now: Date, calendar: Calendar) -> Bool {
        guard let watchingSince else { return false }
        return watchingSince >= GrowthJournalService.historyStart(now: now, calendar: calendar)
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
        let net = feed.thisWeek?.netBytes ?? 0
        self = abs(net) < GrowthJournalService.presentationFloorBytes ? .none : .bytes(net)
    }

    /// The amount on the header's right edge: "—", "+48 GB" or "−3 GB".
    /// `.none` has no amount; its line reads "no change this week".
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

/// "+2 GB" or "−3 GB".
func signedBytes(_ bytes: Int64) -> String {
    "\(bytes > 0 ? "+" : "\u{2212}")\(formattedBytes(abs(bytes)))"
}

/// Turns journal slots into rows. Pure: no I/O, no database, no actor.
///
/// Rules (docs/core-screen-episodes-prd-2026-10-11.md, "What a row is"):
/// - Slots of one unit form runs; a gap of more than 30 minutes ends a run.
/// - A run belongs to the local day it started, so activity past midnight stays
///   with its start day. All runs of a unit on one day merge into one change.
/// - The amount is the net change; changes that net to zero are dropped.
/// - The time is the slot where most bytes moved. If that slot only holds
///   scan residuals whose window is older than an hour, the time is approximate.
/// - Legacy rows without a unit become one change per (category, subcategory).
///
/// Which changes get a row ("Which changes get their own row"):
/// - Per week, a change needs |net| ≥ `Cutoff.threshold(grossBytes:)`.
/// - At most `Cutoff.maxRowsPerDay` rows per day, biggest first.
/// - Trash growth never gets a row: moving to the Trash frees nothing.
/// - Everything else is the week's "smaller changes".
enum EpisodeBuilder {
    /// The adaptive row cutoff. First values, to tune with the owner.
    enum Cutoff {
        /// Share of the week's moved bytes, in percent.
        static let percentOfWeekGross: Int64 = 2
        static let floorBytes: Int64 = 250_000_000
        static let ceilingBytes: Int64 = 2_000_000_000
        static let maxRowsPerDay = 5

        /// clamp(2% × gross, 250 MB, 2 GB).
        static func threshold(grossBytes: Int64) -> Int64 {
            min(max(grossBytes * percentOfWeekGross / 100, floorBytes), ceilingBytes)
        }
    }

    /// Whole local days the list covers.
    static let historyDays = GrowthJournalService.historyWindowDays
    static let weekDays = GrowthJournalService.displayWindowDays
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
        let today = calendar.startOfDay(for: now)
        let oldestDay = windowStart(now: now, calendar: calendar)
        let byUnit = Dictionary(grouping: slots, by: identity(of:))
        let trashGrowth = trashGrowthBySlot(slots)

        let weekCount = (historyDays + weekDays - 1) / weekDays
        var netByWeek = [Int64](repeating: 0, count: weekCount)
        var grossByWeek = [Int64](repeating: 0, count: weekCount)
        var episodesByWeek = [[ChangeEpisode]](repeating: [], count: weekCount)

        for (identity, unitSlots) in byUnit {
            for (day, daySlots) in groupByRunStartDay(unitSlots, calendar: calendar) where day >= oldestDay {
                let daysAgo = max(0, calendar.dateComponents([.day], from: day, to: today).day ?? 0)
                let week = min(daysAgo / weekDays, weekCount - 1)
                netByWeek[week] += daySlots.reduce(Int64(0)) { $0 + $1.netBytes }
                grossByWeek[week] += daySlots.reduce(Int64(0)) { $0 + $1.grossBytes }
                guard let episode = makeEpisode(
                    identity: identity,
                    day: day,
                    slots: daySlots,
                    trashGrowth: trashGrowth,
                    home: home
                ) else { continue }
                episodesByWeek[week].append(episode)
            }
        }

        let weeks = (0..<weekCount).map { index -> ChangeFeedWeek in
            let end = calendar.date(byAdding: .day, value: -index * weekDays, to: today) ?? today
            let start = max(
                oldestDay,
                calendar.date(byAdding: .day, value: -(weekDays - 1), to: end) ?? end
            )
            return makeWeek(
                index: index,
                start: start,
                end: end,
                episodes: episodesByWeek[index],
                netBytes: netByWeek[index],
                grossBytes: grossByWeek[index]
            )
        }
        return ChangeFeed(weeks: weeks, watchingSince: watchingSince)
    }

    // MARK: - Labels

    /// "Today", "Yesterday", a weekday name within the last 7 days, then "3 Oct".
    static func dayLabel(for day: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let start = calendar.startOfDay(for: day)
        let daysAgo = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        switch daysAgo {
        case 0:
            return "Today"
        case 1:
            return "Yesterday"
        case 2...6:
            return formatter("EEEE", calendar: calendar).string(from: start)
        default:
            return formatter("d MMM", calendar: calendar).string(from: start)
        }
    }

    /// "14:20 · detail", "14:20 · moved to Trash", or "found 03:10 · daily
    /// check" for approximate times.
    static func caption(for episode: ChangeEpisode, calendar: Calendar) -> String {
        let clock = formatter("HH:mm", calendar: calendar).string(from: episode.time)
        if episode.isApproximateTime {
            return "found \(clock) · daily check"
        }
        if episode.isMovedToTrash {
            return "\(clock) · moved to Trash"
        }
        guard let detail = episode.detail, !detail.isEmpty else { return clock }
        return "\(clock) · \(detail)"
    }

    /// "in 9 smaller changes".
    static func smallerChangesTitle(count: Int) -> String {
        "in \(count) smaller \(count == 1 ? "change" : "changes")"
    }

    /// The week's days: "5 – 11 Oct", "28 Sep – 4 Oct", or "3 Oct" for a
    /// one-day stretch.
    static func weekSpanLabel(for week: ChangeFeedWeek, calendar: Calendar) -> String {
        let dayMonth = formatter("d MMM", calendar: calendar)
        guard !calendar.isDate(week.start, inSameDayAs: week.end) else {
            return dayMonth.string(from: week.end)
        }
        let sameMonth = calendar.isDate(week.start, equalTo: week.end, toGranularity: .month)
        let first = sameMonth ? formatter("d", calendar: calendar).string(from: week.start) : dayMonth.string(from: week.start)
        return "\(first) \u{2013} \(dayMonth.string(from: week.end))"
    }

    /// "Watching since 3 Oct".
    static func watchingSinceLabel(_ date: Date, calendar: Calendar) -> String {
        "Watching since \(formatter("d MMM", calendar: calendar).string(from: date))"
    }

    // MARK: - Private

    private static func identity(of slot: JournalSlot) -> String {
        slot.unitKey.isEmpty ? "legacy|\(slot.category)|\(slot.subcategory)" : slot.unitKey
    }

    private static func isTrash(_ slot: JournalSlot) -> Bool {
        if let key = UnitKey(rawValue: slot.unitKey) {
            return key.kind == .trash
        }
        return slot.category == GrowthCategory.trash.rawValue
    }

    /// How much the Trash grew in each slot.
    private static func trashGrowthBySlot(_ slots: [JournalSlot]) -> [Int64: Int64] {
        var growth: [Int64: Int64] = [:]
        for slot in slots where isTrash(slot) {
            growth[slot.slot, default: 0] += slot.netBytes
        }
        return growth.filter { $0.value > 0 }
    }

    /// Picks the week's rows: above the cutoff, not Trash growth, and at most
    /// `maxRowsPerDay` per day, biggest first. The rest is "smaller changes".
    private static func makeWeek(
        index: Int,
        start: Date,
        end: Date,
        episodes: [ChangeEpisode],
        netBytes: Int64,
        grossBytes: Int64
    ) -> ChangeFeedWeek {
        let cutoff = Cutoff.threshold(grossBytes: grossBytes)
        var rowsByDay: [Date: [ChangeEpisode]] = [:]
        var smaller: [ChangeEpisode] = []

        for (day, dayEpisodes) in Dictionary(grouping: episodes, by: \.day) {
            var rowCount = 0
            for episode in dayEpisodes.sorted(by: biggestFirst) {
                let isTrashGrowth = episode.category == .trash && episode.netBytes > 0
                if !isTrashGrowth, abs(episode.netBytes) >= cutoff, rowCount < Cutoff.maxRowsPerDay {
                    rowsByDay[day, default: []].append(episode)
                    rowCount += 1
                } else {
                    smaller.append(episode)
                }
            }
        }

        let days = rowsByDay
            .map { day, rows in ChangeFeedDay(day: day, episodes: rows.sorted(by: newestFirst)) }
            .sorted { $0.day > $1.day }
        return ChangeFeedWeek(
            index: index,
            start: start,
            end: end,
            days: days,
            smaller: smaller.sorted(by: biggestFirst),
            netBytes: netBytes,
            grossBytes: grossBytes,
            cutoffBytes: cutoff
        )
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
        slots: [JournalSlot],
        trashGrowth: [Int64: Int64],
        home: String
    ) -> ChangeEpisode? {
        let net = slots.reduce(Int64(0)) { $0 + $1.netBytes }
        guard net != 0, let first = slots.first else { return nil }
        let gross = slots.reduce(Int64(0)) { $0 + $1.grossBytes }

        // Peak: the slot where most bytes moved; ties go to the later slot.
        let bySlot = Dictionary(grouping: slots, by: \.slot)
        let peakIndex = bySlot.max { lhs, rhs in
            let lhsGross = lhs.value.reduce(Int64(0)) { $0 + $1.grossBytes }
            let rhsGross = rhs.value.reduce(Int64(0)) { $0 + $1.grossBytes }
            return lhsGross == rhsGross ? lhs.key < rhs.key : lhsGross < rhsGross
        }?.key ?? first.slot
        let peakSlots = bySlot[peakIndex] ?? [first]
        let time = peakSlots.map(\.firstAt).min() ?? first.firstAt
        let approximate = peakSlots.allSatisfy { isApproximateSlot($0) }

        var title: String
        let detail: String?
        let category: GrowthCategory
        let rootPath: String?
        if first.unitKey.isEmpty {
            category = GrowthCategory(rawValue: first.category) ?? .other
            title = legacyName(category: category, subcategory: GrowthSubcategory(rawValue: first.subcategory))
            detail = nil
            rootPath = nil
        } else {
            let name = UnitNamer.name(forKey: first.unitKey, home: home)
            title = name.title
            detail = name.detail
            category = name.category
            rootPath = UnitKey(rawValue: first.unitKey)?.rootPath
        }

        let isTrashUnit = isTrash(first)
        if isTrashUnit && net < 0 {
            title = "Trash emptied"
        }

        // A shrink whose bytes the Trash took in the same slots is a move.
        var movedToTrash = false
        if net < 0 && !isTrashUnit {
            let trashIn = Set(slots.map(\.slot)).reduce(Int64(0)) { $0 + (trashGrowth[$1] ?? 0) }
            movedToTrash = trashIn * 100 >= -net * trashMovePercent
        }

        return ChangeEpisode(
            id: "\(identity)@\(Int64(day.timeIntervalSince1970))",
            title: title,
            detail: detail,
            category: category,
            rootPath: rootPath,
            netBytes: net,
            grossBytes: gross,
            day: day,
            time: time,
            isApproximateTime: approximate,
            isMovedToTrash: movedToTrash
        )
    }

    private static func isApproximateSlot(_ slot: JournalSlot) -> Bool {
        guard slot.source == .scan else { return false }
        guard let observedSince = slot.observedSince else { return true }
        return slot.firstAt.timeIntervalSince(observedSince) > approximateAfter
    }

    /// Rough names for rows recorded before places existed. Never a bare
    /// category word such as "Other".
    static func legacyName(category: GrowthCategory, subcategory: GrowthSubcategory?) -> String {
        if let subcategory {
            return subcategory.displayName
        }
        switch category {
        case .downloads, .trash:
            return category.displayName
        case .other:
            return "Files in your folders"
        default:
            return "Files in \(category.displayName)"
        }
    }

    private static func newestFirst(_ lhs: ChangeEpisode, _ rhs: ChangeEpisode) -> Bool {
        lhs.time == rhs.time ? lhs.id < rhs.id : lhs.time > rhs.time
    }

    private static func biggestFirst(_ lhs: ChangeEpisode, _ rhs: ChangeEpisode) -> Bool {
        let lhsSize = abs(lhs.netBytes)
        let rhsSize = abs(rhs.netBytes)
        return lhsSize == rhsSize ? lhs.id < rhs.id : lhsSize > rhsSize
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
