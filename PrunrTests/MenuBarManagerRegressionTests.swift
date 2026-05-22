import XCTest
@testable import Prunr

@MainActor
final class MenuBarManagerRegressionTests: PrunrTestCase {
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
}
