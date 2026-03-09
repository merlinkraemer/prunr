import XCTest
@testable import Prunr

final class PrunrSmokeTests: XCTestCase {
    private func withTemporaryDatabase(
        _ body: @escaping (_ trackedPathId: UUID, _ snapshotId: Int64) async throws -> Void
    ) async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrunrTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let dbPath = tempDirectory.appendingPathComponent("prunr.sqlite").path
        try DatabaseManager.shared.initialize(at: dbPath)

        let trackedPathId = UUID()
        let snapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
        guard let snapshotId = snapshot.id else {
            XCTFail("snapshot id should be created")
            return
        }

        try await body(trackedPathId, snapshotId)
    }

    func testDownloadsPathsCategorizeAsDownloads() {
        let downloadsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/archive.zip")
            .path

        XCTAssertEqual(
            GrowthCategory.categorize(path: downloadsPath),
            .downloads
        )
    }

    func testNodeModulesPathsResolveToDeveloperNodeModules() {
        XCTAssertEqual(
            GrowthCategory.subcategorize(path: "/Users/tester/dev/app/node_modules/react/index.js"),
            .nodeModules
        )
    }

    func testGrowthItemFlagsBigFilesAtThreshold() {
        let downloadsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/archive.zip")
            .path

        let item = GrowthItem(
            path: downloadsPath,
            growthBytes: bigFileThreshold,
            currentSizeBytes: bigFileThreshold,
            percentOfParent: 1.0
        )

        XCTAssertTrue(item.isBigFile)
        XCTAssertEqual(item.category, .downloads)
    }

    func testCategoryAggregationMatchesRuntimeClassifier() async throws {
        try await withTemporaryDatabase { _, snapshotId in
            try await DatabaseManager.shared.addEntries(
                to: snapshotId,
                entries: [
                    ScanResult(path: "/usr/local/lib/node_modules/react/index.js", sizeBytes: 2_048),
                    ScanResult(path: "/usr/local/lib/node_modules/vue/index.js", sizeBytes: 1_024)
                ]
            )

            try await DatabaseCleanupService.shared.aggregateCategoryTotals(for: snapshotId)
            let totals = try await DatabaseManager.shared.fetchCategoryTotals(for: snapshotId)

            XCTAssertEqual(
                totals.first(where: { $0.category == .applications })?.currentSizeBytes,
                3_072
            )
            XCTAssertNil(totals.first(where: { $0.category == .developer }))
        }
    }

    func testSubcategoryBreakdownUsesFullCategoryTotals() async throws {
        try await withTemporaryDatabase { _, snapshotId in
            let entries = (1...25).map { index in
                ScanResult(
                    path: "/Users/tester/dev/app/node_modules/pkg-\(index).js",
                    sizeBytes: Int64(index * 1_000)
                )
            }

            try await DatabaseManager.shared.addEntries(to: snapshotId, entries: entries)

            let groups = await BaselineService.shared.getSubcategoryBreakdown(
                for: .developer,
                snapshotId: snapshotId
            )

            let group = try XCTUnwrap(groups.first(where: { $0.subcategory == .nodeModules }))
            XCTAssertEqual(group.fileCount, 25)
            XCTAssertEqual(group.totalBytes, entries.reduce(0) { $0 + $1.sizeBytes })
            XCTAssertEqual(group.topFiles.count, SubcategoryGroup.initialLoadLimit)
        }
    }

    func testLoadMoreFilesUsesStablePagingWithoutDuplicates() async throws {
        try await withTemporaryDatabase { _, snapshotId in
            let entries = (1...25).reversed().map { index in
                ScanResult(
                    path: "/Users/tester/dev/app/node_modules/pkg-\(String(format: "%02d", index)).js",
                    sizeBytes: 1_000
                )
            }

            try await DatabaseManager.shared.addEntries(to: snapshotId, entries: entries)

            let groups = await BaselineService.shared.getSubcategoryBreakdown(
                for: .developer,
                snapshotId: snapshotId
            )
            let group = try XCTUnwrap(groups.first(where: { $0.subcategory == .nodeModules }))

            XCTAssertEqual(
                group.topFiles.map { URL(fileURLWithPath: $0.path).lastPathComponent },
                (1...20).map { String(format: "pkg-%02d.js", $0) }
            )

            let additionalFiles = await BaselineService.shared.loadMoreSubcategoryFiles(
                for: .developer,
                subcategory: .nodeModules,
                snapshotId: snapshotId,
                totalBytes: group.totalBytes,
                offset: group.loadedFileCount,
                limit: 10
            )

            XCTAssertEqual(
                additionalFiles.map { URL(fileURLWithPath: $0.path).lastPathComponent },
                (21...25).map { String(format: "pkg-%02d.js", $0) }
            )
            XCTAssertEqual(
                Set(group.topFiles.map(\.path)).intersection(Set(additionalFiles.map(\.path))).count,
                0
            )
        }
    }

    func testFSEventsWatcherReportsRealFilesystemChanges() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrunrWatcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let watcher = FSEventsWatcher(pathsToWatch: [tempDirectory], debounceInterval: 0.1)
        let expectation = expectation(description: "watcher emits changed path")

        await watcher.setOnChange { changedPaths in
            if changedPaths.contains(where: { $0.path.hasPrefix(tempDirectory.path) }) {
                expectation.fulfill()
            }
        }
        await watcher.start()
        try? await Task.sleep(for: .milliseconds(250))

        let fileURL = tempDirectory.appendingPathComponent("watch.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [expectation], timeout: 5.0)
        await watcher.stop()
    }
}
