import XCTest
@testable import Prunr

final class OwnerGroupsTests: XCTestCase {
    private func row(_ owner: UnitOwner, _ bytes: Int64, files: Int = 1) -> DrilldownGroupRow {
        DrilldownGroupRow(
            category: .cachesAndSystem,
            groupKey: DrilldownGroupKey.ownerPrefix + owner.token,
            totalBytes: bytes,
            fileCount: files,
            isTopShort: false
        )
    }

    private func file(_ owner: UnitOwner, _ path: String, _ bytes: Int64) -> DrilldownFileEntry {
        DrilldownFileEntry(groupKey: DrilldownGroupKey.ownerPrefix + owner.token, path: path, sizeBytes: bytes)
    }

    func testOwnerTokensRoundTripWithCaseAndVendor() {
        let owners: [UnitOwner] = [
            .app(id: "com.google.Chrome"),
            .named("Chrome", vendor: "Google"),
            .named("Claude"),
            .named("Prunr backup"),
            .category(.developer),
            .system
        ]
        for owner in owners {
            XCTAssertEqual(UnitOwner(token: owner.token), owner, owner.token)
            XCTAssertEqual(DrilldownGroupKey.owner(of: DrilldownGroupKey.ownerPrefix + owner.token), owner)
        }
        XCTAssertNil(UnitOwner(token: "bogus"))
        XCTAssertNil(UnitOwner(token: "app:"))
        XCTAssertNil(DrilldownGroupKey.owner(of: GrowthSubcategory.docker.rawValue))
    }

    func testOnlyAppsAndSystemGroupsByOwner() {
        let path = "/Users/alex/Library/Caches/com.acme.app/x"
        XCTAssertTrue(DrilldownGroupKey.isOwnerGroupKey(
            DrilldownGroupKey.make(category: .cachesAndSystem, subcategory: .appCaches, path: path)
        ))
        XCTAssertEqual(DrilldownGroupKey.make(category: .developer, subcategory: .docker, path: path), "docker")
        XCTAssertEqual(DrilldownGroupKey.make(category: .other, subcategory: nil, path: path), "")
    }

    func testOneRowPerInstalledAppWithItsNameAndIcon() {
        let chrome = AppCatalogEntry(
            bundleIdentifier: "com.google.Chrome", name: "Chrome", names: ["Chrome", "Google Chrome"],
            path: "/Applications/Google Chrome.app"
        )
        let groups = DrilldownStore.ownerGroups([
            row(.app(id: "com.google.Chrome"), 6, files: 2),
            row(.named("Chrome", vendor: "Google"), 4, files: 3),
            row(.system, 8),
            row(.app(id: "com.acme.Widgets"), 1)
        ], catalog: AppCatalog(entries: [chrome]))

        XCTAssertEqual(groups.map(\.displayName), ["Chrome", "System", "Widgets"])
        let merged = groups[0]
        XCTAssertEqual(merged.totalBytes, 10)
        XCTAssertEqual(merged.fileCount, 5)
        XCTAssertEqual(merged.groupKeys.count, 2)
        XCTAssertEqual(merged.ownerIcon, .app(bundleIdentifier: "com.google.Chrome"))
        XCTAssertNil(groups[1].ownerIcon)
        XCTAssertEqual(groups[1].icon, GrowthCategory.cachesAndSystem.icon)
        XCTAssertEqual(groups[2].ownerIcon, .genericApp)
        XCTAssertEqual(Set(groups.map(\.id)).count, 3)
    }

    func testSmallOwnersFoldIntoOtherAppsKeptLast() {
        let rows = (1...10).map { row(.app(id: "com.acme.App\($0)"), Int64($0) * 10) }
        let groups = DrilldownStore.ownerGroups(rows, catalog: .empty)

        XCTAssertEqual(groups.count, DrilldownStore.shownOwnerLimit + 1)
        let other = groups.last
        XCTAssertEqual(other?.displayName, "Other apps (3)")
        XCTAssertEqual(other?.totalBytes, 60)
        XCTAssertEqual(other?.groupKeys.count, 3)
        XCTAssertTrue(other?.isRemainder == true)
        XCTAssertEqual(DrilldownStore.sorted(Array(groups.reversed())).last?.displayName, "Other apps (3)")

        let eight = DrilldownStore.ownerGroups(Array(rows.prefix(8)), catalog: .empty)
        XCTAssertEqual(eight.count, 8, "one extra owner gets its own row instead of a fold of one")
        XCTAssertFalse(eight.contains(where: \.isRemainder))
    }

    func testMergedTopFilesStopWhereAGroupHasUnstoredFiles() {
        let a = UnitOwner.app(id: "com.acme.A")
        let b = UnitOwner.named("A")
        let keyA = DrilldownGroupKey.ownerPrefix + a.token
        let keyB = DrilldownGroupKey.ownerPrefix + b.token
        let rows = [
            keyA: [file(a, "/a1", 90), file(a, "/a2", 50)],
            keyB: [file(b, "/b1", 70), file(b, "/b2", 10)]
        ]

        let complete = DrilldownStore.mergedTopFiles(of: [keyA, keyB], rowsByGroupKey: rows, fileCounts: [keyA: 2, keyB: 2])
        XCTAssertEqual(complete.map(\.path), ["/a1", "/b1", "/a2", "/b2"])

        let aHasMore = DrilldownStore.mergedTopFiles(of: [keyA, keyB], rowsByGroupKey: rows, fileCounts: [keyA: 9, keyB: 2])
        XCTAssertEqual(aHasMore.map(\.path), ["/a1", "/b1", "/a2"])

        let single = DrilldownStore.mergedTopFiles(of: [keyB], rowsByGroupKey: rows, fileCounts: [:])
        XCTAssertEqual(single.map(\.path), ["/b1", "/b2"])
    }
}
