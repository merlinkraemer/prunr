import XCTest
@testable import Prunr

@MainActor
final class DrilldownNavigationTests: XCTestCase {
    private func child(_ name: String, _ bytes: Int64, folder: Bool = true) -> PlaceChild {
        PlaceChild(name: name, path: "/Users/tester/dev/acme/\(name)", isFolder: folder, totalBytes: bytes, fileCount: 3)
    }

    private func pages(_ children: [PlaceChild], pageSize: Int) -> (PlaceContentsModel.Loader, () -> [Int]) {
        var offsets: [Int] = []
        let loader: PlaceContentsModel.Loader = { offset in
            offsets.append(offset)
            let page = Array(children.dropFirst(offset).prefix(pageSize))
            return PlaceContentsPage(children: page, hasMore: offset + page.count < children.count)
        }
        return (loader, { offsets })
    }

    func testPlaceContentsPageInPlaceUntilEverythingIsShown() async {
        let all = (0..<5).map { child("item\($0)", Int64(100 - $0)) }
        let (loader, offsets) = pages(all, pageSize: 2)
        let model = PlaceContentsModel(loader: loader)

        XCTAssertNil(model.inlineStatus(isIndexing: false))
        await model.load()
        XCTAssertEqual(model.children.map(\.name), ["item0", "item1"])
        XCTAssertTrue(model.hasMore)
        XCTAssertNil(model.inlineStatus(isIndexing: false))

        await model.loadMore()
        await model.loadMore()
        XCTAssertEqual(model.children.map(\.name), all.map(\.name))
        XCTAssertFalse(model.hasMore)

        await model.loadMore()
        XCTAssertEqual(offsets(), [0, 2, 4])
    }

    func testPlaceContentsInlineStates() async {
        struct ReadFailure: Error {}
        let failing = PlaceContentsModel(loader: { _ in throw ReadFailure() })
        await failing.load()
        XCTAssertEqual(failing.inlineStatus(isIndexing: false), .failed)
        XCTAssertEqual(InlineStatus.failed.text, "Couldn't read")

        let empty = PlaceContentsModel(loader: { _ in PlaceContentsPage(children: [], hasMore: false) })
        await empty.load()
        XCTAssertEqual(empty.inlineStatus(isIndexing: false), .empty)
        XCTAssertEqual(empty.inlineStatus(isIndexing: true), .indexing)
        XCTAssertEqual(InlineStatus.indexing.text, "Indexing files…")
        XCTAssertEqual(InlineStatus.empty.text, "No files found")
    }

    func testSingleRowPagesAreSkippedOrRevealedAndOthersPush() {
        XCTAssertEqual(SoloDrill.step(rows: [], hasMore: false), .push)
        XCTAssertEqual(SoloDrill.step(rows: [.leaf("/a")], hasMore: false), .reveal("/a"))
        XCTAssertEqual(SoloDrill.step(rows: [.leaf("/a")], hasMore: true), .push)
        XCTAssertEqual(SoloDrill.step(rows: [.leaf("/a"), .leaf("/b")], hasMore: false), .push)
        XCTAssertEqual(SoloDrill.step(rows: [.branch], hasMore: false), .skip)
        XCTAssertEqual(SoloDrill.step(rows: [.branch], hasMore: true), .push)
        XCTAssertEqual(SoloDrill.step(rows: [.branch, .branch], hasMore: false), .push)
        XCTAssertEqual(SoloDrill.step(rows: [.inert], hasMore: false), .push)
    }

    func testOnlyASingleCompleteLeafPageRevealsItsItem() {
        let whatsApp = "/Users/tester/Library/Mobile Documents/57T9237FN3~net~whatsapp~WhatsApp/Accounts"
        XCTAssertEqual(SoloDrill.revealPath(leaves: [whatsApp], hasMore: false), whatsApp)
        XCTAssertNil(SoloDrill.revealPath(leaves: [whatsApp], hasMore: true))
        XCTAssertNil(SoloDrill.revealPath(leaves: [whatsApp, "/b"], hasMore: false))
        XCTAssertNil(SoloDrill.revealPath(leaves: [], hasMore: false))
    }

    func testCategoryWithoutSubcategoriesOpensItsFilesDirectly() {
        let files = SubcategoryGroup(subcategory: nil, displayName: "Files", totalBytes: 10, fileCount: 2, topFiles: [])
        XCTAssertEqual(MenuBarManager.directFileGroup(for: .downloads, groups: [files])?.id, files.id)
        XCTAssertNil(MenuBarManager.directFileGroup(for: .downloads, groups: []))
    }

