import XCTest
@testable import Prunr

@MainActor
final class MenuBarManagerRegressionTests: PrunrTestCase {
    func testFooterActivityShowsReliableFullScanPercentage() {
        let manager = MenuBarManager()
        manager.isAutoScanning = true
        manager.scanProgressPercentage = 0.374
        manager.hasReliableScanProgressEstimate = true

        XCTAssertEqual(
            manager.footerActivity,
            .fullScan(phase: .scanning, percentage: 37)
        )
        XCTAssertEqual(manager.footerActivity.text, "Scanning 37%")
    }

    func testFooterActivityShowsFullScanPhaseInsteadOfMisleadingPercentage() {
        let manager = MenuBarManager()
        manager.isLoading = true
        manager.isAnalyzingChanges = true
        manager.scanProgressPercentage = 1
        manager.hasReliableScanProgressEstimate = true

        XCTAssertEqual(
            manager.footerActivity,
            .fullScan(phase: .analyzing, percentage: nil)
        )
        XCTAssertEqual(manager.footerActivity.text, "Analyzing inventory…")
    }

    func testFooterActivityPrioritizesAutomaticFullScanOverQueuedChanges() {
        let manager = MenuBarManager()
        manager.isAutoScanning = true
        manager.scanProgressPercentage = 0.5
        manager.hasReliableScanProgressEstimate = true
        manager.recordFileWatcherChangeBatch(
            FSEventsWatcher.ChangeBatch(
                changedPaths: [],
                requiresFullRescan: false,
                dirtyReason: "stream-dropped",
                rawEventCount: 1
            )
        )

        XCTAssertEqual(
            manager.footerActivity,
            .fullScan(phase: .scanning, percentage: 50)
        )
    }

    func testFooterActivityDescribesManualStorageCheckOnly() {
        let manager = MenuBarManager()
        manager.isCheckingGrowth = true
        XCTAssertEqual(manager.footerActivity, .checkingChanges)
        XCTAssertEqual(manager.footerActivity.text, "Checking storage…")

        manager.isCheckingGrowth = false
        manager.isProcessingRecentChanges = true
        XCTAssertEqual(manager.footerActivity, .idle)
    }

    func testFooterActivityOnlyShowsExceptionalQueuedReconciliation() {
        let dirtyManager = MenuBarManager()
        dirtyManager.recordFileWatcherChangeBatch(
            FSEventsWatcher.ChangeBatch(
                changedPaths: [],
                requiresFullRescan: false,
                dirtyReason: "stream-dropped",
                rawEventCount: 1
            )
        )
        XCTAssertEqual(dirtyManager.footerActivity, .reconciliationQueued)
        XCTAssertEqual(dirtyManager.footerActivity.text, "Full refresh queued")

        let normalManager = MenuBarManager()
        normalManager.hasPendingRecentChanges = true
        XCTAssertEqual(normalManager.footerActivity, .idle)
    }

    func testFooterActivityIsIdleWithoutCurrentOrQueuedWork() {
        let manager = MenuBarManager()

        XCTAssertEqual(manager.footerActivity, .idle)
    }

    func testDiagnosticsTailKeepsNewestCompleteRecords() {
        let data = Data("old-record\nnewest-record\n".utf8)

        let tail = DiagnosticsReporter.newestCompleteRecords(in: data, maximumBytes: 16)

        XCTAssertEqual(String(decoding: tail, as: UTF8.self), "newest-record\n")
    }

    func testDiagnosticsTailDropsAnOversizedPartialRecord() {
        let data = Data(repeating: 0x61, count: 32)

        let tail = DiagnosticsReporter.newestCompleteRecords(in: data, maximumBytes: 16)

        XCTAssertTrue(tail.isEmpty)
    }

