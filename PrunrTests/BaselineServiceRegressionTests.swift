import XCTest
import GRDB
@testable import Prunr

final class BaselineServiceRegressionTests: PrunrTestCase {
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
