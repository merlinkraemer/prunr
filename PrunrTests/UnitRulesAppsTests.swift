import XCTest
@testable import Prunr

final class UnitRulesAppsTests: XCTestCase {
    private let home = "/Users/tester"
    private let lib = "/Users/tester/Library"

    private func key(_ path: String) -> String {
        UnitResolver.resolve(path: path, home: home)
    }

    private func name(_ path: String) -> UnitName {
        UnitNamer.name(forKey: key(path), home: home)
    }

    private var fixture: [(path: String, title: String)] {
        [
            ("\(lib)/Caches/com.apple.Safari/WebKitCache/x.db", "Safari cache"),
            ("\(lib)/Caches/com.spotify.client/Data/a", "Spotify cache"),
            ("\(lib)/Caches/com.acme.FooBar/x", "FooBar cache"),
            ("\(lib)/Caches/Homebrew/downloads/a.tar.gz", "Homebrew cache"),
            ("\(lib)/Containers/com.apple.mail/Data/x", "Mail data"),
            ("\(lib)/Containers/com.acme.some-app/Data/x", "Some app data"),
            ("\(lib)/Group Containers/group.com.apple.notes/x", "Notes data"),
            ("\(lib)/Group Containers/UBF8T346G9.Office/x", "Office data"),
            ("\(lib)/Application Support/Google/Chrome/Default/x", "Google data"),
            ("\(lib)/Application Support/Steam/steamapps/common/Half-Life 2/hl2.exe", "Half-Life 2 \u{00B7} Steam"),
            ("\(lib)/Application Support/Steam/config/x", "Steam data"),
            ("\(lib)/Mail/V10/ABCDEF/INBOX.mbox/x.emlx", "Mail"),
            ("\(lib)/Mail/V10/ABCDEF/INBOX.mbox/Data/Attachments/1/2/file.pdf", "Mail attachments"),
            ("\(lib)/Messages/chat.db", "Messages"),
            ("\(lib)/Messages/Attachments/ab/12/IMG.heic", "Messages attachments"),
            ("\(lib)/CloudStorage/GoogleDrive-me@example.com/My Drive/a.txt", "Google Drive files"),
            ("\(lib)/CloudStorage/OneDrive-Personal/a.txt", "OneDrive files"),
            ("\(lib)/CloudStorage/Dropbox/a.txt", "Dropbox files"),
            ("\(lib)/CloudStorage/ProtonDrive-me/a.txt", "Proton Drive files")
        ]
    }

    func testFixtureNames() {
        for item in fixture {
            XCTAssertEqual(name(item.path).title, item.title, item.path)
        }
    }

    func testNoForbiddenTokensOrLibraryInNames() {
        for item in fixture {
            let title = name(item.path).title
            XCTAssertFalse(UnitNamer.containsForbiddenToken(title), title)
            XCTAssertFalse(title.contains("Library"), title)
            XCTAssertFalse(title.contains("com."), title)
        }
    }

    func testCoreKeysStayStable() {
        XCTAssertEqual(key("\(lib)/Caches/com.apple.Safari/a/b"), "library|\(lib)/Caches/com.apple.Safari")
        XCTAssertEqual(key("\(lib)/Containers/com.apple.mail/Data"), "library|\(lib)/Containers/com.apple.mail")
        XCTAssertEqual(key("\(lib)/Application Support/Google/Chrome"), "library|\(lib)/Application Support/Google")
    }

    func testPackKeys() {
        XCTAssertEqual(
            key("\(lib)/Application Support/Steam/steamapps/common/Half-Life 2/bin/x"),
            "steam-game|\(lib)/Application Support/Steam/steamapps/common/Half-Life 2"
        )
        XCTAssertEqual(
            key("\(lib)/Mail/V10/A/B.mbox/Attachments/1/f.pdf"),
            "mail-attachments|\(lib)/Mail/V10/A/B.mbox/Attachments"
        )
        XCTAssertEqual(key("\(lib)/Messages/Attachments/ab/c"), "messages-attachments|\(lib)/Messages/Attachments")
        XCTAssertEqual(
            key("\(lib)/CloudStorage/OneDrive-Personal/Docs/a"),
            "cloud-storage|\(lib)/CloudStorage/OneDrive-Personal"
        )
    }

    func testContainerDetailAndCacheDetail() {
        XCTAssertEqual(name("\(lib)/Group Containers/group.com.apple.notes/x").detail, "Group Containers")
        XCTAssertEqual(name("\(lib)/Caches/com.apple.Safari/x").detail, "Caches")
    }
}
