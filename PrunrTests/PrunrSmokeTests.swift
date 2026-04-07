import XCTest
import GRDB
@testable import Prunr

final class PrunrSmokeTests: XCTestCase {
    private func withEmptyTemporaryDatabase(
        _ body: @escaping (_ trackedPathId: UUID) async throws -> Void
    ) async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrunrTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let dbPath = tempDirectory.appendingPathComponent("prunr.sqlite").path
        try DatabaseManager.shared.initialize(at: dbPath)

        try await body(UUID())
    }

    private func withTemporaryDatabase(
        _ body: @escaping (_ trackedPathId: UUID, _ snapshotId: Int64) async throws -> Void
    ) async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrunrTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? DatabaseManager.shared.close()
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

    private func workingSetMetadataByPath() async throws -> [String: (sizeBytes: Int64, updatedAt: Date)] {
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT p.path AS path, wse.sizeBytes AS sizeBytes, wse.updatedAt AS updatedAt
                    FROM workingSetEntry wse
                    JOIN paths p ON p.id = wse.pathId
                    """
            )

            var result: [String: (sizeBytes: Int64, updatedAt: Date)] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                let path: String = row["path"] ?? ""
                let sizeBytes: Int64 = row["sizeBytes"] ?? 0
                let updatedAt: Date = row["updatedAt"] ?? .distantPast
                result[path] = (sizeBytes, updatedAt)
            }
            return result
        }
    }

    private func createTrackedPathDirectory(
        named prefix: String
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func withIsolatedTrackedPathSettings<T>(
        mainBaseURL: URL,
        _ body: () async throws -> T
    ) async throws -> T {
        let settings = SettingsStore.shared
        let originalMainBasePath = settings.mainBasePath
        let originalCustomTrackedPaths = settings.customTrackedPaths
        let originalSelectedCommonPathIDs = Set(settings.selectedCommonPaths.map(\.id))
        let originalEnabledPathIDs = Set(settings.allTrackedPaths.filter { settings.isPathEnabled($0) }.map(\.id))
        let originalHasPendingScopeChanges = settings.hasPendingScopeChanges

        defer {
            settings.setMainBasePath(URL(fileURLWithPath: originalMainBasePath, isDirectory: true))
            settings.customTrackedPaths = originalCustomTrackedPaths

            for path in settings.availableCommonPaths {
                settings.setCommonPathSelected(path, selected: originalSelectedCommonPathIDs.contains(path.id))
            }

            for path in settings.allTrackedPaths {
                settings.setPathEnabled(path, enabled: originalEnabledPathIDs.contains(path.id))
            }

            settings.hasPendingScopeChanges = originalHasPendingScopeChanges
        }

        settings.setMainBasePath(mainBaseURL)
        settings.customTrackedPaths = []

        for path in settings.availableCommonPaths {
            settings.setCommonPathSelected(path, selected: false)
        }

        for path in settings.allTrackedPaths {
            settings.setPathEnabled(path, enabled: path.id == settings.mainTrackedPath.id)
        }

        settings.hasPendingScopeChanges = false
        return try await body()
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

    func testColimaPathsCategorizeAsDeveloper() {
        XCTAssertEqual(
            GrowthCategory.categorize(path: "/Users/tester/.colima/_lima/_disks/colima/datadisk"),
            .developer
        )
    }

    func testColimaPathsResolveToDockerSubcategory() {
        XCTAssertEqual(
            GrowthCategory.subcategorize(path: "/Users/tester/.colima/_lima/_disks/colima/datadisk"),
            .docker
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
        XCTAssertEqual(GrowthCategory.categorize(path: item.path), .downloads)
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

    func testAggregatedInventoryMergesTotalsAcrossTrackedPaths() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let secondTrackedPathId = UUID()

            let firstSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let firstSnapshotId = try XCTUnwrap(firstSnapshot.id)
            try await DatabaseManager.shared.replaceCategorySnapshots(
                snapshotId: firstSnapshotId,
                totals: [
                    .applications: 100 * 1024 * 1024,
                    .developer: 40 * 1024 * 1024
                ]
            )

            let secondSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: secondTrackedPathId)
            let secondSnapshotId = try XCTUnwrap(secondSnapshot.id)
            try await DatabaseManager.shared.replaceCategorySnapshots(
                snapshotId: secondSnapshotId,
                totals: [
                    .applications: 25 * 1024 * 1024,
                    .downloads: 10 * 1024 * 1024
                ]
            )

            let aggregation = await BaselineService.shared.getInventoryWithTrends(
                trackedPaths: [
                    TrackedPath(id: trackedPathId, url: URL(fileURLWithPath: "/Users/tester"), displayName: "tester"),
                    TrackedPath(id: secondTrackedPathId, url: URL(fileURLWithPath: "/Applications"), displayName: "Applications")
                ]
            )

            XCTAssertEqual(
                aggregation.inventory.first(where: { $0.category == .applications })?.currentSizeBytes,
                125 * 1024 * 1024
            )
            XCTAssertEqual(
                aggregation.inventory.first(where: { $0.category == .developer })?.currentSizeBytes,
                40 * 1024 * 1024
            )
            XCTAssertEqual(
                aggregation.inventory.first(where: { $0.category == .downloads })?.currentSizeBytes,
                10 * 1024 * 1024
            )
            XCTAssertEqual(aggregation.latestSnapshotIdsByPath.count, 2)
        }
    }

    func testAggregatedSubcategoryBreakdownMergesTrackedPaths() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let secondTrackedPathId = UUID()

            let firstSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let firstSnapshotId = try XCTUnwrap(firstSnapshot.id)
            try await DatabaseManager.shared.addEntries(
                to: firstSnapshotId,
                entries: [
                    ScanResult(path: "/Users/tester/dev/app/node_modules/react/index.js", sizeBytes: 4_096),
                    ScanResult(path: "/Users/tester/dev/app/node_modules/vue/index.js", sizeBytes: 2_048)
                ]
            )

            let secondSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: secondTrackedPathId)
            let secondSnapshotId = try XCTUnwrap(secondSnapshot.id)
            try await DatabaseManager.shared.addEntries(
                to: secondSnapshotId,
                entries: [
                    ScanResult(path: "/Applications/MyApp.app/Contents/Resources/node_modules/pkg-a.js", sizeBytes: 1_024),
                    ScanResult(path: "/Applications/MyApp.app/Contents/Resources/node_modules/pkg-b.js", sizeBytes: 512)
                ]
            )

            let groups = await BaselineService.shared.getSubcategoryBreakdown(
                for: .developer,
                trackedPathsById: [
                    trackedPathId: TrackedPath(id: trackedPathId, url: URL(fileURLWithPath: "/Users/tester"), displayName: "tester"),
                    secondTrackedPathId: TrackedPath(id: secondTrackedPathId, url: URL(fileURLWithPath: "/Applications"), displayName: "Applications")
                ],
                latestSnapshotIdsByPath: [
                    trackedPathId: firstSnapshotId,
                    secondTrackedPathId: secondSnapshotId
                ],
                baselineSnapshotIdsByPath: [:]
            )

            let nodeModules = try XCTUnwrap(groups.first(where: { $0.subcategory == .nodeModules }))
            XCTAssertEqual(nodeModules.fileCount, 4)
            XCTAssertEqual(nodeModules.totalBytes, 7_680)
            XCTAssertEqual(nodeModules.topFiles.count, 4)
        }
    }

    func testInventoryIgnoresHistoricalTrendFallbackWithoutRecentGrowthStory() async throws {
        try await withTemporaryDatabase { trackedPathId, initialSnapshotId in
            try await DatabaseManager.shared.replaceCategorySnapshots(
                snapshotId: initialSnapshotId,
                totals: [.developer: 100 * 1024 * 1024]
            )

            let newerSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let newerSnapshotId = try XCTUnwrap(newerSnapshot.id)
            try await DatabaseManager.shared.replaceCategorySnapshots(
                snapshotId: newerSnapshotId,
                totals: [.developer: 400 * 1024 * 1024]
            )

            let trackedPath = TrackedPath(
                id: trackedPathId,
                url: URL(fileURLWithPath: "/Users/tester/dev"),
                displayName: "dev"
            )

            let inventory = await BaselineService.shared.getInventoryWithTrends(trackedPath: trackedPath)
            let developer = try XCTUnwrap(inventory.first(where: { $0.category == .developer }))

            XCTAssertNil(developer.recentGrowthStory)
            XCTAssertNil(developer.growthTrend)
        }
    }

    func testAggregatedInventoryCombinesMultipleTrackedPaths() async throws {
        try await withEmptyTemporaryDatabase { _ in
            let downloadsPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/archive.zip")
                .path

            let pathAId = UUID()
            let snapshotA = try await DatabaseManager.shared.createSnapshot(trackedPathId: pathAId)
            let snapshotAId = try XCTUnwrap(snapshotA.id)
            try await DatabaseManager.shared.addEntries(
                to: snapshotAId,
                entries: [
                    ScanResult(path: "/Applications/Safari.app", sizeBytes: 200),
                    ScanResult(path: downloadsPath, sizeBytes: 50)
                ]
            )

            let pathBId = UUID()
            let snapshotB = try await DatabaseManager.shared.createSnapshot(trackedPathId: pathBId)
            let snapshotBId = try XCTUnwrap(snapshotB.id)
            try await DatabaseManager.shared.addEntries(
                to: snapshotBId,
                entries: [
                    ScanResult(path: "/Applications/Xcode.app", sizeBytes: 25),
                    ScanResult(path: "/Users/tester/dev/app/node_modules/react/index.js", sizeBytes: 75)
                ]
            )

            let result = await BaselineService.shared.getInventoryWithTrends(
                trackedPaths: [
                    TrackedPath(id: pathAId, url: URL(fileURLWithPath: "/"), displayName: "A"),
                    TrackedPath(id: pathBId, url: URL(fileURLWithPath: "/opt"), displayName: "B")
                ]
            )

            XCTAssertEqual(result.latestSnapshotIdsByPath.count, 2)
            XCTAssertEqual(
                result.inventory.first(where: { $0.category == .applications })?.currentSizeBytes,
                225
            )
            XCTAssertEqual(
                result.inventory.first(where: { $0.category == .downloads })?.currentSizeBytes,
                50
            )
            XCTAssertEqual(
                result.inventory.first(where: { $0.category == .developer })?.currentSizeBytes,
                75
            )
        }
    }

    func testAggregatedSubcategoryBreakdownCombinesMultipleTrackedPaths() async throws {
        try await withEmptyTemporaryDatabase { _ in
            let pathAId = UUID()
            let snapshotA = try await DatabaseManager.shared.createSnapshot(trackedPathId: pathAId)
            let snapshotAId = try XCTUnwrap(snapshotA.id)
            try await DatabaseManager.shared.addEntries(
                to: snapshotAId,
                entries: [
                    ScanResult(path: "/Users/tester/dev/app-a/node_modules/react/index.js", sizeBytes: 100),
                    ScanResult(path: "/Users/tester/dev/app-a/node_modules/vue/index.js", sizeBytes: 200)
                ]
            )

            let pathBId = UUID()
            let snapshotB = try await DatabaseManager.shared.createSnapshot(trackedPathId: pathBId)
            let snapshotBId = try XCTUnwrap(snapshotB.id)
            try await DatabaseManager.shared.addEntries(
                to: snapshotBId,
                entries: [
                    ScanResult(path: "/Users/tester/dev/app-b/node_modules/svelte/index.js", sizeBytes: 300)
                ]
            )

            let groups = await BaselineService.shared.getSubcategoryBreakdown(
                for: .developer,
                trackedPathsById: [
                    pathAId: TrackedPath(id: pathAId, url: URL(fileURLWithPath: "/Users/tester/dev/app-a"), displayName: "A"),
                    pathBId: TrackedPath(id: pathBId, url: URL(fileURLWithPath: "/Users/tester/dev/app-b"), displayName: "B")
                ],
                latestSnapshotIdsByPath: [
                    pathAId: snapshotAId,
                    pathBId: snapshotBId
                ],
                baselineSnapshotIdsByPath: [:]
            )

            let nodeModules = try XCTUnwrap(groups.first(where: { $0.subcategory == .nodeModules }))
            XCTAssertEqual(nodeModules.totalBytes, 600)
            XCTAssertEqual(nodeModules.fileCount, 3)
            XCTAssertEqual(nodeModules.topFiles.first?.path, "/Users/tester/dev/app-b/node_modules/svelte/index.js")
        }
    }

    func testAggregatedSubcategoryBreakdownPreservesBaselineGrowthWhenJournalIsPartial() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = TrackedPath(
                id: trackedPathId,
                url: URL(fileURLWithPath: "/Users/tester/dev"),
                displayName: "dev"
            )

            let baselineSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let baselineSnapshotId = try XCTUnwrap(baselineSnapshot.id)
            try await DatabaseManager.shared.addEntries(
                to: baselineSnapshotId,
                entries: [
                    ScanResult(path: "/Users/tester/dev/app/node_modules/react/index.js", sizeBytes: 100),
                    ScanResult(path: "/Users/tester/dev/app/.build/output.bin", sizeBytes: 200)
                ]
            )

            let currentSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let currentSnapshotId = try XCTUnwrap(currentSnapshot.id)
            try await DatabaseManager.shared.addEntries(
                to: currentSnapshotId,
                entries: [
                    ScanResult(path: "/Users/tester/dev/app/node_modules/react/index.js", sizeBytes: 400),
                    ScanResult(path: "/Users/tester/dev/app/.build/output.bin", sizeBytes: 500)
                ]
            )
            try await DatabaseManager.shared.rebuildWorkingSet(
                from: currentSnapshotId,
                trackedPathId: trackedPathId
            )

            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [
                    DatabaseManager.JournalDeltaKey(category: .developer, subcategory: .nodeModules): 300
                ],
                at: Date()
            )

            let groups = await BaselineService.shared.getSubcategoryBreakdown(
                for: .developer,
                trackedPathsById: [trackedPathId: trackedPath],
                latestSnapshotIdsByPath: [trackedPathId: currentSnapshotId],
                baselineSnapshotIdsByPath: [trackedPathId: baselineSnapshotId]
            )

            XCTAssertEqual(
                groups.first(where: { $0.subcategory == .nodeModules })?.growthBytes,
                300
            )
            XCTAssertEqual(
                groups.first(where: { $0.subcategory == .buildArtifacts })?.growthBytes,
                300
            )
        }
    }

    func testInventoryWithTrendsSkipsJournalFallbackWithoutComparableBaseline() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let oldSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let oldSnapshotId = try XCTUnwrap(oldSnapshot.id)
            try await DatabaseManager.shared.addEntries(
                to: oldSnapshotId,
                entries: (0..<20).map { index in
                    ScanResult(
                        path: "/tmp/project/node_modules/old-\(index).js",
                        sizeBytes: Int64(index + 1) * 1_024
                    )
                }
            )

            let currentSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let currentSnapshotId = try XCTUnwrap(currentSnapshot.id)
            try await DatabaseManager.shared.addEntries(
                to: currentSnapshotId,
                entries: (0..<200).map { index in
                    ScanResult(
                        path: "/tmp/project/node_modules/current-\(index).js",
                        sizeBytes: Int64(index + 1) * 2_048
                    )
                }
            )

            let trackedPath = TrackedPath(
                id: trackedPathId,
                url: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
                displayName: "tester"
            )

            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [
                    DatabaseManager.JournalDeltaKey(category: .developer, subcategory: .nodeModules): 300 * 1024 * 1024
                ]
            )

            let comparison = try await BaselineService.shared.resolveGrowthComparisonSnapshots(
                trackedPathId: trackedPathId
            )
            XCTAssertNil(comparison?.baselineSnapshotId)

            let inventory = await BaselineService.shared.getInventoryWithTrends(trackedPath: trackedPath)
            let developer = try XCTUnwrap(inventory.first(where: { $0.category == .developer }))
            XCTAssertNil(developer.recentGrowthStory)
        }
    }

    func testResolveGrowthComparisonSnapshotsSkipsIncompleteHistory() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let oldSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let oldSnapshotId = try XCTUnwrap(oldSnapshot.id)
            try await DatabaseManager.shared.addEntries(
                to: oldSnapshotId,
                entries: (1...20).map { index in
                    ScanResult(
                        path: "/Users/tester/dev/old/file-\(index).dat",
                        sizeBytes: Int64(index)
                    )
                }
            )

            let baselineSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let baselineSnapshotId = try XCTUnwrap(baselineSnapshot.id)
            try await DatabaseManager.shared.addEntries(
                to: baselineSnapshotId,
                entries: (1...160).map { index in
                    ScanResult(
                        path: "/Users/tester/dev/baseline/file-\(index).dat",
                        sizeBytes: Int64(index)
                    )
                }
            )

            let latestSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let latestSnapshotId = try XCTUnwrap(latestSnapshot.id)
            try await DatabaseManager.shared.addEntries(
                to: latestSnapshotId,
                entries: (1...180).map { index in
                    ScanResult(
                        path: "/Users/tester/dev/latest/file-\(index).dat",
                        sizeBytes: Int64(index)
                    )
                }
            )

            let resolved = try await BaselineService.shared.resolveGrowthComparisonSnapshots(
                trackedPathId: trackedPathId
            )

            XCTAssertEqual(resolved?.currentSnapshotId, latestSnapshotId)
            XCTAssertEqual(resolved?.baselineSnapshotId, baselineSnapshotId)
        }
    }

    func testRecentGrowthStoryDisplayLabelUsesGrowthWindow() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let trackedPath = TrackedPath(
                id: trackedPathId,
                url: URL(fileURLWithPath: "/Users/tester/dev"),
                displayName: "dev"
            )
            let growthBytes = Int64(300 * 1024 * 1024)
            let deltaKey = DatabaseManager.JournalDeltaKey(category: .developer, subcategory: nil)

            let firstBucket = Date().addingTimeInterval(-180)
            let secondBucket = firstBucket.addingTimeInterval(60)

            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [deltaKey: growthBytes],
                at: firstBucket
            )
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [deltaKey: growthBytes],
                at: secondBucket
            )

            let stories = await GrowthJournalService.shared.recentGrowthStories(
                trackedPath: trackedPath,
                retentionDays: 7
            )

            XCTAssertEqual(stories[.developer]?.displayLabel, "2m")
        }
    }

    @MainActor
    func testComparisonSummaryUsesCurrentSnapshotTimestamp() async throws {
        try await withTemporaryDatabase { trackedPathId, initialSnapshotId in
            let entries = (0..<120).map { index in
                ScanResult(
                    path: "/Users/tester/dev/pkg-\(index).dat",
                    sizeBytes: Int64(index + 1)
                )
            }
            try await DatabaseManager.shared.addEntries(to: initialSnapshotId, entries: entries)

            let newerSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let newerSnapshotId = try XCTUnwrap(newerSnapshot.id)
            try await DatabaseManager.shared.addEntries(to: newerSnapshotId, entries: entries)
            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)

            let historicalDate = Date().addingTimeInterval(-(3 * 24 * 60 * 60))
            let currentDate = Date().addingTimeInterval(-(3 * 60 * 60))

            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE snapshot SET createdAt = ? WHERE id = ?",
                    arguments: [historicalDate, initialSnapshotId]
                )
                try db.execute(
                    sql: "UPDATE snapshot SET createdAt = ? WHERE id = ?",
                    arguments: [currentDate, newerSnapshotId]
                )
            }

            let viewModel = MainViewModel()
            viewModel.selectedPath = TrackedPath(
                id: trackedPathId,
                url: URL(fileURLWithPath: "/Users/tester/dev"),
                displayName: "dev"
            )

            await viewModel.loadSnapshots()
            await viewModel.compareSince()

            XCTAssertEqual(
                viewModel.comparisonSummary,
                "\(viewModel.formattedSnapshotDate(currentDate)) vs \(viewModel.formattedSnapshotDate(historicalDate))"
            )
            XCTAssertFalse(viewModel.comparisonSummary?.hasPrefix("Now vs ") ?? false)
        }
    }

    func testGrowthContributorsStayEmptyWithoutLiveWorkingSetGrowth() async throws {
        try await withTemporaryDatabase { trackedPathId, initialSnapshotId in
            let trackedPath = TrackedPath(
                id: trackedPathId,
                url: URL(fileURLWithPath: "/Users/tester/dev"),
                displayName: "dev"
            )
            let filePath = "/Users/tester/dev/node_modules/react/index.js"

            try await DatabaseManager.shared.addEntries(
                to: initialSnapshotId,
                entries: [
                    ScanResult(path: filePath, sizeBytes: 1_024)
                ]
            )

            let newerSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let newerSnapshotId = try XCTUnwrap(newerSnapshot.id)
            try await DatabaseManager.shared.addEntries(
                to: newerSnapshotId,
                entries: [
                    ScanResult(path: filePath, sizeBytes: 4_096)
                ]
            )
            try await DatabaseManager.shared.rebuildWorkingSet(
                from: newerSnapshotId,
                trackedPathId: trackedPath.id
            )

            let contributors = await BaselineService.shared.getGrowthContributors(
                trackedPathId: trackedPath.id,
                snapshotId: newerSnapshotId,
                category: .developer,
                subcategory: .nodeModules
            )

            XCTAssertTrue(contributors.isEmpty)
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

        await watcher.setOnChange { changeBatch in
            if changeBatch.changedPaths.contains(where: { $0.path.hasPrefix(tempDirectory.path) }) {
                XCTAssertFalse(changeBatch.requiresFullRescan)
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

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let (categorySnapshotIDs, subcategorySnapshotCount) = try await dbPool.read { db in
                let categorySnapshotIDs = try Set(
                    Int64.fetchAll(db, sql: "SELECT DISTINCT snapshotId FROM categorySnapshot")
                )
                let subcategorySnapshotCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM subcategorySnapshot"
                ) ?? 0
                return (categorySnapshotIDs, subcategorySnapshotCount)
            }

            XCTAssertEqual(categorySnapshotIDs, Set(remainingSnapshotIDs))
            XCTAssertEqual(subcategorySnapshotCount, retentionCap)
        }
    }

    func testMainViewModelFallsBackToCurrentOnlyWhenOnlyIncompleteBaselineExists() async throws {
        try await withTemporaryDatabase { trackedPathId, _ in
            let currentSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let currentSnapshotId = try XCTUnwrap(currentSnapshot.id)

            let entries = (0..<200).map { index in
                ScanResult(
                    path: "/tmp/project/file-\(index).txt",
                    sizeBytes: Int64(index + 1)
                )
            }
            try await DatabaseManager.shared.addEntries(to: currentSnapshotId, entries: entries)

            let viewModel = await MainActor.run { () -> MainViewModel in
                let model = MainViewModel()
                model.selectedPath = TrackedPath(
                    id: trackedPathId,
                    url: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
                    displayName: "Project"
                )
                return model
            }

            await viewModel.loadSnapshots()
            await viewModel.compareSince()

            await MainActor.run {
                XCTAssertTrue(viewModel.currentOnlyMode)
                XCTAssertTrue(viewModel.deltas.isEmpty)
                XCTAssertEqual(viewModel.currentSnapshotEntries.count, entries.count)
                XCTAssertEqual(
                    viewModel.comparisonWarning,
                    "Recent history is incomplete. Showing the latest snapshot until another full scan is available."
                )
            }
        }
    }

    func testMainViewModelSkipsIncompleteSnapshotWhenSelectingComparisonBaseline() async throws {
        try await withTemporaryDatabase { trackedPathId, _ in
            let baselineSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let baselineSnapshotId = try XCTUnwrap(baselineSnapshot.id)

            let baselineEntries = (0..<200).map { index in
                ScanResult(
                    path: "/tmp/project/file-\(index).txt",
                    sizeBytes: Int64(index + 100)
                )
            }
            try await DatabaseManager.shared.addEntries(to: baselineSnapshotId, entries: baselineEntries)

            _ = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)

            let currentSnapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
            let currentSnapshotId = try XCTUnwrap(currentSnapshot.id)
            let currentEntries = baselineEntries.enumerated().map { index, entry in
                ScanResult(
                    path: entry.path,
                    sizeBytes: index == 0 ? entry.sizeBytes + 50 : entry.sizeBytes
                )
            }
            try await DatabaseManager.shared.addEntries(to: currentSnapshotId, entries: currentEntries)

            let viewModel = await MainActor.run { () -> MainViewModel in
                let model = MainViewModel()
                model.selectedPath = TrackedPath(
                    id: trackedPathId,
                    url: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
                    displayName: "Project"
                )
                return model
            }

            await viewModel.loadSnapshots()
            await viewModel.compareSince()

            await MainActor.run {
                XCTAssertFalse(viewModel.currentOnlyMode)
                XCTAssertEqual(viewModel.deltas.count, 1)
                XCTAssertEqual(viewModel.deltas.first?.oldSizeBytes, baselineEntries[0].sizeBytes)
                XCTAssertEqual(viewModel.deltas.first?.newSizeBytes, currentEntries[0].sizeBytes)
                XCTAssertEqual(
                    viewModel.comparisonWarning,
                    "Skipped 1 incomplete snapshot in the comparison window."
                )
            }
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

    func testRecentChangeRefreshPrefersFileOverTrackedRootDirectoryEvent() async throws {
        try await withTemporaryDatabase { [self] trackedPathId, snapshotId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrRecentChangeRoot")
            defer {
                try? FileManager.default.removeItem(at: tempDirectory)
            }

            let changedFileURL = tempDirectory.appendingPathComponent("changed.txt")
            let untouchedFileURL = tempDirectory.appendingPathComponent("untouched.txt")
            try Data(repeating: 0x01, count: 128).write(to: changedFileURL)
            try Data(repeating: 0x02, count: 256).write(to: untouchedFileURL)

            try await DatabaseManager.shared.addEntries(
                to: snapshotId,
                entries: [
                    ScanResult(path: changedFileURL.path, sizeBytes: 128),
                    ScanResult(path: untouchedFileURL.path, sizeBytes: 256)
                ]
            )
            let initialUpdatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
            try await DatabaseManager.shared.rebuildWorkingSet(
                from: snapshotId,
                trackedPathId: trackedPathId,
                updatedAt: initialUpdatedAt
            )

            try Data(repeating: 0x03, count: 512).write(to: changedFileURL)

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")
            let result = await RecentChangeService.shared.refreshChangedPaths(
                Set([tempDirectory, changedFileURL]),
                trackedPath: trackedPath
            )

            guard case .updated = result else {
                XCTFail("recent change refresh should stay incremental when a tracked-root directory event accompanies a file change")
                return
            }

            let metadata = try await self.workingSetMetadataByPath()
            let changed = try XCTUnwrap(metadata[changedFileURL.path])
            let untouched = try XCTUnwrap(metadata[untouchedFileURL.path])

            XCTAssertEqual(changed.sizeBytes, 512)
            XCTAssertGreaterThan(changed.updatedAt, initialUpdatedAt)
            XCTAssertEqual(untouched.sizeBytes, 256)
            XCTAssertEqual(untouched.updatedAt, initialUpdatedAt)
        }
    }

    func testRecentChangeRefreshUpdatesVisibleInventoryFromWorkingSet() async throws {
        try await withTemporaryDatabase { [self] trackedPathId, snapshotId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrRecentChangeInventory")
            defer {
                try? FileManager.default.removeItem(at: tempDirectory)
            }

            let changedFileURL = tempDirectory.appendingPathComponent("changed.txt")
            try Data(repeating: 0x0A, count: 128).write(to: changedFileURL)

            try await DatabaseManager.shared.addEntries(
                to: snapshotId,
                entries: [ScanResult(path: changedFileURL.path, sizeBytes: 128)]
            )
            try await DatabaseManager.shared.rebuildWorkingSet(
                from: snapshotId,
                trackedPathId: trackedPathId,
                updatedAt: Date(timeIntervalSinceReferenceDate: 6_000)
            )

            try Data(repeating: 0x0B, count: 512).write(to: changedFileURL)

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")
            let result = await RecentChangeService.shared.refreshChangedPaths([changedFileURL], trackedPath: trackedPath)

            guard case .updated = result else {
                XCTFail("recent change refresh should update inventory incrementally")
                return
            }

            let inventory = await BaselineService.shared.getInventoryWithTrends(trackedPath: trackedPath)
            XCTAssertEqual(inventory.first(where: { $0.category == .other })?.currentSizeBytes, 512)

            let snapshots = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPath.id)
            XCTAssertEqual(snapshots.count, 1)
        }
    }

    func testRecentChangeRefreshPrefersFileOverAncestorDirectoryEvent() async throws {
        try await withTemporaryDatabase { [self] trackedPathId, snapshotId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrRecentChangeAncestor")
            defer {
                try? FileManager.default.removeItem(at: tempDirectory)
            }

            let directoryURL = tempDirectory.appendingPathComponent("Library", isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let changedFileURL = directoryURL.appendingPathComponent("changed.dat")
            let untouchedFileURL = directoryURL.appendingPathComponent("untouched.dat")
            try Data(repeating: 0x04, count: 64).write(to: changedFileURL)
            try Data(repeating: 0x05, count: 96).write(to: untouchedFileURL)

            try await DatabaseManager.shared.addEntries(
                to: snapshotId,
                entries: [
                    ScanResult(path: changedFileURL.path, sizeBytes: 64),
                    ScanResult(path: untouchedFileURL.path, sizeBytes: 96)
                ]
            )
            let initialUpdatedAt = Date(timeIntervalSinceReferenceDate: 2_000)
            try await DatabaseManager.shared.rebuildWorkingSet(
                from: snapshotId,
                trackedPathId: trackedPathId,
                updatedAt: initialUpdatedAt
            )

            try Data(repeating: 0x06, count: 160).write(to: changedFileURL)

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")
            let result = await RecentChangeService.shared.refreshChangedPaths(
                Set([directoryURL, changedFileURL]),
                trackedPath: trackedPath
            )

            guard case .updated = result else {
                XCTFail("recent change refresh should keep the file-level target when an ancestor directory event is also present")
                return
            }

            let metadata = try await self.workingSetMetadataByPath()
            let changed = try XCTUnwrap(metadata[changedFileURL.path])
            let untouched = try XCTUnwrap(metadata[untouchedFileURL.path])

            XCTAssertEqual(changed.sizeBytes, 160)
            XCTAssertGreaterThan(changed.updatedAt, initialUpdatedAt)
            XCTAssertEqual(untouched.sizeBytes, 96)
            XCTAssertEqual(untouched.updatedAt, initialUpdatedAt)
        }
    }

    func testRecentChangeRefreshProcessesMoreThanTwentyFourFileTargets() async throws {
        try await withTemporaryDatabase { [self] trackedPathId, snapshotId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrRecentChangeBatch")
            defer {
                try? FileManager.default.removeItem(at: tempDirectory)
            }

            let fileURLs = (0..<30).map { index in
                tempDirectory.appendingPathComponent("file-\(index).bin")
            }

            for fileURL in fileURLs {
                try Data(repeating: 0x07, count: 32).write(to: fileURL)
            }

            try await DatabaseManager.shared.addEntries(
                to: snapshotId,
                entries: fileURLs.map { ScanResult(path: $0.path, sizeBytes: 32) }
            )
            try await DatabaseManager.shared.rebuildWorkingSet(
                from: snapshotId,
                trackedPathId: trackedPathId,
                updatedAt: Date(timeIntervalSinceReferenceDate: 3_000)
            )

            for (index, fileURL) in fileURLs.enumerated() {
                try Data(repeating: UInt8(index), count: 64).write(to: fileURL)
            }

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")
            let result = await RecentChangeService.shared.refreshChangedPaths(Set(fileURLs), trackedPath: trackedPath)

            guard case .updated = result else {
                XCTFail("recent change refresh should stay incremental for larger file batches")
                return
            }

            let metadata = try await self.workingSetMetadataByPath()
            XCTAssertEqual(metadata.count, 30)
            XCTAssertEqual(metadata.values.reduce(0) { $0 + $1.sizeBytes }, 30 * 64)
        }
    }

    func testRecentChangeRefreshPromotesTrackedRootDirectoryEventToFullScan() async throws {
        try await withTemporaryDatabase { [self] trackedPathId, snapshotId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrRecentChangeRootOnly")
            defer {
                try? FileManager.default.removeItem(at: tempDirectory)
            }

            let fileURL = tempDirectory.appendingPathComponent("existing.bin")
            try Data(repeating: 0x08, count: 128).write(to: fileURL)

            try await DatabaseManager.shared.addEntries(
                to: snapshotId,
                entries: [ScanResult(path: fileURL.path, sizeBytes: 128)]
            )
            try await DatabaseManager.shared.rebuildWorkingSet(
                from: snapshotId,
                trackedPathId: trackedPathId,
                updatedAt: Date(timeIntervalSinceReferenceDate: 4_000)
            )

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")
            let result = await RecentChangeService.shared.refreshChangedPaths([tempDirectory], trackedPath: trackedPath)

            guard case .needsFullScan = result else {
                XCTFail("tracked-root directory events should promote to a full scan instead of rescanning the entire root incrementally")
                return
            }

            let metadata = try await self.workingSetMetadataByPath()
            XCTAssertEqual(metadata[fileURL.path]?.sizeBytes, 128)

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let journalCount = try await dbPool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalBucket") ?? 0
            }
            XCTAssertEqual(journalCount, 0)
        }
    }

    func testRecentChangeRefreshPromotesLargeFileBatchToFullScan() async throws {
        try await withTemporaryDatabase { [self] trackedPathId, snapshotId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrRecentChangeOverflow")
            defer {
                try? FileManager.default.removeItem(at: tempDirectory)
            }

            let fileURLs = (0..<193).map { index in
                tempDirectory.appendingPathComponent("file-\(index).bin")
            }

            for fileURL in fileURLs {
                try Data(repeating: 0x09, count: 32).write(to: fileURL)
            }

            try await DatabaseManager.shared.addEntries(
                to: snapshotId,
                entries: fileURLs.map { ScanResult(path: $0.path, sizeBytes: 32) }
            )
            try await DatabaseManager.shared.rebuildWorkingSet(
                from: snapshotId,
                trackedPathId: trackedPathId,
                updatedAt: Date(timeIntervalSinceReferenceDate: 5_000)
            )

            for (index, fileURL) in fileURLs.enumerated() {
                try Data(repeating: UInt8(index % 255), count: 64).write(to: fileURL)
            }

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")
            let result = await RecentChangeService.shared.refreshChangedPaths(Set(fileURLs), trackedPath: trackedPath)

            guard case .needsFullScan = result else {
                XCTFail("oversized incremental file batches should promote to a full scan")
                return
            }

            let metadata = try await self.workingSetMetadataByPath()
            XCTAssertEqual(metadata.count, 193)
            XCTAssertEqual(metadata.values.reduce(0) { $0 + $1.sizeBytes }, 193 * 32)

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let journalCount = try await dbPool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalBucket") ?? 0
            }
            XCTAssertEqual(journalCount, 0)
        }
    }

    func testRecentChangeRefreshIgnoresChangesBeforeFirstSnapshot() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PrunrRecentChange-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDirectory)
            }

            let fileURL = tempDirectory.appendingPathComponent("before-baseline.txt")
            try Data(repeating: 0xAB, count: 512).write(to: fileURL)

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")
            let result = await RecentChangeService.shared.refreshChangedPaths(
                Set([fileURL]),
                trackedPath: trackedPath
            )
            guard case .noChanges = result else {
                XCTFail("recent change refresh should be ignored before the first snapshot")
                return
            }

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let counts = try await dbPool.read { db in
                (
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workingSetEntry") ?? 0,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalBucket") ?? 0
                )
            }

            XCTAssertEqual(counts.0, 0)
            XCTAssertEqual(counts.1, 0)
        }
    }

    func testRecentChangeRefreshUpdatesInventoryFromWorkingSetWithoutNewSnapshot() async throws {
        try await withTemporaryDatabase { [self] trackedPathId, snapshotId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrRecentChangeInventory")
            defer {
                try? FileManager.default.removeItem(at: tempDirectory)
            }

            let modulesDirectory = tempDirectory
                .appendingPathComponent("app/node_modules", isDirectory: true)
            try FileManager.default.createDirectory(at: modulesDirectory, withIntermediateDirectories: true)

            let fileURL = modulesDirectory.appendingPathComponent("react.js")
            try Data(repeating: 0xAA, count: 128).write(to: fileURL)

            try await DatabaseManager.shared.addEntries(
                to: snapshotId,
                entries: [ScanResult(path: fileURL.path, sizeBytes: 128)]
            )
            try await DatabaseManager.shared.rebuildWorkingSet(
                from: snapshotId,
                trackedPathId: trackedPathId,
                updatedAt: Date(timeIntervalSinceReferenceDate: 6_000)
            )

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")
            let initialInventory = await BaselineService.shared.getInventoryWithTrends(trackedPath: trackedPath)
            XCTAssertEqual(
                initialInventory.first(where: { $0.category == .developer })?.currentSizeBytes,
                128
            )

            try Data(repeating: 0xBB, count: 512).write(to: fileURL)

            let result = await RecentChangeService.shared.refreshChangedPaths([fileURL], trackedPath: trackedPath)
            guard case .updated = result else {
                XCTFail("recent change refresh should stay incremental for a single file update")
                return
            }

            let refreshedInventory = await BaselineService.shared.getInventoryWithTrends(trackedPath: trackedPath)
            XCTAssertEqual(
                refreshedInventory.first(where: { $0.category == .developer })?.currentSizeBytes,
                512
            )

            let snapshots = try await DatabaseManager.shared.fetchRecentSnapshots(trackedPathId: trackedPathId, limit: 10)
            XCTAssertEqual(snapshots.count, 1)
        }
    }

    func testRecentChangeRefreshAddsNewCategoryToInventoryFromWorkingSet() async throws {
        try await withTemporaryDatabase { [self] trackedPathId, snapshotId in
            let tempDirectory = try self.createTrackedPathDirectory(named: "PrunrRecentChangeNewCategory")
            defer {
                try? FileManager.default.removeItem(at: tempDirectory)
            }

            let existingFileURL = tempDirectory.appendingPathComponent("existing.txt")
            try Data(repeating: 0xCC, count: 64).write(to: existingFileURL)

            try await DatabaseManager.shared.addEntries(
                to: snapshotId,
                entries: [ScanResult(path: existingFileURL.path, sizeBytes: 64)]
            )
            try await DatabaseManager.shared.rebuildWorkingSet(
                from: snapshotId,
                trackedPathId: trackedPathId,
                updatedAt: Date(timeIntervalSinceReferenceDate: 7_000)
            )

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")
            let initialInventory = await BaselineService.shared.getInventoryWithTrends(trackedPath: trackedPath)
            XCTAssertEqual(initialInventory.first(where: { $0.category == .developer })?.currentSizeBytes, nil)
            XCTAssertEqual(
                initialInventory.first(where: { $0.category == .other })?.currentSizeBytes,
                64
            )

            let modulesDirectory = tempDirectory
                .appendingPathComponent("app/node_modules", isDirectory: true)
            try FileManager.default.createDirectory(at: modulesDirectory, withIntermediateDirectories: true)

            let newFileURL = modulesDirectory.appendingPathComponent("pkg.js")
            try Data(repeating: 0xDD, count: 256).write(to: newFileURL)

            let result = await RecentChangeService.shared.refreshChangedPaths(
                Set([newFileURL]),
                trackedPath: trackedPath
            )
            guard case .updated = result else {
                XCTFail("recent change refresh should add a newly created file incrementally")
                return
            }

            let refreshedInventory = await BaselineService.shared.getInventoryWithTrends(trackedPath: trackedPath)
            XCTAssertEqual(
                refreshedInventory.first(where: { $0.category == .other })?.currentSizeBytes,
                64
            )
            XCTAssertEqual(
                refreshedInventory.first(where: { $0.category == .developer })?.currentSizeBytes,
                256
            )
        }
    }

    func testFirstBaselineClearsStaleRealtimeGrowthState() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PrunrBaseline-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDirectory)
            }

            let fileURL = tempDirectory.appendingPathComponent("existing.txt")
            try Data(repeating: 0xCD, count: 2_048).write(to: fileURL)

            _ = try await DatabaseManager.shared.replaceWorkingSetSubtree(
                trackedPathId: trackedPathId,
                rootPath: tempDirectory.path,
                entries: [ScanResult(path: fileURL.path, sizeBytes: 2_048)]
            )

            try await DatabaseManager.shared.upsertGrowthJournalBuckets(
                trackedPathId: trackedPathId,
                bucketStart: Date(),
                deltas: [
                    DatabaseManager.JournalDeltaKey(category: .other, subcategory: nil): 2_048
                ]
            )

            let trackedPath = TrackedPath(id: trackedPathId, url: tempDirectory, displayName: "Temp")
            let snapshot = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            let snapshotId = try XCTUnwrap(snapshot.id)

            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let journalCount = try await dbPool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalBucket") ?? 0
            }
            XCTAssertEqual(journalCount, 0)

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

    func testScanScopeAccessAllowsReachableTemporaryDirectory() async throws {
        let directory = try createTrackedPathDirectory(named: "PrunrAccess")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let report = await MainActor.run {
            PermissionsService.shared.evaluateScanScopeAccess(scanRootURLs: [directory])
        }

        XCTAssertTrue(report.isGranted)
        XCTAssertTrue(report.blockedLocations.isEmpty)
    }

    @MainActor
    func testMenuBarManagerAggregatesPartialScanCategoryTotalsAcrossTrackedPaths() {
        let manager = MenuBarManager()
        let firstPath = TrackedPath(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/prunr-path-one", isDirectory: true),
            displayName: "One"
        )
        let secondPath = TrackedPath(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/prunr-path-two", isDirectory: true),
            displayName: "Two"
        )

        manager.applyPartialCategoryTotals(
            from: firstPath,
            totals: [.downloads: 100, .developer: 20]
        )
        manager.applyPartialCategoryTotals(
            from: secondPath,
            totals: [.downloads: 50, .developer: 5]
        )

        XCTAssertEqual(
            manager.stableCategories.first(where: { $0.category == .downloads })?.currentSizeBytes,
            150
        )
        XCTAssertEqual(
            manager.stableCategories.first(where: { $0.category == .developer })?.currentSizeBytes,
            25
        )
    }

    @MainActor
    func testMenuBarManagerRecentChangeRefreshUsesLiveSubcategoryStructureForAffectedCategory() async throws {
        let trackedRoot = try createTrackedPathDirectory(named: "PrunrIssue6")
        defer {
            try? FileManager.default.removeItem(at: trackedRoot)
        }

        try await withEmptyTemporaryDatabase { _ in
            try await self.withIsolatedTrackedPathSettings(mainBaseURL: trackedRoot) {
                let trackedPath = SettingsStore.shared.mainTrackedPath
                let manager = MenuBarManager()

                let snapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPath.id)
                let snapshotId = try XCTUnwrap(snapshot.id)
                try await DatabaseManager.shared.addEntries(
                    to: snapshotId,
                    entries: [
                        ScanResult(
                            path: trackedRoot.appendingPathComponent("app/.build/output.bin").path,
                            sizeBytes: 128_000
                        )
                    ]
                )
                try await DatabaseManager.shared.rebuildWorkingSet(
                    from: snapshotId,
                    trackedPathId: trackedPath.id
                )

                await manager.loadInventoryFromLatestSnapshot(
                    refreshedAt: Date(),
                    invalidateSubcategoryCache: true,
                    force: true
                )

                let liveFile = trackedRoot.appendingPathComponent("app/node_modules/react/index.js")
                try FileManager.default.createDirectory(
                    at: liveFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let liveGrowthBytes = 2 * 1_024 * 1_024
                try Data(repeating: 0x41, count: liveGrowthBytes).write(to: liveFile)

                manager.recordFileWatcherChangeBatch(
                    FSEventsWatcher.ChangeBatch(
                        changedPaths: [liveFile],
                        requiresFullRescan: false
                    )
                )
                await manager.performRecentChangeRefresh(allowFullRefresh: false)

                XCTAssertNotNil(manager.lastDetectedChangeAt)
                XCTAssertEqual(
                    manager.growingCategories.first(where: { $0.category == .developer })?.currentSizeBytes,
                    Int64(128_000 + liveGrowthBytes)
                )

                let refreshedInventory = await BaselineService.shared.getInventoryWithTrends(trackedPath: trackedPath)
                XCTAssertEqual(
                    refreshedInventory.first(where: { $0.category == .developer })?.currentSizeBytes,
                    Int64(128_000 + liveGrowthBytes)
                )

                let liveGroups = await BaselineService.shared.getSubcategoryBreakdownFromWorkingSet(
                    for: .developer,
                    trackedPathsById: [trackedPath.id: trackedPath],
                    baselineSnapshotIdsByPath: [trackedPath.id: snapshotId]
                )
                XCTAssertEqual(
                    liveGroups.first(where: { $0.subcategory == .nodeModules })?.growthBytes,
                    Int64(liveGrowthBytes)
                )

                let groups = await manager.loadSubcategoryBreakdown(for: .developer)
                let nodeModules = try XCTUnwrap(groups.first(where: { $0.subcategory == .nodeModules }))
                XCTAssertEqual(nodeModules.growthBytes, Int64(liveGrowthBytes))

                let contributors = await manager.loadGrowthContributors(
                    for: nodeModules,
                    category: .developer
                )
                XCTAssertEqual(contributors.first?.path, liveFile.path)
                XCTAssertEqual(contributors.first?.growthBytes, Int64(liveGrowthBytes))
            }
        }
    }

    @MainActor
    func testMenuBarManagerRetainsPendingRefreshWhenWatcherRequiresFullRescan() async {
        let manager = MenuBarManager()

        manager.recordFileWatcherChangeBatch(
            FSEventsWatcher.ChangeBatch(changedPaths: [], requiresFullRescan: true)
        )
        XCTAssertTrue(manager.hasPendingRecentChanges)

        await manager.performRecentChangeRefresh(allowFullRefresh: false)

        XCTAssertTrue(manager.hasPendingRecentChanges)
    }
}
