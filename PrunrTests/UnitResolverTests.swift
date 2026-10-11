import XCTest
@testable import Prunr

final class UnitResolverTests: XCTestCase {
    private let home = "/Users/tester"

    private func key(_ path: String) -> String {
        UnitResolver.resolve(path: path, home: home)
    }

    private func name(_ path: String) -> UnitName {
        UnitNamer.name(forKey: key(path), home: home)
    }

    // MARK: - Downloads

    func testDownloadItemIsItsOwnUnit() {
        XCTAssertEqual(key("/Users/tester/Downloads/ubuntu.iso"), "download|/Users/tester/Downloads/ubuntu.iso")
        XCTAssertEqual(name("/Users/tester/Downloads/ubuntu.iso"), UnitName(title: "Downloads · ubuntu.iso", category: .downloads))
    }

    func testFilesInsideDownloadedFolderBelongToThatFolder() {
        XCTAssertEqual(
            key("/Users/tester/Downloads/Assets Pack/textures/rock.png"),
            "download|/Users/tester/Downloads/Assets Pack"
        )
        XCTAssertEqual(name("/Users/tester/Downloads/Assets Pack/textures/rock.png").title, "Downloads · Assets Pack")
    }

    func testDownloadsFolderItself() {
        XCTAssertEqual(key("/Users/tester/Downloads"), "download|/Users/tester/Downloads")
        XCTAssertEqual(name("/Users/tester/Downloads").title, "Downloads")
    }

    func testPartialDownloadKeepsRawKeyButReadsAsTheFile() {
        XCTAssertEqual(
            key("/Users/tester/Downloads/ubuntu.iso.crdownload"),
            "download|/Users/tester/Downloads/ubuntu.iso.crdownload"
        )
        XCTAssertEqual(name("/Users/tester/Downloads/ubuntu.iso.crdownload").title, "Downloads · ubuntu.iso")
        XCTAssertEqual(name("/Users/tester/Downloads/ubuntu.iso.download/data").title, "Downloads · ubuntu.iso")
    }

    func testHashNamedDownloadFallsBackToDownloads() {
        let hash = String(repeating: "a1b2c3d4", count: 4)
        XCTAssertEqual(name("/Users/tester/Downloads/\(hash).zip").title, "Downloads")
    }

    // MARK: - Trash

    func testEverythingInTrashIsOneUnit() {
        XCTAssertEqual(key("/Users/tester/.Trash/old movie.mov"), "trash|/Users/tester/.Trash")
        XCTAssertEqual(key("/Users/tester/.Trash/folder/deep/file"), "trash|/Users/tester/.Trash")
        XCTAssertEqual(name("/Users/tester/.Trash/folder/deep/file"), UnitName(title: "Trash", category: .trash))
    }

    // MARK: - Named-place fallback

    func testFallbackNamesTheFolderUnderATopLevelFolder() {
        let path = "/Users/tester/Documents/Archive/2024/taxes.pdf"
        XCTAssertEqual(key(path), "place|/Users/tester/Documents/Archive")
        XCTAssertEqual(name(path).title, "Archive · Documents")
        XCTAssertNil(name(path).detail)
    }

    func testFallbackForLooseFilesAndHome() {
        XCTAssertEqual(key("/Users/tester/Documents/report.pdf"), "place|/Users/tester/Documents/report.pdf")
        XCTAssertEqual(name("/Users/tester/Documents/report.pdf").title, "report.pdf · Documents")
        XCTAssertEqual(name("/Users/tester/notes.txt").title, "notes.txt")
        XCTAssertEqual(key("/Users/tester"), "place|/Users/tester")
        XCTAssertEqual(name("/Users/tester").title, "Home folder")
    }

    func testFallbackOutsideHomeUsesTwoParts() {
        XCTAssertEqual(key("/Applications/Foo.app/Contents/MacOS/Foo"), "place|/Applications/Foo.app")
        XCTAssertEqual(name("/Applications/Foo.app/Contents/MacOS/Foo").title, "Foo.app · Applications")
    }

    func testFallbackSkipsHashFolders() {
        let hash = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(name("/Users/tester/Documents/\(hash)/file").title, "Documents")
    }

    func testUnknownKindStillReadsAsAPlace() {
        XCTAssertEqual(
            UnitNamer.name(forKey: "retired-kind|/Users/tester/Documents/Archive", home: home).title,
            "Archive · Documents"
        )
    }

    // MARK: - Library/<Area>/<X>

    func testLibraryAreaItemReadsAsData() {
        let path = "/Users/tester/Library/Application Support/Google/Chrome/Default/History"
        XCTAssertEqual(key(path), "library|/Users/tester/Library/Application Support/Google")
        XCTAssertEqual(name(path).title, "Google data")
        XCTAssertEqual(name(path).detail, "Application Support")
    }

    func testLibraryBundleIdsBecomeAppNames() {
        XCTAssertEqual(name("/Users/tester/Library/Containers/com.apple.Safari/Data/x").title, "Safari data")
        XCTAssertEqual(name("/Users/tester/Library/Group Containers/group.com.apple.notes/db").title, "Notes data")
        XCTAssertEqual(name("/Users/tester/Library/Group Containers/UBF8T346G9.Office/x").title, "Office data")
        XCTAssertEqual(name("/Users/tester/Library/Preferences/com.apple.finder.plist").title, "Finder data")
        XCTAssertEqual(name("/Users/tester/Library/Caches/com.example.Widget/blob").title, "Widget data")
    }

