import XCTest
@testable import Prunr

@MainActor
final class FooterStatusTests: PrunrTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    func testEachStateOutranksTheOnesBelowIt() {
        let day = now.addingTimeInterval(-3 * 86_400)
        let updated = now.addingTimeInterval(-120)

        XCTAssertEqual(FooterStatus.resolve(
            notice: "No longer on disk", refreshFailed: true, scanText: "Scanning 42%", isRefreshing: true,
            foldersNotReadable: true, updateAvailable: true, groupDay: day, preview: .sample, updatedAt: updated
        ), .notice("No longer on disk"))
        XCTAssertEqual(FooterStatus.resolve(
            refreshFailed: true, scanText: "Scanning 42%", isRefreshing: true,
            foldersNotReadable: true, updateAvailable: true, groupDay: day, preview: .sample, updatedAt: updated
        ), .refreshFailed)
        XCTAssertEqual(FooterStatus.resolve(
            scanText: "Scanning 42%", isRefreshing: true,
            foldersNotReadable: true, updateAvailable: true, groupDay: day, preview: .sample, updatedAt: updated
        ), .scanning("Scanning 42%"))
        XCTAssertEqual(FooterStatus.resolve(
            isRefreshing: true, foldersNotReadable: true, updateAvailable: true, groupDay: day, preview: .sample, updatedAt: updated
        ), .refreshing)
        XCTAssertEqual(FooterStatus.resolve(
            foldersNotReadable: true, updateAvailable: true, groupDay: day, preview: .sample, updatedAt: updated
        ), .foldersNotReadable)
        XCTAssertEqual(FooterStatus.resolve(
            updateAvailable: true, groupDay: day, preview: .sample, updatedAt: updated
        ), .updateAvailable)
        XCTAssertEqual(FooterStatus.resolve(groupDay: day, preview: .sample, updatedAt: updated), .groupDay(day))
        XCTAssertEqual(FooterStatus.resolve(preview: .sample, updatedAt: updated), .preview(.sample))
        XCTAssertEqual(FooterStatus.resolve(updatedAt: updated), .updated(updated))
        XCTAssertEqual(FooterStatus.resolve(), .none)
    }

    func testTexts() {
        XCTAssertEqual(FooterStatus.refreshFailed.text(), "Couldn't refresh")
        XCTAssertEqual(FooterStatus.refreshing.text(), "Refreshing…")
        XCTAssertEqual(FooterStatus.foldersNotReadable.text(), "Some folders not readable")
        XCTAssertEqual(FooterStatus.preview(.sample).text(), "Sample data")
        XCTAssertEqual(FooterStatus.preview(.dayOne).text(), "Preview: Day one")
        XCTAssertTrue(FooterStatus.scanning("Scanning 42%").showsSpinner)
        XCTAssertTrue(FooterStatus.refreshing.showsSpinner)
        XCTAssertFalse(FooterStatus.updated(now).showsSpinner)
    }

    func testUpdatedReadsRelativeTime() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        utc.locale = Locale(identifier: "en_GB")
        XCTAssertEqual(FooterStatus.updatedText(since: now.addingTimeInterval(-20), now: now, calendar: utc), "Updated just now")
        XCTAssertEqual(FooterStatus.updatedText(since: now.addingTimeInterval(-120), now: now, calendar: utc), "Updated 2 min ago")
        XCTAssertEqual(FooterStatus.updatedText(since: now.addingTimeInterval(-3 * 3_600), now: now, calendar: utc), "Updated 3 h ago")
        let old = now.addingTimeInterval(-2 * 86_400)
        XCTAssertEqual(
            FooterStatus.updatedText(since: old, now: now, calendar: utc),
            "Updated \(EpisodeBuilder.dayLabel(for: old, calendar: utc))"
        )
    }

    func testMarketingFooterReadsUpdatedTwoMinutesAgo() {
        XCTAssertEqual(MarketingSample.footerStatus.text(now: MarketingSample.now), "Updated 2 min ago")
    }

    func testCategoriesViewShowsSizesOnly() {
        let item = CategoryInventoryItem(
            category: .developer,
            currentSizeBytes: 182_800_000_000,
            recentGrowthStory: RecentGrowthStory(
                category: .developer, subcategory: nil, deltaBytes: 9_000_000_000,
                startedAt: now.addingTimeInterval(-86_400), endedAt: now
            )
        )
        XCTAssertEqual(CategorySizes.sizeText(item.currentSizeBytes), formattedBytes(182_800_000_000))
        XCTAssertFalse(CategorySizes.sizeText(item.currentSizeBytes).contains("\u{2197}"))
        XCTAssertFalse(CategorySizes.sizeText(item.currentSizeBytes).contains("+"))
    }

    func testSubcategoriesSortBySizeIgnoringChange() {
        let small = SubcategoryGroup(subcategory: nil, displayName: "Python", totalBytes: 18_000_000_000,
                                     fileCount: 1, growthBytes: 12_000_000_000, topFiles: [])
        let big = SubcategoryGroup(subcategory: nil, displayName: "Docker", totalBytes: 64_000_000_000,
                                   fileCount: 1, growthBytes: nil, topFiles: [])
        let middle = SubcategoryGroup(subcategory: nil, displayName: "Xcode", totalBytes: 48_000_000_000,
                                      fileCount: 1, growthBytes: -5_000_000_000, topFiles: [])
        XCTAssertEqual(CategorySizes.subcategoriesBySize([small, middle, big]).map(\.displayName), ["Docker", "Xcode", "Python"])
        XCTAssertEqual(
            MarketingSample.developerSubcategories.map(\.bytes),
            MarketingSample.developerSubcategories.map(\.bytes).sorted(by: >)
        )
    }
}
