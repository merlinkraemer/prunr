import Foundation

actor GrowthJournalService {
    static let shared = GrowthJournalService()

    private let db = DatabaseManager.shared
    private let recentStoryThresholdBytes: Int64 = 250 * 1024 * 1024
    private let recentStoryWindow: TimeInterval = 7 * 24 * 60 * 60

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
            print("[GrowthJournalService] Failed to fetch recent growth stories: \(error)")
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
            print("[GrowthJournalService] Failed to fetch deltas since last snapshot: \(error)")
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
            print("[GrowthJournalService] Failed to fetch subcategory growth totals: \(error)")
            return [:]
        }
    }

    func prune(retentionDays: Int) async {
        let retentionWindow = TimeInterval(max(1, retentionDays)) * 24 * 60 * 60
        let cutoff = Date().addingTimeInterval(-retentionWindow)

        do {
            try await db.pruneGrowthJournalBuckets(olderThan: cutoff)
        } catch {
            print("[GrowthJournalService] Failed to prune growth journal: \(error)")
        }
    }

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

            guard !positiveBuckets.isEmpty else { continue }

            let segments = buildSegments(from: positiveBuckets)
            let recentSegments = segments.filter { now.timeIntervalSince($0.endedAt) <= recentStoryWindow }

            guard let bestSegment = recentSegments.max(by: {
                score(segment: $0, now: now, retentionWindow: retentionWindow)
                < score(segment: $1, now: now, retentionWindow: retentionWindow)
            }) else {
                continue
            }

            guard bestSegment.deltaBytes >= recentStoryThresholdBytes else { continue }

            let duration = max(60, bestSegment.endedAt.timeIntervalSince(bestSegment.startedAt) + 60)
            result[category] = RecentGrowthStory(
                category: category,
                subcategory: nil,
                deltaBytes: bestSegment.deltaBytes,
                startedAt: bestSegment.startedAt,
                endedAt: bestSegment.endedAt,
                duration: duration,
                displayLabel: formattedRecency(since: bestSegment.endedAt, now: now)
            )
        }

        return result
    }

    private func buildSegments(from buckets: [GrowthJournalBucket]) -> [GrowthSegment] {
        guard let first = buckets.first else { return [] }

        var segments: [GrowthSegment] = []
        var current = GrowthSegment(
            startedAt: first.bucketStart,
            endedAt: first.bucketStart,
            deltaBytes: first.deltaBytes
        )

        for bucket in buckets.dropFirst() {
            let gap = bucket.bucketStart.timeIntervalSince(current.endedAt)
            if gap <= 3 * 60 {
                current.endedAt = bucket.bucketStart
                current.deltaBytes += bucket.deltaBytes
            } else {
                segments.append(current)
                current = GrowthSegment(
                    startedAt: bucket.bucketStart,
                    endedAt: bucket.bucketStart,
                    deltaBytes: bucket.deltaBytes
                )
            }
        }

        segments.append(current)
        return segments
    }

    private func score(segment: GrowthSegment, now: Date, retentionWindow: TimeInterval) -> Double {
        let age = max(0, now.timeIntervalSince(segment.endedAt))
        let recencyWeight: Double
        if age <= 24 * 60 * 60 {
            recencyWeight = 1.0
        } else {
            let decayWindow = max(60, retentionWindow - 24 * 60 * 60)
            let progress = min(1.0, (age - 24 * 60 * 60) / decayWindow)
            recencyWeight = 1.0 - (0.65 * progress)
        }

        return Double(segment.deltaBytes) * recencyWeight
    }

    private func formattedRecency(since endedAt: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(endedAt)

        if elapsed < 5 * 60 {
            return "just now"
        }

        let minutes = Int(elapsed / 60)
        if minutes < 60 {
            return "\(minutes)m ago"
        }

        let hours = Int((elapsed / 3600).rounded())
        if hours < 24 {
            return "\(hours)h ago"
        }

        if hours < 48 {
            return "yesterday"
        }

        let days = Int((elapsed / (24 * 3600)).rounded())
        return "\(days)d ago"
    }

    private func floorToMinute(_ date: Date) -> Date {
        let timeInterval = date.timeIntervalSinceReferenceDate
        let floored = floor(timeInterval / 60.0) * 60.0
        return Date(timeIntervalSinceReferenceDate: floored)
    }
}

private struct GrowthSegment {
    var startedAt: Date
    var endedAt: Date
    var deltaBytes: Int64
}
