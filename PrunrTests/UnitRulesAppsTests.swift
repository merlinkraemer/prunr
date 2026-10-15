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
            ("\(lib)/Caches/com.apple.Safari/WebKitCache/x.db", "Safari · Cache"),
            ("\(lib)/Caches/com.spotify.client/Data/a", "Spotify · Cache"),
            ("\(lib)/Caches/com.acme.FooBar/x", "FooBar · Cache"),
            ("\(lib)/Caches/Homebrew/downloads/a.tar.gz", "Homebrew · Cache"),
            ("\(lib)/Containers/com.apple.mail/Data/x", "Mail · App data"),
            ("\(lib)/Containers/com.acme.some-app/Data/x", "Some app · App data"),
            ("\(lib)/Group Containers/group.com.apple.notes/x", "Notes · Shared data"),
            ("\(lib)/Group Containers/UBF8T346G9.Office/x", "Office · Shared data"),
            ("\(lib)/Application Support/Google/Chrome/Default/x", "Google · App data"),
            ("\(lib)/Application Support/Steam/steamapps/common/Half-Life 2/hl2.exe", "Steam · Half-Life 2"),
            ("\(lib)/Application Support/Steam/config/x", "Steam · App data"),
            ("\(lib)/Mail/V10/ABCDEF/INBOX.mbox/x.emlx", "Mail · Mailboxes"),
            ("\(lib)/Mail/V10/ABCDEF/INBOX.mbox/Data/Attachments/1/2/file.pdf", "Mail · Attachments"),
            ("\(lib)/Messages/chat.db", "Messages · Chat history"),
            ("\(lib)/Messages/Attachments/ab/12/IMG.heic", "Messages · Attachments"),
            ("\(lib)/CloudStorage/GoogleDrive-me@example.com/My Drive/a.txt", "Google Drive · Files"),
            ("\(lib)/CloudStorage/OneDrive-Personal/a.txt", "OneDrive · Files"),
            ("\(lib)/CloudStorage/Dropbox/a.txt", "Dropbox · Files"),
            ("\(lib)/CloudStorage/ProtonDrive-me/a.txt", "Proton Drive · Files")
        ]
    }

    func testFixtureNames() {
        for item in fixture {
            XCTAssertEqual(name(item.path).standaloneTitle, item.title, item.path)
        }
    }

    func testNoForbiddenTokensOrLibraryInNames() {
        for item in fixture {
            let title = name(item.path).standaloneTitle
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

    func testAppPlacesNameTheKindNotTheArea() {
        XCTAssertEqual(name("\(lib)/Group Containers/group.com.apple.notes/x").title, "Shared data")
        XCTAssertEqual(name("\(lib)/Caches/com.apple.Safari/x").title, "Cache")
        XCTAssertNil(name("\(lib)/Caches/com.apple.Safari/x").context)
        XCTAssertEqual(name("\(lib)/Application Support/Steam/steamapps/common/Celeste/x").title, "Celeste")
        XCTAssertEqual(name("\(lib)/Application Support/Steam/steamapps/common/Celeste/x").owner, .named("Steam"))
        XCTAssertEqual(name("\(lib)/Application Support/Steam/config/x").owner, .named("Steam"))
        XCTAssertEqual(name("\(lib)/Messages/Attachments/ab/c").owner, .app(id: "com.apple.MobileSMS"))
        XCTAssertEqual(name("\(lib)/CloudStorage/Dropbox/a.txt").owner, .named("Dropbox"))
    }
}
