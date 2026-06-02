import Foundation
import OSLog

actor GrowthJournalService {
    static let shared = GrowthJournalService()

    private let db = DatabaseManager.shared
    private let recentStoryThresholdBytes: Int64 = 1 * 1024 * 1024
    private let logger = Logger(subsystem: "com.prunr.app", category: "GrowthJournal")

    private init() {}

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

    func recentGrowthStories(
        trackedPath: TrackedPath,
        retentionDays: Int
    ) async -> [GrowthCategory: RecentGrowthStory] {
        let retentionWindow = TimeInterval(max(1, retentionDays)) * 24 * 60 * 60
        let cutoff = Date().addingTimeInterval(-retentionWindow)

        do {
            let buckets = try await db.fetchGrowthJournalBuckets(trackedPathId: trackedPath.id, since: cutoff)
            return buildStories(from: buckets, now: Date(), retentionWindow: retentionWindow)
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

    func subcategoryGrowthTotals(
        trackedPath: TrackedPath,
        category: GrowthCategory,
        retentionDays: Int
    ) async -> [GrowthSubcategory?: Int64] {
        let retentionWindow = TimeInterval(max(1, retentionDays)) * 24 * 60 * 60
        let cutoff = Date().addingTimeInterval(-retentionWindow)

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

    func prune(retentionDays: Int) async {
        let retentionWindow = TimeInterval(max(1, retentionDays)) * 24 * 60 * 60
        let cutoff = Date().addingTimeInterval(-retentionWindow)

        do {
            try await db.pruneGrowthJournalBuckets(olderThan: cutoff)
        } catch {
            logger.error("Failed to prune growth journal: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Builds one cumulative growth story per category from the retained journal.
    ///
    /// The journal is cleared on Accept/Reset (`BaselineService.acceptGrowth`),
    /// so every retained bucket represents growth since the current baseline.
    /// Growth is therefore the **sum of all positive deltas** per category —
    /// not a single recent burst — with the time anchor surfaced separately as
    /// the baseline date in the UI.
    private func buildStories(
        from buckets: [GrowthJournalBucket],
        now: Date,
        retentionWindow: TimeInterval
    ) -> [GrowthCategory: RecentGrowthStory] {
        let grouped = Dictionary(grouping: buckets) { $0.category }
        var result: [GrowthCategory: RecentGrowthStory] = [:]

        for (rawCategory, categoryBuckets) in grouped {
            guard let category = GrowthCategory(rawValue: rawCategory) else { continue }
            let positiveBuckets = categoryBuckets
                .filter { $0.deltaBytes > 0 }
                .sorted { $0.bucketStart < $1.bucketStart }

            guard let first = positiveBuckets.first, let last = positiveBuckets.last else { continue }

            let total = positiveBuckets.reduce(Int64(0)) { $0 + $1.deltaBytes }
            guard total >= recentStoryThresholdBytes else { continue }

            let duration = max(60, last.bucketStart.timeIntervalSince(first.bucketStart) + 60)
            result[category] = RecentGrowthStory(
                category: category,
                subcategory: nil,
                deltaBytes: total,
                startedAt: first.bucketStart,
                endedAt: last.bucketStart,
                duration: duration,
                displayLabel: ""
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