    func testDiagnosticsScopeSummaryDoesNotContainPathOrFolderNames() {
        let context = DiagnosticsAppContext(
            scopePathCount: 2,
            enabledPathCount: 2,
            watchedPathCount: 2,
            protectedTraversalConfirmed: true,
            usedBytes: 0,
            totalBytes: 0,
            freeBytes: 0,
            categoryCount: 0,
            growingCount: 0,
            stableCount: 0,
            fullScanRunning: false,
            pendingRecentChanges: false,
            noBaseline: false,
            lastFullScanCompletedAt: nil
        )

        let summary = DiagnosticsReporter.scopeSummary(for: context)

        XCTAssertEqual(summary, "scope: roots=2 enabled=2 watched=2 protectedTraversal=true")
        XCTAssertFalse(summary.contains("/Users/"))
        XCTAssertFalse(summary.contains("AcmeCorp"))
    }

    func testDiagnosticsRedactsLegacyUserAndVolumePaths() {
        let text = "scope: /Users/jane/Work/AcmeCorp and /Volumes/Archive/Private\n"

        let redacted = DiagnosticsReporter.redactingFilesystemPaths(in: text)

        XCTAssertEqual(redacted, "scope: <redacted-path> and <redacted-path>\n")
        XCTAssertFalse(redacted.contains("jane"))
        XCTAssertFalse(redacted.contains("AcmeCorp"))
        XCTAssertFalse(redacted.contains("Archive"))
    }

    func testDiagnosticsRedactsTildePaths() {
        let text = "opened ~/Library/Caches/AcmeCorp/tmp.log\n"

        let redacted = DiagnosticsReporter.redactingFilesystemPaths(in: text)

        XCTAssertEqual(redacted, "opened <redacted-path>\n")
        XCTAssertFalse(redacted.contains("Library"))
        XCTAssertFalse(redacted.contains("AcmeCorp"))
    }

