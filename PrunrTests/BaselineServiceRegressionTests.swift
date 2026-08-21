import XCTest
import GRDB
@testable import Prunr

final class BaselineServiceRegressionTests: PrunrTestCase {

    // MARK: - Signed growth over a fixed window

    private func makeTrackedPath(_ id: UUID) -> TrackedPath {
        TrackedPath(
            id: id,
            url: URL(fileURLWithPath: "/Users/tester/dev", isDirectory: true),
            displayName: "dev"
        )
    }

    /// The header must equal the signed sum of every category delta, including
    /// sub-floor categories that never render a delta line.
    func testGrowthStoriesSumSignedAcrossCategoriesIncludingSubFloor() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = self.makeTrackedPath(trackedPathId)
            let gb: Int64 = 1024 * 1024 * 1024

            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [
                    .init(category: .developer, subcategory: nil): -20 * gb,
                    .init(category: .downloads, subcategory: nil): 1 * gb,
                    // Sub-floor: hidden by the row renderer, still in the sum.
                    .init(category: .applications, subcategory: nil): 800_000
                ],
                at: Date().addingTimeInterval(-3600)
            )

            let stories = await GrowthJournalService.shared.recentGrowthStories(trackedPath: trackedPath)

            XCTAssertEqual(stories[.developer]?.deltaBytes, -20 * gb)
            XCTAssertEqual(stories[.downloads]?.deltaBytes, 1 * gb)
            XCTAssertEqual(stories[.applications]?.deltaBytes, 800_000)

            let signedTotal = stories.values.reduce(Int64(0)) { $0 + $1.deltaBytes }
            XCTAssertEqual(signedTotal, -19 * gb + 800_000)
        }
    }

    /// Grew then cleared inside the window nets to zero — no story at all, not `+8 GB`.
    func testCategoryClearedInWindowProducesNoStory() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = self.makeTrackedPath(trackedPathId)
            let eightGB: Int64 = 8 * 1024 * 1024 * 1024

            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .cachesAndSystem, subcategory: nil): eightGB],
                at: Date().addingTimeInterval(-7200)
            )
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .cachesAndSystem, subcategory: nil): -eightGB],
                at: Date().addingTimeInterval(-3600)
            )

            let stories = await GrowthJournalService.shared.recentGrowthStories(trackedPath: trackedPath)
            XCTAssertNil(stories[.cachesAndSystem])
        }
    }

    /// Retention governs pruning only. Lowering it must not change what the
    /// fixed display window counts, and pruning must never reach inside it.
    func testDisplayWindowIsIndependentOfRetentionSetting() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = self.makeTrackedPath(trackedPathId)
            let inWindow: Int64 = 5 * 1024 * 1024
            let outOfWindow: Int64 = 16 * 1024 * 1024 * 1024
            let day: TimeInterval = 24 * 60 * 60

            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .developer, subcategory: nil): inWindow],
                at: Date().addingTimeInterval(-2 * day)
            )
            // 9 days back: outside the 7-day display window.
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .developer, subcategory: nil): outOfWindow],
                at: Date().addingTimeInterval(-9 * day)
            )

            let stories = await GrowthJournalService.shared.recentGrowthStories(trackedPath: trackedPath)
            XCTAssertEqual(stories[.developer]?.deltaBytes, inWindow, "the 9-day-old spike must have aged out")

            // A retention shorter than the display window must be clamped, so
            // pruning cannot delete the bucket that is still on screen.
            await GrowthJournalService.shared.prune(retentionDays: 1)

            let afterPrune = await GrowthJournalService.shared.recentGrowthStories(trackedPath: trackedPath)
            XCTAssertEqual(
                afterPrune[.developer]?.deltaBytes,
                inWindow,
                "pruning must never reach inside the display window"
            )
        }
    }

    @MainActor
    func testRetentionSettingIsClampedToDisplayWindow() {
        let previous = SettingsStore.shared.categoryHistoryRetentionDays
        defer { SettingsStore.shared.categoryHistoryRetentionDays = previous }

        SettingsStore.shared.categoryHistoryRetentionDays = 3
        XCTAssertEqual(
            SettingsStore.shared.categoryHistoryRetentionDays,
            GrowthJournalService.displayWindowDays
        )
    }
    func testAcceptGrowthPromotesWorkingSetWithoutFilesystemFreeSpace() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = TrackedPath(
                id: trackedPathId,
                url: URL(fileURLWithPath: "/Users/tester/dev", isDirectory: true),
                displayName: "dev"
            )
            let liveFile = trackedPath.url.appendingPathComponent("app/.build/output.bin")

            _ = try await DatabaseManager.shared.replaceWorkingSetSubtree(
                trackedPathId: trackedPathId,
                rootPath: trackedPath.url.path,
                entries: [
                    ScanResult(path: liveFile.path, sizeBytes: 128_000)
                ]
            )
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .developer, subcategory: .buildArtifacts): 128_000],
                at: Date()
            )

            try await BaselineService.shared.acceptGrowth(for: trackedPath)

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let state = try await dbPool.read { db in
                let snapshotCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM snapshot WHERE trackedPathId = ?",
                    arguments: [trackedPathId.uuidString]
                ) ?? 0
                let freeBytesCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM snapshot WHERE trackedPathId = ? AND freeBytes IS NOT NULL",
                    arguments: [trackedPathId.uuidString]
                ) ?? 0
                let snapshotBytes = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT COALESCE(SUM(se.sizeBytes), 0)
                        FROM snapshotEntry se
                        JOIN snapshot s ON s.id = se.snapshotId
                        WHERE s.trackedPathId = ?
                        """,
                    arguments: [trackedPathId.uuidString]
                ) ?? 0
                let journalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalBucket") ?? 0
                return (snapshotCount, freeBytesCount, snapshotBytes, journalCount)
            }

            XCTAssertEqual(state.0, 1)
            XCTAssertEqual(state.1, 0)
            XCTAssertEqual(state.2, 128_000)
            XCTAssertEqual(state.3, 0)
        }
    }

    func testFirstBaselineClearsStaleRealtimeStateForTrackedPath() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrBaselineFresh")
            defer {
                try? FileManager.default.removeItem(at: tempDirectory)
            }

            let liveFile = tempDirectory.appendingPathComponent("existing.txt")
            try Data(repeating: 0xCD, count: 2_048).write(to: liveFile)

            _ = try await DatabaseManager.shared.replaceWorkingSetSubtree(
                trackedPathId: trackedPathId,
                rootPath: tempDirectory.path,
                entries: [
                    ScanResult(path: liveFile.path, sizeBytes: 2_048),
                    ScanResult(path: tempDirectory.appendingPathComponent("stale.txt").path, sizeBytes: 4_096)
                ]
            )

            try await DatabaseManager.shared.upsertGrowthJournalBuckets(
                trackedPathId: trackedPathId,
                bucketStart: Date(),
                deltas: [.init(category: .other, subcategory: nil): 6_144]
            )

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")
            let snapshot = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            let snapshotId = try XCTUnwrap(snapshot.id)

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let counts = try await dbPool.read { db in
                let journalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalBucket") ?? 0
                let workingSetCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM workingSetEntry WHERE trackedPathId = ?",
                    arguments: [trackedPathId.uuidString]
                ) ?? 0
                return (journalCount, workingSetCount)
            }

            XCTAssertEqual(counts.0, 0)
            XCTAssertEqual(counts.1, 1)

            let contributors = try await DatabaseManager.shared.fetchGrowthContributors(
                trackedPathId: trackedPathId,
                snapshotId: snapshotId,
                category: .other,
                subcategory: nil,
                limit: 20
            )
            XCTAssertTrue(contributors.isEmpty)
        }
    }

    /// Regression: a full scan must not double-count growth the realtime watcher
    /// already recorded. Both the incremental refresh and `createBaseline` write
    /// to the growth journal, and the journal accumulates — so without the full
    /// scan reclaiming its own window, the same growth lands twice and the
    /// displayed total roughly doubles every reconciliation cycle.
    func testReconciliationFullScanDoesNotDoubleCountRealtimeGrowth() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrDoubleCount")
            defer { try? FileManager.default.removeItem(at: tempDirectory) }

            let file = tempDirectory.appendingPathComponent("blob.bin")
            let initialBytes = 2_048
            let growthBytes = 3 * 1_024 * 1_024
            try Data(repeating: 0xAB, count: initialBytes).write(to: file)

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")

            // 1) First baseline (S0) — establishes the reference; no journal yet.
            _ = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)

            // 2) File grows on disk; the realtime watcher records the delta into the
            //    journal (simulated here via recordDeltas, as RecentChangeService does).
            //    In reality this lands well after the baseline snapshot; the +120s
            //    stamp models that (the real reconciliation gap is hours).
            try Data(repeating: 0xAB, count: initialBytes + growthBytes).write(to: file)
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .other, subcategory: nil): Int64(growthBytes)],
                at: Date().addingTimeInterval(120)
            )

            // 3) Reconciliation full scan (S1) — sees the same grown file and records
            //    the snapshot delta (S0 -> S1) into the journal as well.
            _ = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)

            // 4) Displayed growth must equal the ACTUAL growth, not 2x.
            let stories = await GrowthJournalService.shared.recentGrowthStories(
                trackedPath: trackedPath
            )
            let total = stories[.other]?.deltaBytes ?? 0
            XCTAssertEqual(
                total,
                Int64(growthBytes),
                "growth should be counted once; got \(total) bytes vs expected \(growthBytes)"
            )
        }
    }

    func testSingleSnapshotInventorySurfacesRealtimeGrowthStory() async throws {
        try await withTemporaryDatabase { trackedPathId, snapshotId in
            let trackedPath = TrackedPath(
                id: trackedPathId,
                url: URL(fileURLWithPath: "/Users/tester/dev", isDirectory: true),
                displayName: "dev"
            )

            try await DatabaseManager.shared.addEntries(
                to: snapshotId,
                entries: [
                    ScanResult(path: "/Users/tester/dev/app/.build/output.bin", sizeBytes: 128_000)
                ]
            )
            try await DatabaseManager.shared.rebuildWorkingSet(
                from: snapshotId,
                trackedPathId: trackedPathId
            )

            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [.init(category: .developer, subcategory: .nodeModules): 2 * 1_024 * 1_024],
                at: Date()
            )

            let inventory = await BaselineService.shared.getInventoryWithTrends(trackedPath: trackedPath)
            let developer = try XCTUnwrap(inventory.first(where: { $0.category == .developer }))
            XCTAssertEqual(developer.currentSizeBytes, 128_000)
            XCTAssertEqual(developer.recentGrowthStory?.deltaBytes, 2 * 1_024 * 1_024)
        }
    }
}
