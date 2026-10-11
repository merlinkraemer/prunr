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

/// One row of the change list: one place's net change on one local day.
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
}

struct ChangeFeedDay: Identifiable, Equatable, Sendable {
    var id: Date { day }
    let day: Date
    /// Newest first.
    let episodes: [ChangeEpisode]
}

/// The change list, newest day first.
struct ChangeFeed: Equatable, Sendable {
    let days: [ChangeFeedDay]

    static let empty = ChangeFeed(days: [])

    var isEmpty: Bool { days.isEmpty }

    /// Net change of the days that start at or after `start`. With
    /// `GrowthJournalService.weekStart` this is the header's "this week".
    func netBytes(since start: Date) -> Int64 {
        days
            .filter { $0.day >= start }
            .reduce(Int64(0)) { total, day in
                day.episodes.reduce(total) { $0 + $1.netBytes }
            }
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
    /// Loading or a read error. Shown as "—", never as zero.
    case unknown
    /// History was read and nothing above the presentation floor moved.
    case none
    case bytes(Int64)

    init(_ result: ChangeFeedResult?, now: Date = Date(), calendar: Calendar = .current) {
        guard let feed = result?.feed else {
            self = .unknown
            return
        }
        let net = feed.netBytes(since: GrowthJournalService.weekStart(now: now, calendar: calendar))
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
            return "\(net > 0 ? "+" : "\u{2212}")\(formattedBytes(abs(net)))"
        }
    }
}

/// Turns journal slots into rows. Pure: no I/O, no database, no actor.
///
/// Rules (docs/core-screen-episodes-prd-2026-10-11.md, "What a row is"):
/// - Slots of one unit form runs; a gap of more than 30 minutes ends a run.
/// - A run belongs to the local day it started, so activity past midnight stays
///   with its start day. All runs of a unit on one day merge into one row.
/// - The amount is the net change; rows that net to zero are dropped.
/// - The time is the slot where most bytes moved. If that slot only holds
///   scan residuals whose window is older than an hour, the time is approximate.
/// - Legacy rows without a unit become one row per (category, subcategory).
enum EpisodeBuilder {
    /// Whole local days the list covers: today plus the previous six.
    static let windowDays = GrowthJournalService.displayWindowDays
    /// A scan residual whose window started more than this before the scan
    /// cannot say when the change happened.
    static let approximateAfter: TimeInterval = 60 * 60
    /// Slot-index difference that still continues a run (one empty slot = a
    /// 30-minute gap, which is not "over 30 minutes").
    private static let maxRunSlotStep: Int64 = 2

    /// Start of the oldest day the list shows, for the SQL read.
    static func windowStart(now: Date, calendar: Calendar) -> Date {
        GrowthJournalService.weekStart(now: now, calendar: calendar)
    }

    static func build(
        slots: [JournalSlot],
        now: Date,
        calendar: Calendar,
        home: String = UnitResolver.defaultHome
    ) -> ChangeFeed {
        let oldestDay = windowStart(now: now, calendar: calendar)
        let byUnit = Dictionary(grouping: slots, by: identity(of:))

        var episodesByDay: [Date: [ChangeEpisode]] = [:]
        for (identity, unitSlots) in byUnit {
            for (day, daySlots) in groupByRunStartDay(unitSlots, calendar: calendar) where day >= oldestDay {
                guard let episode = makeEpisode(
                    identity: identity,
                    day: day,
                    slots: daySlots,
                    home: home
                ) else { continue }
                episodesByDay[day, default: []].append(episode)
            }
        }

        let days = episodesByDay
            .map { day, episodes in
                ChangeFeedDay(day: day, episodes: episodes.sorted(by: newestFirst))
            }
            .sorted { $0.day > $1.day }
        return ChangeFeed(days: days)
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

    /// "14:20 · detail", or "found 03:10 · daily check" for approximate times.
    static func caption(for episode: ChangeEpisode, calendar: Calendar) -> String {
        let clock = formatter("HH:mm", calendar: calendar).string(from: episode.time)
        if episode.isApproximateTime {
            return "found \(clock) · daily check"
        }
        guard let detail = episode.detail, !detail.isEmpty else { return clock }
        return "\(clock) · \(detail)"
    }

    // MARK: - Private

    private static func identity(of slot: JournalSlot) -> String {
        slot.unitKey.isEmpty ? "legacy|\(slot.category)|\(slot.subcategory)" : slot.unitKey
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

        let title: String
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
            isApproximateTime: approximate
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

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = format
        return formatter
    }
}
