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

    func testCleanupCapsSnapshotHistoryByCount() async throws {
        let previousRetention = await MainActor.run { () -> Int in
            let current = SettingsStore.shared.categoryHistoryRetentionDays
            SettingsStore.shared.categoryHistoryRetentionDays = 3650
            return current
        }
        defer {
            Task { @MainActor in
                SettingsStore.shared.categoryHistoryRetentionDays = previousRetention
            }
        }

        try await withTemporaryDatabase { trackedPathId, _ in
            let retentionCap = 500
            let totalSnapshots = retentionCap + 5
            var createdSnapshotIDs: [Int64] = []

            for index in 0..<totalSnapshots {
                let snapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
                let snapshotId = try XCTUnwrap(snapshot.id)
                createdSnapshotIDs.append(snapshotId)

                try await DatabaseManager.shared.replaceCategorySnapshots(
                    snapshotId: snapshotId,
                    totals: [.developer: Int64(index + 1)]
                )
                try await DatabaseManager.shared.replaceSubcategorySnapshots(
                    snapshotId: snapshotId,
                    rows: [
                        DatabaseManager.StoredSubcategorySnapshot(
                            category: .developer,
                            subcategory: .nodeModules,
                            totalBytes: Int64(index + 1),
                            fileCount: 1,
                            topItems: []
                        )
                    ]
                )
            }

            let deletedCount = try await DatabaseCleanupService.shared.cleanupOldCategoryHistory()
            let remainingSnapshots = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPathId)
            let remainingSnapshotIDs = remainingSnapshots.compactMap(\.id)

            XCTAssertEqual(deletedCount, 6)
            XCTAssertEqual(remainingSnapshots.count, retentionCap)
            XCTAssertEqual(Set(remainingSnapshotIDs), Set(createdSnapshotIDs.suffix(retentionCap)))

            let categoryRows = DatabaseManager.shared.fetchCategorySnapshots(
                trackedPathId: trackedPathId.uuidString,
                limit: totalSnapshots + 10
            )
            XCTAssertEqual(Set(categoryRows.map(\.snapshotId)), Set(remainingSnapshotIDs))

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let subcategorySnapshotCount = try await dbPool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM subcategorySnapshot") ?? 0
            }
            XCTAssertEqual(subcategorySnapshotCount, retentionCap)
        }
    }

    func testCompactionPreservesWorkingSetOnlyPaths() async throws {
        try await withTemporaryDatabase { trackedPathId, snapshotId in
            try await DatabaseManager.shared.addEntries(
                to: snapshotId,
                entries: [
                    ScanResult(path: "/tmp/root/original.txt", sizeBytes: 1)
                ]
            )
            try await DatabaseManager.shared.rebuildWorkingSet(
                from: snapshotId,
                trackedPathId: trackedPathId
            )

            _ = try await DatabaseManager.shared.replaceWorkingSetSubtree(
                trackedPathId: trackedPathId,
                rootPath: "/tmp/root/new-folder",
                entries: [
                    ScanResult(path: "/tmp/root/new-folder/new.txt", sizeBytes: 2)
                ]
            )

            UserDefaults.standard.set(
                Date().timeIntervalSince1970,
                forKey: "databaseLastCheckpointAt"
            )
            UserDefaults.standard.set(
                Date().timeIntervalSince1970,
                forKey: "databaseLastVacuumAt"
            )

            await DatabaseCleanupService.shared.performAutoCleanup()

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let workingSetPaths = try await dbPool.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT p.path
                        FROM workingSetEntry wse
                        JOIN paths p ON p.id = wse.pathId
                        ORDER BY p.path ASC
                        """
                )
            }

            XCTAssertTrue(workingSetPaths.contains("/tmp/root/new-folder/new.txt"))
        }
    }
}
