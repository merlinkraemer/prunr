import GRDB
import XCTest
@testable import Prunr

final class DrilldownOnDemandTests: PrunrTestCase {
    private var db: DatabaseManager { DatabaseManager.shared }

    private func markBuildingAndDropIndexRows(_ trackedPathId: UUID) async throws {
        let dbPool = try XCTUnwrap(db.dbPool)
        try await dbPool.write { db in
            for table in ["workingSetGroupTotal", "workingSetTopEntry", "workingSetPlaceChild"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE trackedPathId = ?", arguments: [trackedPathId.uuidString])
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO workingSetIndexState (trackedPathId, state) VALUES (?, 'building')",
                arguments: [trackedPathId.uuidString]
            )
        }
    }

    private func shape(_ groups: [SubcategoryGroup]) -> [String] {
        groups.map { group in
            ([group.id, group.displayName, "\(group.totalBytes)", "\(group.fileCount)"]
                + group.topFiles.map { "\($0.path)=\($0.currentSizeBytes)" }).joined(separator: "|")
        }
    }

    func testPlaceContentsWhileIndexingMatchTheIndex() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            let place = "/Data/Place"
            _ = try await db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: "/Data", entries: [
                ScanResult(path: place + "/big.iso", sizeBytes: 500, category: .other, subcategory: nil),
                ScanResult(path: place + "/Photos/a.jpg", sizeBytes: 300, category: .mediaAndDocuments, subcategory: .photos),
                ScanResult(path: place + "/Photos/2026/b.jpg", sizeBytes: 400, category: .mediaAndDocuments, subcategory: .photos),
                ScanResult(path: place + "/Docs/x.txt", sizeBytes: 100, category: .mediaAndDocuments, subcategory: .documents),
                ScanResult(path: place + "-other/y.txt", sizeBytes: 9_000, category: .other, subcategory: nil)
            ])
            let second = UUID()
            _ = try await db.replaceWorkingSetFile(
                trackedPathId: second,
                entry: ScanResult(path: place + "/Docs/y.txt", sizeBytes: 1_000, category: .mediaAndDocuments, subcategory: .documents)
            )

            let indexed = try await [
                db.fetchPlaceContents(unitRoot: place, trackedPathIds: [id], limit: 2),
                db.fetchPlaceContents(unitRoot: place, trackedPathIds: [id], offset: 2, limit: 2),
                db.fetchPlaceContents(unitRoot: place, trackedPathIds: [id]),
                db.fetchPlaceContents(unitRoot: place, trackedPathIds: [id, second])
            ]
            XCTAssertEqual(indexed[2].children.map(\.name), ["Photos", "big.iso", "Docs"])

            try await markBuildingAndDropIndexRows(id)

            let onDemand = try await [
                db.fetchPlaceContents(unitRoot: place, trackedPathIds: [id], limit: 2),
                db.fetchPlaceContents(unitRoot: place, trackedPathIds: [id], offset: 2, limit: 2),
                db.fetchPlaceContents(unitRoot: place, trackedPathIds: [id]),
                db.fetchPlaceContents(unitRoot: place, trackedPathIds: [id, second])
            ]
            XCTAssertEqual(onDemand, indexed)
            XCTAssertEqual(onDemand[3].children.first?.name, "Docs")
            XCTAssertEqual(onDemand[3].children.first?.totalBytes, 1_100)
        }
    }

    func testSoleItemOfAFileUnitWhileIndexing() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            let download = UnitResolver.defaultHome + "/Downloads/ubuntu.iso"
            _ = try await db.replaceWorkingSetFile(
                trackedPathId: id,
                entry: ScanResult(path: download, sizeBytes: 4_000, category: .downloads, subcategory: nil)
            )
            try await markBuildingAndDropIndexRows(id)

            let root = try XCTUnwrap(UnitKey(rawValue: UnitResolver.resolve(path: download))?.rootPath)
            let page = try await db.fetchPlaceContents(unitRoot: root, trackedPathIds: [id])
            XCTAssertEqual(SoloDrill.revealPath(leaves: page.children.map(\.path), hasMore: page.hasMore), download)
        }
    }

    @MainActor
    func testCategoryGroupsWhileIndexingComeFromTheWorkingSet() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            let cacheRoot = UnitResolver.defaultHome + "/Library/Caches"
            var entries = (1...260).map {
                ScanResult(path: "/Data/Tree/big/f\(String(format: "%03d", $0)).js", sizeBytes: Int64($0), category: .developer, subcategory: .nodeModules)
            }
            entries.append(ScanResult(path: "/Data/Tree/out/a.o", sizeBytes: 50, category: .developer, subcategory: .buildArtifacts))
            _ = try await db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: "/Data/Tree", entries: entries)
            _ = try await db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: cacheRoot, entries: [
                ScanResult(path: cacheRoot + "/com.example.one/blob", sizeBytes: 70, category: .cachesAndSystem, subcategory: .appCaches),
                ScanResult(path: cacheRoot + "/com.example.one/blob2", sizeBytes: 30, category: .cachesAndSystem, subcategory: .appCaches),
                ScanResult(path: cacheRoot + "/com.example.two/blob", sizeBytes: 20, category: .cachesAndSystem, subcategory: .appCaches)
            ])

            let indexedDeveloper = await drilldownGroups(.developer, trackedPathIds: [id])
            let indexedCaches = await drilldownGroups(.cachesAndSystem, trackedPathIds: [id])
            XCTAssertEqual(indexedDeveloper.count, 2)
            XCTAssertEqual(indexedCaches.count, 2)

            try await markBuildingAndDropIndexRows(id)

            let store = DrilldownStore()
            await store.reload(trackedPathIds: [id])
            XCTAssertTrue(store.isBuilding)
            XCTAssertTrue(store.isGroupsPending(for: .developer))
            XCTAssertNil(CategorySizes.groupsStatus(isEmpty: true, isPending: store.isGroupsPending(for: .developer), readFailed: false))

            await store.loadFiles(for: .developer, trackedPathIds: [id])
            await store.loadFiles(for: .cachesAndSystem, trackedPathIds: [id])
            XCTAssertFalse(store.isGroupsPending(for: .developer))
            XCTAssertEqual(store.groupsByCategory[.developer].map { self.shape($0) }, self.shape(indexedDeveloper))
            XCTAssertEqual(store.groupsByCategory[.cachesAndSystem].map { self.shape($0) }, self.shape(indexedCaches))

            var group = try XCTUnwrap(store.groupsByCategory[.developer]?.first { $0.subcategory == .nodeModules })
            while let next = await store.loadMoreFiles(for: group, category: .developer, trackedPathIds: [id]) {
                group = next
            }
            XCTAssertEqual(group.topFiles.map(\.currentSizeBytes), (1...260).reversed().map(Int64.init))

            await store.reload(trackedPathIds: [id])
            XCTAssertEqual(store.groupsByCategory[.developer]?.map(\.fileCount), indexedDeveloper.map(\.fileCount))

            try await db.rebuildDrilldownIndex(trackedPathId: id)
            await store.reload(trackedPathIds: [id])
            XCTAssertFalse(store.isBuilding)
            XCTAssertEqual(store.groupsByCategory[.developer]?.map(\.totalBytes), indexedDeveloper.map(\.totalBytes))
            XCTAssertEqual(store.groupsByCategory[.cachesAndSystem]?.map(\.id), indexedCaches.map(\.id))
        }
    }
}
