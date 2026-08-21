import XCTest
@testable import Prunr

@MainActor
final class MenuBarManagerRegressionTests: PrunrTestCase {
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
            CategoryInventoryItem(category: .downloads, currentSizeBytes: 100, growthTrend: nil, recentGrowthStory: nil),
            CategoryInventoryItem(category: .applications, currentSizeBytes: 100, growthTrend: nil, recentGrowthStory: nil),
            CategoryInventoryItem(category: .developer, currentSizeBytes: 100, growthTrend: nil, recentGrowthStory: nil)
        ]

        XCTAssertEqual(
            manager.stableCategories.map(\.category),
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
                growthTrend: nil,
                recentGrowthStory: RecentGrowthStory(
                    category: .downloads,
                    subcategory: nil,
                    deltaBytes: 2_000_000,
                    startedAt: now,
                    endedAt: now,
                    duration: 0,
                    displayLabel: "now"
                )
            ),
            CategoryInventoryItem(
                category: .applications,
                currentSizeBytes: 100,
                growthTrend: nil,
                recentGrowthStory: RecentGrowthStory(
                    category: .applications,
                    subcategory: nil,
                    deltaBytes: 2_000_000,
                    startedAt: now,
                    endedAt: now,
                    duration: 0,
                    displayLabel: "now"
                )
            )
        ]

        XCTAssertEqual(
            manager.growingCategories.map(\.category),
            [.applications, .downloads]
        )
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
}
