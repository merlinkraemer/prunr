import Foundation
import OSLog

actor GrowthJournalService {
    static let shared = GrowthJournalService()

    /// Fixed window the UI reports on: "last 7 days".
    ///
    /// Deliberately decoupled from `categoryHistoryRetentionDays`. Retention
    /// governs pruning only; changing it must never change what the headline
    /// number counts.
    static let displayWindowDays = 7

    /// Whole local days of history the change list reaches back: this week
    /// plus the older weeks below it. Also the floor for journal pruning.
    static let historyWindowDays = 30

    /// Presentation floor. Deltas smaller than this are not *rendered*, but they
    /// remain part of every sum — the floor never drops data from the arithmetic.
    static let presentationFloorBytes: Int64 = 1 * 1024 * 1024

    private let db = DatabaseManager.shared
    private let logger = Logger(subsystem: "com.prunr.app", category: "GrowthJournal")

    private init() {}

    /// Start of "this week": local midnight six days before `now`, so the week
    /// is today plus the previous six whole days. The change list, the header
    /// and the category rows all read this one window, so they always agree.
    static func weekStart(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(displayWindowDays - 1), to: today) ?? today
    }

    /// Start of the oldest day the change list shows: local midnight
    /// `historyWindowDays - 1` days before `now`.
    static func historyStart(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(historyWindowDays - 1), to: today) ?? today
    }

    func recordDeltas(
        trackedPath: TrackedPath,
        deltas: [DatabaseManager.JournalDeltaKey: Int64],
        at date: Date = Date(),
        source: GrowthJournalBucket.Source = .watch,
        observedSince: Date? = nil
    ) async throws {
        let bucketStart = floorToMinute(date)
        try await db.upsertGrowthJournalBuckets(
            trackedPathId: trackedPath.id,
            bucketStart: bucketStart,
            deltas: deltas,
            source: source,
            observedSince: observedSince
        )
    }

    /// Signed net change per category over the fixed display window.
    func recentGrowthStories(
        trackedPath: TrackedPath,
        now: Date = Date()
    ) async -> [GrowthCategory: RecentGrowthStory] {
        let cutoff = Self.weekStart(now: now)

        do {
            let buckets = try await db.fetchGrowthJournalBuckets(trackedPathId: trackedPath.id, since: cutoff)
            return buildStories(from: buckets)
        } catch {
            logger.error("Failed to fetch recent growth stories: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// The change list across all tracked paths: the journal read as 30-minute
    /// slots, with a row each time a place moved another 1 GB. Runs on this actor,
    /// off the main thread. Throws when history cannot be read.
    ///
    /// `watchingSince` is when the history started. Without it, the oldest
    /// complete snapshot of these paths is used.
    func changeFeed(
        trackedPaths: [TrackedPath],
        now: Date = Date(),
        calendar: Calendar = .current,
        watchingSince: Date? = nil
    ) async throws -> ChangeFeed {
        let ids = trackedPaths.map(\.id)
        let since = EpisodeBuilder.windowStart(now: now, calendar: calendar)
        let slots = try await db.fetchJournalSlots(trackedPathIds: ids, since: since)
        let start: Date?
        if let watchingSince {
            start = watchingSince
        } else {
            start = try await db.fetchOldestCompleteSnapshotDate(trackedPathIds: ids)
        }
        return EpisodeBuilder.build(slots: slots, now: now, calendar: calendar, watchingSince: start)
    }

    /// The oldest complete snapshot of these paths, for `HistoryStart`.
    func oldestCompleteSnapshotDate(trackedPaths: [TrackedPath]) async throws -> Date? {
        try await db.fetchOldestCompleteSnapshotDate(trackedPathIds: trackedPaths.map(\.id))
    }

    func deltasSinceLastSnapshot(
        trackedPath: TrackedPath,
        since snapshotDate: Date
    ) async -> [GrowthCategory: Int64] {
        do {
            return try await db.fetchGrowthJournalTotalsByCategory(
                trackedPathId: trackedPath.id,
                since: snapshotDate
            )
        } catch {
            logger.error("Failed to fetch deltas since last snapshot: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// Signed subcategory totals over the same window the category rows use, so
    /// a drilldown decomposes the row above it rather than reading a second clock.
    func subcategoryGrowthTotals(
        trackedPath: TrackedPath,
        category: GrowthCategory,
        now: Date = Date()
    ) async -> [GrowthSubcategory?: Int64] {
        let cutoff = Self.weekStart(now: now)

        do {
            return try await db.fetchGrowthJournalTotalsBySubcategory(
                trackedPathId: trackedPath.id,
                category: category,
                since: cutoff
            )
        } catch {
            logger.error("Failed to fetch subcategory growth totals: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// Deletes buckets older than the retention window, counted in whole local
    /// days like the change list.
    ///
    /// Clamped to at least `historyWindowDays` — pruning inside the shown
    /// history would silently shrink the on-screen numbers with no filesystem
    /// activity, which is the decay bug this design exists to remove.
    func prune(retentionDays: Int, now: Date = Date(), calendar: Calendar = .current) async {
        let clampedDays = max(retentionDays, Self.historyWindowDays)
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -(clampedDays - 1), to: today) ?? today

        do {
            try await db.pruneGrowthJournalBuckets(olderThan: cutoff)
        } catch {
            logger.error("Failed to prune growth journal: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Builds one signed net-change story per category from the buckets in the
    /// display window.
    ///
    /// The write path already stores signed deltas and nets within a bucket
    /// (`DatabaseManager.upsertGrowthJournalBuckets`), so summing them here is
    /// the true net change: a category that grew 8 GB and was then cleared nets
    /// to zero and produces no story.
    ///
    /// `presentationFloorBytes` is *not* applied here — sub-floor categories
    /// still get a story so they remain part of the header sum. Hiding the
    /// delta line is the view's decision.
    private func buildStories(
        from buckets: [GrowthJournalBucket]
    ) -> [GrowthCategory: RecentGrowthStory] {
        let grouped = Dictionary(grouping: buckets) { $0.category }
        var result: [GrowthCategory: RecentGrowthStory] = [:]

        for (rawCategory, categoryBuckets) in grouped {
            guard let category = GrowthCategory(rawValue: rawCategory) else { continue }
            let sorted = categoryBuckets.sorted { $0.bucketStart < $1.bucketStart }

            guard let first = sorted.first, let last = sorted.last else { continue }

            let total = sorted.reduce(Int64(0)) { $0 + $1.deltaBytes }
            guard total != 0 else { continue }

            result[category] = RecentGrowthStory(
                category: category,
                subcategory: nil,
                deltaBytes: total,
                startedAt: first.bucketStart,
                endedAt: last.bucketStart
            )
        }

        return result
    }

    private func floorToMinute(_ date: Date) -> Date {
        let timeInterval = date.timeIntervalSinceReferenceDate
        let floored = floor(timeInterval / 60.0) * 60.0
        return Date(timeIntervalSinceReferenceDate: floored)
    }
}

/// When the change history started ("Watching since 3 Oct").
///
/// Taken from the first complete snapshot, and remembered: snapshot cleanup
/// deletes snapshots past the retention window, which would otherwise move the
/// start forward and claim a short history after 30 days of watching.
enum HistoryStart {
    static let defaultsKey = "changeHistoryStartedAt"
    static let testSuiteName = "com.prunr.tests.history-start"

    /// Where the start is kept. Unit tests run inside the app against
    /// temporary databases, so under XCTest this is a throwaway suite, emptied
    /// at launch: a test must never move the owner's real "Watching since".
    static let store: UserDefaults = {
        let environment = ProcessInfo.processInfo.environment
        let isTestRun = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
        guard isTestRun, let suite = UserDefaults(suiteName: testSuiteName) else { return .standard }
        suite.removePersistentDomain(forName: testSuiteName)
        return suite
    }()

    /// The earlier of the remembered start and `oldestSnapshot`, remembered for
    /// next time. Nil when neither is known.
    static func remember(oldestSnapshot: Date?, defaults: UserDefaults = HistoryStart.store) -> Date? {
        let stored = defaults.object(forKey: defaultsKey) as? Date
        guard let start = [stored, oldestSnapshot].compactMap({ $0 }).min() else { return nil }
        if start != stored {
            defaults.set(start, forKey: defaultsKey)
        }
        return start
    }

    /// Forgets the start; called when the baseline is reset and history
    /// starts over.
    static func reset(defaults: UserDefaults = HistoryStart.store) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
