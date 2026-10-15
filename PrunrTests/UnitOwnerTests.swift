import XCTest
@testable import Prunr

final class UnitOwnerTests: XCTestCase {
    private let home = "/Users/alex"
    private let lib = "/Users/alex/Library"

    private func name(_ path: String) -> UnitName {
        UnitNamer.name(path: path, home: home)
    }

    // MARK: - Canonical bundle ids

    func testCanonicalisationTable() {
        let cases: [(String, String?)] = [
            ("com.apple.Safari", "com.apple.Safari"),
            ("group.com.apple.notes", "com.apple.notes"),
            ("group.net.whatsapp.WhatsApp.shared", "net.whatsapp.WhatsApp"),
            ("UBF8T346G9.com.microsoft.teams", "com.microsoft.teams"),
            ("6N38VWS5BX.ru.keepcoder.Telegram", "ru.keepcoder.Telegram"),
            ("UBF8T346G9.Office", nil),
            ("com.google.Chrome.helper", "com.google.Chrome"),
            ("com.google.Chrome.helper.Renderer", "com.google.Chrome"),
            ("com.anthropic.claudefordesktop.ShipIt", "com.anthropic.claudefordesktop"),
            ("com.acme.App.ShareExtension", "com.acme.App"),
            ("com.acme.App.TodayWidget", "com.acme.App"),
            ("com.acme.App.LoginAgent", "com.acme.App"),
            ("com.acme.App.mac", "com.acme.App"),
            ("com.acme.desktop", "com.acme.desktop"),
            ("com.figma.Desktop", "com.figma.Desktop"),
            ("com.apple.finder.plist", "com.apple.finder"),
            ("com.apple.Terminal.savedState", "com.apple.Terminal"),
            ("com.apple.Safari.SafeBrowsing", "com.apple.Safari.SafeBrowsing"),
            ("Claude", nil),
            ("default.store", nil),
            ("com.acme", nil)
        ]
        for (item, expected) in cases {
            XCTAssertEqual(AppIdentity.canonical(item), expected, item)
        }
    }

    func testICloudContainerIdentifiers() {
        XCTAssertEqual(AppIdentity.icloudIdentifier("iCloud~com~culturedcode~ThingsMac"), "com.culturedcode.ThingsMac")
        XCTAssertEqual(AppIdentity.icloudIdentifier("57T9237FN3~net~whatsapp~WhatsApp"), "net.whatsapp.WhatsApp")
        XCTAssertEqual(AppIdentity.icloudIdentifier("27N4MQEA55~pro~writer"), "pro.writer")
        XCTAssertEqual(AppIdentity.icloudIdentifier("com~apple~Pages"), "com.apple.Pages")
        XCTAssertNil(AppIdentity.icloudIdentifier("Documents"))
    }

    func testFallbackNames() {
        XCTAssertEqual(AppIdentity.fallbackName(forIdentifier: "com.google.Chrome"), "Google Chrome")
        XCTAssertEqual(AppIdentity.fallbackName(forIdentifier: "net.whatsapp.WhatsApp"), "WhatsApp")
        XCTAssertEqual(AppIdentity.fallbackName(forIdentifier: "com.acme.tool"), "Tool")
        XCTAssertEqual(UnitOwner.named("Claude").fallbackDisplayName, "Claude")
        XCTAssertEqual(UnitOwner.category(.developer).fallbackDisplayName, "Developer")
        XCTAssertEqual(UnitOwner.system.fallbackDisplayName, "System")
    }

    func testOwnerKeysMergeSpellings() {
        XCTAssertEqual(UnitOwner.app(id: "com.Google.Chrome").key, UnitOwner.app(id: "com.google.chrome").key)
        XCTAssertEqual(UnitOwner.named("Steam").key, UnitOwner.named("steam", vendor: nil).key)
        XCTAssertNotEqual(UnitOwner.named("Steam").key, UnitOwner.app(id: "com.valvesoftware.steam").key)
        XCTAssertEqual(UnitOwner.category(.downloads).key, "category:downloads")
    }

