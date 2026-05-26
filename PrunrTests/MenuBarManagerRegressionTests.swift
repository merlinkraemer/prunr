import XCTest
@testable import Prunr

@MainActor
final class MenuBarManagerRegressionTests: PrunrTestCase {
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
}
