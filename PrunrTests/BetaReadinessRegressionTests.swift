import XCTest
import GRDB
@testable import Prunr

final class BetaReadinessRegressionTests: PrunrTestCase {
    func testRestoreWorkingSetAfterFailedInlineScanUsesLatestCompleteSnapshot() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let goodSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let goodSnapshotId = try XCTUnwrap(goodSnapshot.id)
            try await DatabaseManager.shared.addEntries(
                to: goodSnapshotId,
                entries: [
                    ScanResult(path: "/tmp/prunr/old.txt", sizeBytes: 100, category: .other, subcategory: nil)
                ]
            )
            try await DatabaseManager.shared.rebuildWorkingSet(
                from: goodSnapshotId,
                trackedPathId: trackedPathId,
                updatedAt: goodSnapshot.createdAt
            )

            let failedSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let failedSnapshotId = try XCTUnwrap(failedSnapshot.id)
            try await DatabaseManager.shared.addEntriesWithWorkingSet(
                to: failedSnapshotId,
                entries: [
                    ScanResult(path: "/tmp/prunr/new.txt", sizeBytes: 200, category: .downloads, subcategory: nil)
                ],
                trackedPathId: trackedPathId,
                updatedAt: failedSnapshot.createdAt
            )
            try await DatabaseManager.shared.deleteSnapshot(id: failedSnapshotId)

            let restoredSnapshotId = try await DatabaseManager.shared.restoreWorkingSetFromLatestSnapshotOrClear(
                trackedPathId: trackedPathId
            )
            XCTAssertEqual(restoredSnapshotId, goodSnapshotId)

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let rows = try await dbPool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT p.path AS path, wse.sizeBytes AS sizeBytes
                        FROM workingSetEntry wse
                        JOIN paths p ON p.id = wse.pathId
                        WHERE wse.trackedPathId = ?
                        ORDER BY p.path
                        """,
                    arguments: [trackedPathId.uuidString]
                )
            }

            XCTAssertEqual(rows.count, 1)
            let restoredPath: String? = rows.first?["path"]
            let restoredSize: Int64? = rows.first?["sizeBytes"]
            XCTAssertEqual(restoredPath, "/tmp/prunr/old.txt")
            XCTAssertEqual(restoredSize, 100)
        }
    }

    func testRestoreWorkingSetAfterFailedFirstInlineScanClearsPartialRows() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let failedSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let failedSnapshotId = try XCTUnwrap(failedSnapshot.id)
            try await DatabaseManager.shared.addEntriesWithWorkingSet(
                to: failedSnapshotId,
                entries: [
                    ScanResult(path: "/tmp/prunr/partial.txt", sizeBytes: 200, category: .downloads, subcategory: nil)
                ],
                trackedPathId: trackedPathId,
                updatedAt: failedSnapshot.createdAt
            )
            try await DatabaseManager.shared.deleteSnapshot(id: failedSnapshotId)

            let restoredSnapshotId = try await DatabaseManager.shared.restoreWorkingSetFromLatestSnapshotOrClear(
                trackedPathId: trackedPathId
            )
            XCTAssertNil(restoredSnapshotId)

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let count = try await dbPool.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM workingSetEntry WHERE trackedPathId = ?",
                    arguments: [trackedPathId.uuidString]
                ) ?? 0
            }
            XCTAssertEqual(count, 0)
        }
    }

    func testSnapshotSubcategoryBreakdownUsesPathClassificationFilter() async throws {
        try await withTemporaryDatabase { _, snapshotId in
            var entries: [ScanResult] = []
            for index in 0..<20 {
                entries.append(ScanResult(
                    path: "/Users/tester/Downloads/download-\(index).dmg",
                    sizeBytes: Int64(1_000 + index),
                    category: .downloads,
                    subcategory: nil
                ))
            }
            entries.append(contentsOf: [
                ScanResult(
                    path: "/Users/tester/dev/app/node_modules/package-a/index.js",
                    sizeBytes: 10_000,
                    category: .developer,
                    subcategory: .nodeModules
                ),
                ScanResult(
                    path: "/Users/tester/dev/app/node_modules/package-b/index.js",
                    sizeBytes: 8_000,
                    category: .developer,
                    subcategory: .nodeModules
                ),
                ScanResult(
                    path: "/Users/tester/dev/app/.build/output.o",
                    sizeBytes: 6_000,
                    category: .developer,
                    subcategory: .buildArtifacts
                )
            ])

            try await DatabaseManager.shared.addEntries(to: snapshotId, entries: entries)

            let groups = try await DatabaseManager.shared.fetchSubcategoryGroupsByClassification(
                for: snapshotId,
                category: .developer,
                topLimit: 2
            )

            XCTAssertEqual(groups.reduce(0) { $0 + $1.fileCount }, 3)
            XCTAssertEqual(groups.reduce(Int64(0)) { $0 + $1.totalBytes }, 24_000)
            XCTAssertNil(groups.first { $0.displayName == GrowthCategory.downloads.displayName })

            let nodeModules = try XCTUnwrap(groups.first { $0.subcategory == .nodeModules })
            XCTAssertEqual(nodeModules.fileCount, 2)
            XCTAssertEqual(nodeModules.topFiles.map(\.currentSizeBytes), [10_000, 8_000])
        }
    }
}