    // MARK: - Every rule yields its owner

    func testKindOwnedPlaces() {
        let cases: [(String, UnitOwner)] = [
            ("\(home)/.Trash/a.zip", .category(.trash)),
            ("\(home)/Downloads/ubuntu.iso", .category(.downloads)),
            ("\(lib)/Developer/Xcode/DerivedData/App-abcdefghijklmnopqrstuvwxyzab/Build/x", .category(.developer)),
            ("\(lib)/Developer/Xcode/Archives/2026/x", .category(.developer)),
            ("\(lib)/Developer/Xcode/iOS DeviceSupport/18.0/x", .category(.developer)),
            ("\(lib)/Developer/CoreSimulator/Devices/A/x", .category(.developer)),
            ("\(home)/.docker/x", .category(.developer)),
            ("\(home)/.colima/default/disk", .category(.developer)),
            ("\(home)/.npm/_cacache/x", .category(.developer)),
            ("\(home)/.ollama/models/blobs/x", .category(.developer)),
            ("\(home)/code/app/node_modules/x/y.js", .category(.developer)),
            ("\(home)/code/app/.venv/bin/python", .category(.developer)),
            ("\(home)/code/app/.git/HEAD", .category(.developer)),
            ("\(home)/Pictures/Photos Library.photoslibrary/x", .category(.mediaAndDocuments)),
            ("\(home)/Movies/Trip.fcpbundle/Day/Original Media/a.mov", .category(.mediaAndDocuments)),
            ("\(lib)/Mobile Documents/com~apple~CloudDocs/Work/a.txt", .category(.mediaAndDocuments)),
            ("\(home)/Music/Song Project/a.wav", .category(.audioProduction)),
            ("\(lib)/Mail/V10/A/B.mbox/Attachments/1/f.pdf", .app(id: "com.apple.mail")),
            ("\(lib)/Messages/Attachments/ab/c", .app(id: "com.apple.MobileSMS")),
            ("\(lib)/CloudStorage/GoogleDrive-me@example.com/a", .named("Google Drive")),
            ("\(lib)/Mobile Documents/iCloud~md~obsidian/Documents/x", .app(id: "md.obsidian")),
            ("\(lib)/Application Support/Steam/steamapps/common/Celeste/x", .named("Steam"))
        ]
        for (path, owner) in cases {
            XCTAssertEqual(name(path).owner, owner, path)
        }
    }

    func testAppOwnedLibraryPlaces() {
        let cases: [(String, UnitOwner, String)] = [
            ("Application Support/Claude/vm_bundles/x", .named("Claude"), "App data"),
            ("Application Support/com.spotify.client/x", .app(id: "com.spotify.client"), "App data"),
            ("Containers/com.apple.Safari/Data/x", .app(id: "com.apple.Safari"), "App data"),
            ("Caches/com.spotify.client/Data/x", .app(id: "com.spotify.client"), "Cache"),
            ("Caches/Ableton/x", .named("Ableton"), "Cache"),
            ("Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/x", .app(id: "ru.keepcoder.Telegram"), "Shared data"),
            ("WebKit/com.acme.App/WebsiteDataStore/x", .app(id: "com.acme.App"), "Website data"),
            ("HTTPStorages/com.acme.App/x", .app(id: "com.acme.App"), "Website data"),
            ("Logs/Acme Tool/x.log", .named("Acme Tool"), "Logs")
        ]
        for (relative, owner, title) in cases {
            let unit = name("\(lib)/\(relative)")
            XCTAssertEqual(unit.owner, owner, relative)
            XCTAssertEqual(unit.title, title, relative)
            XCTAssertEqual(unit.icon, .owner(owner), relative)
        }
    }

