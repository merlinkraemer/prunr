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

    func testFooterActivityFallsBackToScanningDuringInventoryAnalysis() {
        let manager = MenuBarManager()
        manager.isLoading = true
        manager.isAnalyzingChanges = true
        manager.scanProgressPercentage = 1
        manager.hasReliableScanProgressEstimate = true

        XCTAssertEqual(
            manager.footerActivity,
            .fullScan(phase: .scanning, percentage: 100)
        )
        XCTAssertEqual(manager.footerActivity.text, "Scanning 100%")
    }

    func testFooterActivityShowsFinalizingScan() {
        let manager = MenuBarManager()
        manager.isLoading = true
        manager.scanProgress = "Finalizing scan..."

        XCTAssertEqual(
            manager.footerActivity,
            .fullScan(phase: .finalizing, percentage: nil)
        )
        XCTAssertEqual(manager.footerActivity.text, "Finalizing scan…")
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

    func testFooterActivityHidesManualStorageChecks() {
        let manager = MenuBarManager()
        manager.isCheckingGrowth = true
        XCTAssertEqual(manager.footerActivity, .idle)
        XCTAssertEqual(manager.footerActivity.text, "")

        manager.isCheckingGrowth = false
        manager.isProcessingRecentChanges = true
        XCTAssertEqual(manager.footerActivity, .idle)
    }

    func testManualCheckWaitsForAutomaticRefreshInsteadOfReturning() async throws {
        let manager = MenuBarManager()
        manager.isProcessingRecentChanges = true

        let checkTask = Task { @MainActor in
            await manager.checkGrowth()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(manager.isCheckingGrowth)

        manager.isProcessingRecentChanges = false
        await checkTask.value
        XCTAssertFalse(manager.isCheckingGrowth)
    }

    func testFooterActivityHidesQueuedReconciliation() {
        let dirtyManager = MenuBarManager()
        dirtyManager.recordFileWatcherChangeBatch(
            FSEventsWatcher.ChangeBatch(
                changedPaths: [],
                requiresFullRescan: false,
                dirtyReason: "stream-dropped",
                rawEventCount: 1
            )
        )
        XCTAssertEqual(dirtyManager.footerActivity, .idle)
        XCTAssertEqual(dirtyManager.footerActivity.text, "")

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

    /// The categories view lists today's sizes, biggest first, whatever moved.
    func testCategoriesSortBySizeBiggestFirst() {
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
            [.other, .developer, .audioProduction, .downloads]
        )
    }

    /// Sub-floor movers sort by size like every row, and their bytes still
    /// count toward the category total.
    func testSubFloorMoversSortBySizeAndStillCountInTotal() {
        let manager = MenuBarManager()
        let gb: Int64 = 1024 * 1024 * 1024
        manager.allCategories = [
            item(.other, size: 546 * gb, delta: 800_000),
            item(.audioProduction, size: 12 * gb, delta: 900_000),
            item(.downloads, size: 2 * gb, delta: 2 * gb)
        ]

        XCTAssertEqual(
            manager.sortedCategories.map(\.category),
            [.other, .audioProduction, .downloads]
        )
        XCTAssertEqual(manager.changedCategories.map(\.category), [.downloads])
        XCTAssertNil(manager.allCategories.first { $0.category == .other }?.renderableGrowthDeltaBytes)
    }

    /// The diagnostics report keeps its growth and stable counts after the
    /// old overview is gone: categories that moved this week vs the rest.
    func testDiagnosticsReportKeepsGrowingAndStableCounts() {
        let manager = MenuBarManager()
        let gb: Int64 = 1024 * 1024 * 1024
        manager.allCategories = [
            item(.developer, size: 100 * gb, delta: -20 * gb),
            item(.downloads, size: 5 * gb, delta: 1 * gb),
            item(.other, size: 400 * gb)
        ]

        let context = manager.makeDiagnosticsContext()

        XCTAssertEqual(context.categoryCount, 3)
        XCTAssertEqual(context.growingCount, 2)
        XCTAssertEqual(context.stableCount, 1)
        XCTAssertEqual(
            DiagnosticsReporter.inventorySummary(for: context),
            "inventory: categories=3 growing=2 stable=1"
        )
    }

    func testMarketingSampleReadsAsTheNewScreen() throws {
        let feed = MarketingSample.feed
        let calendar = Calendar.current

        XCTAssertEqual(WeeklyChange(.loaded(feed), now: MarketingSample.now), .bytes(27_600_000_000))
        XCTAssertEqual(
            feed.days.map { EpisodeBuilder.dayLabel(for: $0.day, calendar: calendar) },
            ["Wed 21 Oct", "Tue 20 Oct", "Mon 19 Oct"]
        )
        XCTAssertTrue(feed.days.allSatisfy { $0.groups.count <= ChangeFeedRows.collapsedGroupLimit })
        XCTAssertEqual(feed.days[0].groups.map(\.rowTitle), ["Google Chrome", "Developer", "Slack"])
        XCTAssertEqual(feed.days[1].groups.map(\.rowTitle), ["Steam", "Downloads · ubuntu-24.04.1-arm64.iso", "Spotify"])

        let chrome = MarketingSample.appGroup
        XCTAssertEqual(chrome.owner.displayName, "Google Chrome")
        XCTAssertEqual(chrome.rowIconSource, .app(bundleIdentifier: "com.google.Chrome"))
        XCTAssertEqual(chrome.episodes.map(\.title), ["Cache", "App data", "Website data"])
        XCTAssertNil(FeedPage.soloPlace(of: chrome))
        XCTAssertTrue(chrome.isLargeGrowth)

        let spotify = MarketingSample.contentsGroup
        let place = try XCTUnwrap(FeedPage.soloPlace(of: spotify))
        XCTAssertEqual(spotify.headerTitle(for: place), "Spotify")
        XCTAssertEqual(
            EpisodeBuilder.contentsCaption(for: place, headerTitle: "Spotify", home: MarketingSample.home),
            "Cache · ~/Library/Caches/com.spotify.client"
        )
        XCTAssertEqual(MarketingSample.contents.map(\.totalBytes), MarketingSample.contents.map(\.totalBytes).sorted(by: >))

        XCTAssertTrue(feed.episodes.allSatisfy { $0.rootPath?.hasPrefix(MarketingSample.home + "/") == true })
        XCTAssertTrue(MarketingSample.contents.allSatisfy { $0.path.hasPrefix(MarketingSample.home + "/") })

        let weekStart = GrowthJournalService.weekStart(now: MarketingSample.now, calendar: calendar)
        let weekRows = feed.days.filter { $0.day >= weekStart }.flatMap(\.episodes)
        for item in MarketingSample.categories(endedAt: MarketingSample.now) {
            let rows = weekRows.filter { $0.category == item.category }.reduce(Int64(0)) { $0 + $1.netBytes }
            XCTAssertEqual(rows, item.growthDeltaBytes, item.category.displayName)
        }
        XCTAssertTrue(feed.episodes.allSatisfy { abs($0.netBytes) >= EpisodeBuilder.rowThresholdBytes })
        XCTAssertNil(feed.quietSince(now: MarketingSample.now, calendar: calendar))
        XCTAssertFalse(feed.isShortHistory(now: MarketingSample.now, calendar: calendar))

        let categories = MarketingSample.categories(endedAt: MarketingSample.now)
        XCTAssertEqual(categories.reduce(Int64(0)) { $0 + $1.growthDeltaBytes }, feed.weekNetBytes)
        let tracked = categories.reduce(Int64(0)) { $0 + $1.currentSizeBytes }
        XCTAssertEqual(MarketingSample.totalBytes - MarketingSample.freeBytes - tracked, 105_500_000_000)
    }

    // MARK: - Change list states

    private static func sampleFeed() -> ChangeFeed {
        let today = Calendar.current.startOfDay(for: Date())
        let episode = ChangeEpisode(
            id: "download|/Users/tester/Downloads/a.iso@0",
            title: "Downloads · a.iso",
            detail: nil,
            category: .downloads,
            rootPath: "/Users/tester/Downloads/a.iso",
            netBytes: 2 * 1024 * 1024 * 1024,
            grossBytes: 2 * 1024 * 1024 * 1024,
            day: today,
            time: Date(),
            isApproximateTime: false
        )
        return ChangeFeed(
            days: [ChangeFeedDay(day: today, episodes: [episode])],
            weekNetBytes: episode.netBytes,
            watchingSince: today
        )
    }

    /// A history that cannot be read gives `.failed` and a "—" header, never
    /// an empty list that would read as "nothing changed".
    func testFeedReadFailureGivesFailedAndUnknownHeader() async throws {
        let manager = MenuBarManager()
        manager.changeFeed = .loaded(Self.sampleFeed())
        // No database: every journal read throws.
        try? DatabaseManager.shared.close()

        await manager.refreshChangeFeed()

        XCTAssertEqual(manager.changeFeed, .failed)
        XCTAssertNotEqual(manager.changeFeed, .loaded(.empty))
        XCTAssertEqual(WeeklyChange(manager.changeFeed), .unknown)
        XCTAssertEqual(WeeklyChange(manager.changeFeed).amountText, "\u{2014}")
    }

    /// Starting a rescan (and the inventory reload around it) keeps the last
    /// list on screen; only a finished read may replace it.
    func testStartingARescanDoesNotClearTheChangeFeed() async throws {
        try await withEmptyTemporaryDatabase { _ in
            let manager = MenuBarManager()
            let feed = Self.sampleFeed()
            manager.noBaseline = false
            manager.changeFeed = .loaded(feed)

            let missingRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("PrunrMissing-\(UUID().uuidString)", isDirectory: true)
            let trackedPath = TrackedPath(url: missingRoot, displayName: "Missing")
            _ = await manager.loadInventory(trackedPathsOverride: [trackedPath])
            XCTAssertEqual(manager.changeFeed, .loaded(feed))

            await manager.loadInventoryFromLatestSnapshot(refreshedAt: Date())
            XCTAssertEqual(manager.changeFeed, .loaded(feed))
        }
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