    func testAppDelegateKeepsMenuBarAppAliveAfterLastWindowCloses() {
        let delegate = AppDelegate()

        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testEqualSizeCategoriesRemainDeterministicallySortedByName() {
        let manager = MenuBarManager()
        manager.allCategories = [
            CategoryInventoryItem(category: .downloads, currentSizeBytes: 100, recentGrowthStory: nil),
            CategoryInventoryItem(category: .applications, currentSizeBytes: 100, recentGrowthStory: nil),
            CategoryInventoryItem(category: .developer, currentSizeBytes: 100, recentGrowthStory: nil)
        ]

        XCTAssertEqual(
            manager.sortedCategories.map(\.category),
            [.applications, .developer, .downloads]
        )
    }

    func testEqualSizeGrowingCategoriesRemainDeterministicallySortedByName() {
        let manager = MenuBarManager()
        let now = Date()
        manager.allCategories = [
            CategoryInventoryItem(
                category: .downloads,
                currentSizeBytes: 100,
                recentGrowthStory: RecentGrowthStory(
                    category: .downloads,
                    subcategory: nil,
                    deltaBytes: 2_000_000,
                    startedAt: now,
                    endedAt: now
                )
            ),
            CategoryInventoryItem(
                category: .applications,
                currentSizeBytes: 100,
                recentGrowthStory: RecentGrowthStory(
                    category: .applications,
                    subcategory: nil,
                    deltaBytes: 2_000_000,
                    startedAt: now,
                    endedAt: now
                )
            )
        ]

        XCTAssertEqual(
            manager.sortedCategories.map(\.category),
            [.applications, .downloads]
        )
    }

    private func item(
        _ category: GrowthCategory,
        size: Int64,
        delta: Int64? = nil
    ) -> CategoryInventoryItem {
        let now = Date()
        return CategoryInventoryItem(
            category: category,
            currentSizeBytes: size,
            recentGrowthStory: delta.map {
                RecentGrowthStory(
                    category: category,
                    subcategory: nil,
                    deltaBytes: $0,
                    startedAt: now,
                    endedAt: now
                )
            }
        )
    }

    /// Change-rank, absolute: a −20 GB event outranks a +2 GB one, and both
    /// outrank a 546 GB category that didn't move.
    func testCategoriesRankByAbsoluteChangeThenBySize() {
        let manager = MenuBarManager()
        let gb: Int64 = 1024 * 1024 * 1024
        manager.allCategories = [
            item(.other, size: 546 * gb),
            item(.downloads, size: 2 * gb, delta: 2 * gb),
            item(.developer, size: 121 * gb, delta: -20 * gb),
            item(.audioProduction, size: 12 * gb)
        ]

        XCTAssertEqual(
            manager.sortedCategories.map(\.category),
            [.developer, .downloads, .other, .audioProduction]
        )
    }

    /// Sub-floor movers rank with the unchanged rows (by size), but their bytes
    /// still count toward the header.
    func testSubFloorMoversRankBySizeAndStillCountInHeader() {
        let manager = MenuBarManager()
        let gb: Int64 = 1024 * 1024 * 1024
        manager.allCategories = [
            item(.other, size: 546 * gb, delta: 800_000),
            item(.audioProduction, size: 12 * gb, delta: 900_000),
            item(.downloads, size: 2 * gb, delta: 2 * gb)
        ]

        XCTAssertEqual(
            manager.sortedCategories.map(\.category),
            [.downloads, .other, .audioProduction]
        )
        XCTAssertEqual(manager.changedCategories.map(\.category), [.downloads])
        XCTAssertEqual(manager.overallGrowthBytes, 2 * gb + 800_000 + 900_000)
        XCTAssertNil(manager.allCategories.first { $0.category == .other }?.renderableGrowthDeltaBytes)
    }

    /// Delete 20 GB from one category, add 1 GB to another → header −19 GB.
    func testHeaderIsSignedSumOfAllCategoryDeltas() {
        let manager = MenuBarManager()
        let gb: Int64 = 1024 * 1024 * 1024
        manager.allCategories = [
            item(.developer, size: 100 * gb, delta: -20 * gb),
            item(.downloads, size: 5 * gb, delta: 1 * gb),
            item(.other, size: 400 * gb)
        ]

        XCTAssertEqual(manager.overallGrowthBytes, -19 * gb)
    }

    func testInitialSubcategoryWarmupDoesNotRepeatSameCategorySet() {
        let manager = MenuBarManager()

        manager.preloadInitialSubcategoryBreakdownsIfNeeded(for: [.developer, .downloads])
        XCTAssertEqual(manager.subcategoryBreakdownLoadingCategories, [.developer, .downloads])

        manager.subcategoryBreakdownLoadingCategories = []
        manager.preloadInitialSubcategoryBreakdownsIfNeeded(for: [.downloads, .developer])

        XCTAssertTrue(manager.subcategoryBreakdownLoadingCategories.isEmpty)
    }

    func testUpdateBannerVisibilityTracksDismissedVersion() {
        let manager = MenuBarManager()
        manager.isUpdaterAvailable = true

        manager.notifyUpdateAvailable(shortVersion: "9.9.9-test", buildVersion: "1")
        XCTAssertTrue(manager.showsUpdateAvailableBanner)

        manager.dismissUpdateBanner()
        XCTAssertFalse(manager.showsUpdateAvailableBanner)

        manager.notifyUpdateAvailable(shortVersion: "9.9.9-test", buildVersion: "2")
        XCTAssertTrue(manager.showsUpdateAvailableBanner)

        manager.notifyUpdateNotAvailable()
        XCTAssertFalse(manager.showsUpdateAvailableBanner)
    }

    func testUpdateBannerHiddenWhenAlreadyOnOfferedVersion() {
        let manager = MenuBarManager()
        manager.isUpdaterAvailable = true

        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

        manager.notifyUpdateAvailable(shortVersion: short, buildVersion: build)
        XCTAssertFalse(manager.showsUpdateAvailableBanner)
    }

    // MARK: - Realtime watch-set home clamping

    private let home = URL(fileURLWithPath: "/Users/tester")

    func testWatchPathInsideHomeIsWatchedAsIs() {
        let scope = home.appendingPathComponent("Downloads")
        XCTAssertEqual(
            MenuBarManager.clampWatchURLs(for: [scope], home: home).map(\.path),
            [scope.path]
        )
    }

    func testRootScopeClampsToHome() {
        XCTAssertEqual(
            MenuBarManager.clampWatchURLs(for: [URL(fileURLWithPath: "/")], home: home).map(\.path),
            [home.path]
        )
    }

    func testHomeAncestorScopeClampsToHome() {
        // /Users is an ancestor of /Users/tester → clamp up to home.
        XCTAssertEqual(
            MenuBarManager.clampWatchURLs(for: [URL(fileURLWithPath: "/Users")], home: home).map(\.path),
            [home.path]
        )
    }

    func testDisjointBoundedScopeIsWatchedAsIs() {
        // An explicitly-added scope outside home (ext. volume, /Library, a temp dir)
        // is bounded and realistic — keep watching it as before. Only ancestors of
        // home get clamped, so these pass through untouched.
        let scopes = [URL(fileURLWithPath: "/Library"), URL(fileURLWithPath: "/Users/someoneelse")]
        let result = MenuBarManager.clampWatchURLs(for: scopes, home: home).map(\.path)
        XCTAssertEqual(Set(result), Set(scopes.map(\.path)))
    }

    func testHomeItselfIsWatched() {
        XCTAssertEqual(
            MenuBarManager.clampWatchURLs(for: [home], home: home).map(\.path),
            [home.path]
        )
    }

    func testNestedScopesDedupeToOutermostRoot() {
        // Root collapses everything under home into a single home watch root.
        let result = MenuBarManager.clampWatchURLs(
            for: [
                URL(fileURLWithPath: "/"),
                home.appendingPathComponent("Downloads"),
                home.appendingPathComponent("Library/Caches")
            ],
            home: home
        )
        XCTAssertEqual(result.map(\.path), [home.path])
    }

    func testSiblingHomeSubfoldersAreKeptSeparate() {
        let downloads = home.appendingPathComponent("Downloads")
        let developer = home.appendingPathComponent("Developer")
        let result = MenuBarManager.clampWatchURLs(for: [downloads, developer], home: home).map(\.path)
        XCTAssertEqual(Set(result), Set([downloads.path, developer.path]))
        XCTAssertEqual(result.count, 2)
    }

    func testMixedHomeAndDisjointScopesKeepsBoth() {
        // A home subfolder and a bounded out-of-home scope are both watched.
        let downloads = home.appendingPathComponent("Downloads")
        let library = URL(fileURLWithPath: "/Library")
        let result = MenuBarManager.clampWatchURLs(for: [downloads, library], home: home).map(\.path)
        XCTAssertEqual(Set(result), Set([downloads.path, library.path]))
    }

    func testRootScopeAlongsideDisjointScopeClampsRootButKeepsDisjoint() {
        // `/` clamps to home; an explicit /Volumes scope stays watched separately.
        let external = URL(fileURLWithPath: "/Volumes/External")
        let result = MenuBarManager.clampWatchURLs(
            for: [URL(fileURLWithPath: "/"), external],
            home: home
        ).map(\.path)
        XCTAssertEqual(Set(result), Set([home.path, external.path]))
    }

    // MARK: - CACHE-01 subcategory vs contributor generation

    func testSubcategoryBreakdownSurvivesContributorCacheInvalidation() {
        let manager = MenuBarManager()
        let group = SubcategoryGroup(
            subcategory: .nodeModules,
            displayName: "node_modules",
            totalBytes: 1_024,
            fileCount: 1,
            topFiles: []
        )

        manager._testSeedSubcategoryReady(category: .developer, groups: [group])
        XCTAssertTrue(manager.isSubcategoryBreakdownReady(for: .developer))

        manager._testInvalidateGrowthContributorCache()
        XCTAssertTrue(
            manager.isSubcategoryBreakdownReady(for: .developer),
            "Contributor-only invalidation must not stale subcategory readiness"
        )

        manager._testBumpSubcategoryCacheGeneration()
        XCTAssertFalse(
            manager.isSubcategoryBreakdownReady(for: .developer),
            "Subcategory generation bump must stale readiness"
        )
    }

}