    func testLibraryAreaAndLibraryItself() {
        XCTAssertEqual(key("/Users/tester/Library/Caches"), "library|/Users/tester/Library/Caches")
        XCTAssertEqual(name("/Users/tester/Library/Caches").title, "Caches")
        XCTAssertEqual(name("/Users/tester/Library").title, "Library files")
        let hash = "fedcba9876543210fedcba9876543210"
        XCTAssertEqual(name("/Users/tester/Library/Caches/\(hash)/x").title, "Caches")
    }

    // MARK: - Key format and stability

    func testCaseIsPreservedInTheKey() {
        XCTAssertEqual(
            key("/Users/tester/Documents/MyProject/Src/File.swift"),
            "place|/Users/tester/Documents/MyProject"
        )
        // Home matches case-insensitively, but the root keeps the incoming case.
        XCTAssertEqual(key("/users/TESTER/downloads/X.iso"), "download|/users/TESTER/downloads/X.iso")
    }

    func testPathSpellingsNormaliseToOneKey() {
        let expected = "download|/Users/tester/Downloads/a.iso"
        XCTAssertEqual(key("/Users/tester/Downloads/a.iso/"), expected)
        XCTAssertEqual(key("/Users/tester//Downloads/./a.iso"), expected)
        XCTAssertEqual(key("~/Downloads/a.iso"), expected)
    }

    func testKeyRoundTripsAndRootMayContainSeparator() {
        let parsed = UnitKey(rawValue: "place|/Users/tester/odd|name")
        XCTAssertEqual(parsed?.kind, .place)
        XCTAssertEqual(parsed?.rootPath, "/Users/tester/odd|name")
        XCTAssertEqual(parsed?.rawValue, "place|/Users/tester/odd|name")
        XCTAssertNil(UnitKey(rawValue: ""))
        XCTAssertNil(UnitKey(rawValue: "|/x"))
    }

    func testDefaultHomeIsTheUsersHome() {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        let path = realHome + "/Downloads/thing.dmg"
        XCTAssertEqual(UnitResolver.resolve(path: path), "download|" + path)
        XCTAssertEqual(UnitNamer.name(path: path), UnitName(title: "Downloads · thing.dmg", category: .downloads))
    }

    // MARK: - Guard: no hashes or bundle ids in names

    func testForbiddenTokenDetector() {
        XCTAssertTrue(UnitNamer.containsForbiddenToken("com.apple.Safari"))
        XCTAssertTrue(UnitNamer.containsForbiddenToken("x group.com.apple.notes y"))
        XCTAssertTrue(UnitNamer.containsForbiddenToken("Build 0123456789abcdef0123456789abcdef"))
        XCTAssertFalse(UnitNamer.containsForbiddenToken("Downloads · ubuntu-22.04.iso"))
        XCTAssertFalse(UnitNamer.containsForbiddenToken("Downloads · archive.tar.gz"))
        XCTAssertFalse(UnitNamer.containsForbiddenToken("Archive · Documents"))
    }

    func testNoNameContainsAHashOrDottedBundleId() {
        let hash = "0123456789abcdef0123456789ABCDEF"
        let paths = [
            "/Users/tester/Downloads/ubuntu-22.04.iso",
            "/Users/tester/Downloads/\(hash).zip",
            "/Users/tester/Downloads/com.example.tool.dmg",
            "/Users/tester/Downloads/build-\(hash)/a",
            "/Users/tester/.Trash/com.apple.Safari.plist",
            "/Users/tester/Documents/Archive/x",
            "/Users/tester/Documents/\(hash)/x",
            "/Users/tester/Documents/org.example.Thing/x",
            "/Users/tester/Library/Caches/com.spotify.client/Data/x",
            "/Users/tester/Library/Caches/com.unknown.vendor.App/x",
            "/Users/tester/Library/Caches/\(hash)/x",
            "/Users/tester/Library/Containers/com.apple.Safari/Data/x",
            "/Users/tester/Library/Containers/\(hash)/x",
            "/Users/tester/Library/Group Containers/group.com.apple.notes/x",
            "/Users/tester/Library/Group Containers/UBF8T346G9.Office/x",
            "/Users/tester/Library/Application Support/com.docker.docker/x",
            "/Users/tester/Library/Application Support/Code/User/x",
            "/Users/tester/Library/Preferences/com.apple.finder.plist",
            "/Users/tester/Library/Saved Application State/com.apple.Terminal.savedState/x",
            "/Users/tester/Library/Developer/Xcode/DerivedData/Prunr-\(hash)/Build",
            "/Users/tester/.cache/\(hash)/x",
            "/Users/tester/dev/acme/node_modules/react/index.js",
            "/Applications/com.vendor.helper.app/Contents/x",
            "/Library/Caches/com.apple.something/x",
        ]
        for path in paths {
            let unit = name(path)
            XCTAssertFalse(unit.title.isEmpty, path)
            XCTAssertFalse(UnitNamer.containsForbiddenToken(unit.title), "\(path) → \(unit.title)")
            if let detail = unit.detail {
                XCTAssertFalse(UnitNamer.containsForbiddenToken(detail), "\(path) → \(detail)")
            }
            XCTAssertFalse(unit.title.contains("/"), "\(path) → \(unit.title)")
        }
    }
}