    func testDatedAndVersionedNamesReadAsTheirStem() {
        let backup = name("\(lib)/Application Support/Prunr-backup-20261014-1439/prunr.db")
        XCTAssertEqual(backup.title, "Prunr backup")
        XCTAssertEqual(backup.owner, .named("Prunr backup"))
        XCTAssertEqual(backup.standaloneTitle, "Prunr backup")
        let other = name("\(lib)/Application Support/Prunr-backup-20261015-0900/prunr.db")
        XCTAssertEqual(other.owner.key, backup.owner.key, "backups of one app share an owner")
    }

    func testStandaloneTitleNamesTheAppOnce() {
        XCTAssertEqual(name("\(lib)/Caches/com.spotify.client/x").standaloneTitle, "Spotify · Cache")
        XCTAssertEqual(name("\(lib)/Application Support/Steam/steamapps/common/Steam/x").standaloneTitle, "Steam")
        XCTAssertEqual(name("\(home)/Downloads/ubuntu.iso").standaloneTitle, "Downloads · ubuntu.iso")
    }

    // MARK: - Plain stems and sanitising

    func testPlainStem() {
        XCTAssertEqual(UnitNamer.plainStem("Prunr-backup-20261014-1439"), "Prunr backup")
        XCTAssertEqual(UnitNamer.plainStem("Xcode_26.1_Release_Candidate"), "Xcode")
        XCTAssertEqual(UnitNamer.plainStem("Meeting 2026-10-14 at 14.39.12"), "Meeting at")
        XCTAssertEqual(UnitNamer.plainStem("Tool-v2.3.1-arm64"), "Tool")
        XCTAssertEqual(UnitNamer.plainStem("cache-1a2b3c4d5e6f"), "cache")
        XCTAssertEqual(UnitNamer.plainStem("Build-0F8E2B9A-1C2D-4E5F-8A9B-0C1D2E3F4A5B"), "Build")
        XCTAssertNil(UnitNamer.plainStem("Claude"))
        XCTAssertNil(UnitNamer.plainStem("Google Chrome"))
        XCTAssertNil(UnitNamer.plainStem("20261014"))
    }

    func testSanitiserStripsDashedUUIDs() {
        let uuid = "0F8E2B9A-1C2D-4E5F-8A9B-0C1D2E3F4A5B"
        XCTAssertTrue(UnitNamer.containsForbiddenToken("Tests-\(uuid)"))
        XCTAssertEqual(UnitNamer.sanitize("PadTests-\(uuid)"), "PadTests")
        XCTAssertEqual(UnitNamer.displayComponent("PadTests-\(uuid).plist"), "PadTests.plist")
        XCTAssertNil(UnitNamer.displayComponent(uuid))
    }

    // MARK: - Guard: rules are generic

    /// Every rule must come from macOS or tool conventions, never from one
    /// person's folder layout.
    func testRuleSourcesHoldNoHomeSpecificTokens() throws {
        let models = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Prunr/Models")
        let files = try FileManager.default.contentsOfDirectory(atPath: models.path)
            .filter { $0.hasPrefix("UnitRules") || $0 == "UnitNamer.swift" || $0 == "UnitResolver.swift"
                || $0 == "UnitOwner.swift" || $0 == "GrowthCategory.swift" }
        XCTAssertGreaterThanOrEqual(files.count, 6)
        let forbidden = [
            "(?<!/usr)/local/", "dev/build", "\\bmerlin", "\\bpara\\b", "\\b[0-9]-(projects|areas|resources|archive)\\b",
            "/\\.pi/", "\\bagent-[0-9a-f]{6,}"
        ]
        for file in files {
            let source = try String(contentsOf: models.appendingPathComponent(file), encoding: .utf8).lowercased()
            for pattern in forbidden {
                XCTAssertNil(source.range(of: pattern, options: .regularExpression), "\(file) matches \"\(pattern)\"")
            }
        }
    }
}
