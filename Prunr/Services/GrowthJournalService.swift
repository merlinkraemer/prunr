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

    /// Presentation floor. Deltas smaller than this are not *rendered*, but they
    /// remain part of every sum — the floor never drops data from the arithmetic.
    static let presentationFloorBytes: Int64 = 1 * 1024 * 1024

    private let db = DatabaseManager.shared
    private let logger = Logger(subsystem: "com.prunr.app", category: "GrowthJournal")

    private init() {}

    private static var displayWindow: TimeInterval {
        TimeInterval(displayWindowDays) * 24 * 60 * 60
    }

    func recordDeltas(
        trackedPath: TrackedPath,
        deltas: [DatabaseManager.JournalDeltaKey: Int64],
        at date: Date = Date()
    ) async throws {
        let bucketStart = floorToMinute(date)
        try await db.upsertGrowthJournalBuckets(
            trackedPathId: trackedPath.id,
            bucketStart: bucketStart,
            deltas: deltas
        )
    }

    /// Signed net change per category over the fixed display window.
    func recentGrowthStories(
        trackedPath: TrackedPath
    ) async -> [GrowthCategory: RecentGrowthStory] {
        let cutoff = Date().addingTimeInterval(-Self.displayWindow)

        do {
            let buckets = try await db.fetchGrowthJournalBuckets(trackedPathId: trackedPath.id, since: cutoff)
            return buildStories(from: buckets)
        } catch {
            logger.error("Failed to fetch recent growth stories: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
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
        category: GrowthCategory
    ) async -> [GrowthSubcategory?: Int64] {
        let cutoff = Date().addingTimeInterval(-Self.displayWindow)

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

    /// Deletes buckets older than the retention window.
    ///
    /// Clamped to at least `displayWindowDays` — pruning inside the display
    /// window would silently shrink the on-screen number with no filesystem
    /// activity, which is the decay bug this design exists to remove.
    func prune(retentionDays: Int) async {
        let clampedDays = max(retentionDays, Self.displayWindowDays)
        let retentionWindow = TimeInterval(clampedDays) * 24 * 60 * 60
        let cutoff = Date().addingTimeInterval(-retentionWindow)

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