    func testCategoryWithOneSubcategoryOpensItsFilesDirectly() {
        let docker = SubcategoryGroup(subcategory: .docker, displayName: "Docker", totalBytes: 10, fileCount: 1, topFiles: [])
        let nodeModules = SubcategoryGroup(subcategory: .nodeModules, displayName: "node_modules", totalBytes: 5, fileCount: 1, topFiles: [])
        XCTAssertEqual(MenuBarManager.directFileGroup(for: .developer, groups: [docker])?.id, docker.id)
        XCTAssertNil(MenuBarManager.directFileGroup(for: .developer, groups: [docker, nodeModules]))
        XCTAssertNil(MenuBarManager.directFileGroup(for: .developer, groups: []))

        XCTAssertFalse(MenuBarManager.filesBackReturnsToSubcategories(for: .developer, groups: [docker]))
        XCTAssertTrue(MenuBarManager.filesBackReturnsToSubcategories(for: .developer, groups: [docker, nodeModules]))
        XCTAssertFalse(MenuBarManager.filesBackReturnsToSubcategories(for: .downloads, groups: [docker, nodeModules]))
    }

    func testEachTapSetsOneFinalSelectionAndBackGoesUpOneLevel() {
        let manager = MenuBarManager()
        let developer = CategoryInventoryItem(category: .developer, currentSizeBytes: 10, recentGrowthStory: nil)
        let docker = SubcategoryGroup(subcategory: .docker, displayName: "Docker", totalBytes: 10, fileCount: 1, topFiles: [])

        manager.openCategory(developer)
        XCTAssertTrue(manager.isDrilledDown)
        XCTAssertFalse(manager.isSubcategoryDrillDown)
        XCTAssertEqual(manager.selectedInventoryCategory?.category, .developer)

        manager.openSubcategory(docker)
        XCTAssertTrue(manager.isSubcategoryDrillDown)
        XCTAssertEqual(manager.selectedSubcategory?.id, docker.id)

        manager.closeDrilldownLevel()
        XCTAssertTrue(manager.isDrilledDown)
        XCTAssertFalse(manager.isSubcategoryDrillDown)
        XCTAssertNil(manager.selectedSubcategory)

        manager.closeDrilldownLevel()
        XCTAssertFalse(manager.isDrilledDown)
        XCTAssertNil(manager.selectedInventoryCategory)
    }

    func testCategoriesViewInlineStatesReplaceLoaderPages() {
        XCTAssertNil(CategorySizes.groupsStatus(isEmpty: false, isIndexing: true, readFailed: true))
        XCTAssertEqual(CategorySizes.groupsStatus(isEmpty: true, isIndexing: true, readFailed: false), .indexing)
        XCTAssertEqual(CategorySizes.groupsStatus(isEmpty: true, isIndexing: false, readFailed: true), .failed)
        XCTAssertEqual(CategorySizes.groupsStatus(isEmpty: true, isIndexing: false, readFailed: false), .empty)

        XCTAssertNil(CategorySizes.filesStatus(hasGroup: true, hasFiles: true, isIndexing: true, isLoaded: false, readFailed: false))
        XCTAssertNil(CategorySizes.filesStatus(hasGroup: true, hasFiles: false, isIndexing: false, isLoaded: false, readFailed: false))
        XCTAssertEqual(CategorySizes.filesStatus(hasGroup: true, hasFiles: false, isIndexing: true, isLoaded: false, readFailed: false), .indexing)
        XCTAssertEqual(CategorySizes.filesStatus(hasGroup: true, hasFiles: false, isIndexing: false, isLoaded: false, readFailed: true), .failed)
        XCTAssertEqual(CategorySizes.filesStatus(hasGroup: true, hasFiles: false, isIndexing: false, isLoaded: true, readFailed: false), .empty)
        XCTAssertEqual(CategorySizes.filesStatus(hasGroup: false, hasFiles: false, isIndexing: false, isLoaded: false, readFailed: false), .empty)
    }

    func testShowMoreCountsTheFilesNotShownYet() {
        let item = GrowthItem(path: "/a", growthBytes: 1, currentSizeBytes: 1, percentOfParent: 0)
        let group = SubcategoryGroup(subcategory: nil, displayName: "Docker", totalBytes: 10, fileCount: 36, topFiles: Array(repeating: item, count: 5))
        XCTAssertEqual(CategorySizes.remainingFileCount(group), 31)
        XCTAssertEqual(CategorySizes.remainingFileCount(nil), 0)
        let capped = SubcategoryGroup(
            subcategory: nil, displayName: "Photos", totalBytes: 10, fileCount: 9_000,
            topFiles: Array(repeating: item, count: SubcategoryGroup.maxLoadableFiles)
        )
        XCTAssertEqual(CategorySizes.remainingFileCount(capped), 0)
        XCTAssertEqual(CategorySizes.fileCountText(1), "1 file")
        XCTAssertEqual(CategorySizes.fileCountText(212_880), "\(212_880.formatted()) files")
    }
}
