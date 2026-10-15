import AppKit
import XCTest
@testable import Prunr

final class UnitIconTests: XCTestCase {
    private let home = "/Users/tester"
    private let lib = "/Users/tester/Library"

    private func icon(_ path: String) -> UnitIconSource {
        UnitNamer.name(path: path, home: home).icon
    }

    // MARK: - Mapping per pack

    func testDeveloperPackIcons() {
        let xcode = UnitIconSource.app(bundleIdentifier: "com.apple.dt.Xcode")
        let docker = UnitIconSource.app(bundleIdentifier: "com.docker.docker")
        XCTAssertEqual(icon("\(lib)/Developer/Xcode/DerivedData/Prunr-bkgqxabcdefghijklmnopqrstu/Build/x.o"), xcode)
        XCTAssertEqual(icon("\(lib)/Developer/Xcode/DerivedData/ModuleCache.noindex/x"), xcode)
        XCTAssertEqual(icon("\(lib)/Developer/Xcode/Archives/2026-10-01/App.xcarchive/x"), xcode)
        XCTAssertEqual(icon("\(lib)/Developer/Xcode/iOS DeviceSupport/18.0/x"), xcode)
        XCTAssertEqual(icon("\(lib)/Developer/CoreSimulator/Devices/ABC/data/x"), xcode)
        XCTAssertEqual(icon("\(lib)/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"), docker)
        XCTAssertEqual(icon("\(home)/.docker/x"), docker)
        XCTAssertEqual(icon("\(home)/.colima/default/disk.img"), docker)
        XCTAssertEqual(icon("\(home)/dev/app/node_modules/react/index.js"), .category)
        XCTAssertEqual(icon("\(home)/.npm/_cacache/x"), .category)
    }

    func testMediaPackIcons() {
        XCTAssertEqual(
            icon("\(home)/Pictures/Photos Library.photoslibrary/originals/A/IMG.heic"),
            .app(bundleIdentifier: "com.apple.Photos")
        )
        let finalCut = UnitIconSource.app(bundleIdentifier: "com.apple.FinalCut")
        XCTAssertEqual(icon("\(home)/Movies/Trip.fcpbundle/Day 1/Original Media/a.mov"), finalCut)
        XCTAssertEqual(icon("\(home)/Movies/Trip.fcpbundle/Day 1/Render Files/x.mov"), finalCut)
        let ableton = UnitIconSource.app(bundleIdentifier: "com.ableton.live")
        XCTAssertEqual(icon("\(home)/Music/Song Project/Samples/a.wav"), ableton)
        XCTAssertEqual(icon("\(home)/Music/Ableton/User Library/Samples/a.wav"), ableton)
        XCTAssertEqual(
            icon("\(lib)/Mobile Documents/iCloud~com~culturedcode~ThingsMac/Documents/x"),
            .app(bundleIdentifier: "com.culturedcode.ThingsMac")
        )
        XCTAssertEqual(
            icon("\(lib)/Mobile Documents/com~apple~Pages/Documents/x.pages"),
            .app(bundleIdentifier: "com.apple.Pages")
        )
        XCTAssertEqual(
            icon("\(lib)/Mobile Documents/27N4MQEA55~pro~writer/Documents/x"),
            .app(bundleIdentifier: "pro.writer")
        )
        XCTAssertEqual(icon("\(lib)/Mobile Documents/com~apple~CloudDocs/Projects/x"), .category)
    }

    func testAppPackIcons() {
        XCTAssertEqual(
            icon("\(lib)/Application Support/Steam/steamapps/common/Half-Life 2/hl2.exe"),
            .app(bundleIdentifier: "com.valvesoftware.steam")
        )
        let mail = UnitIconSource.app(bundleIdentifier: "com.apple.mail")
        let messages = UnitIconSource.app(bundleIdentifier: "com.apple.MobileSMS")
        XCTAssertEqual(icon("\(lib)/Mail/V10/ABCDEF/INBOX.mbox/x.emlx"), mail)
        XCTAssertEqual(icon("\(lib)/Mail/V10/ABCDEF/INBOX.mbox/Data/Attachments/1/2/file.pdf"), mail)
        XCTAssertEqual(icon("\(lib)/Messages/chat.db"), messages)
        XCTAssertEqual(icon("\(lib)/Messages/Attachments/ab/12/IMG.heic"), messages)
        XCTAssertEqual(icon("\(lib)/CloudStorage/Dropbox/a.txt"), .namedApp(name: "Dropbox", vendor: nil))
    }

    func testLibraryItemsWithBundleIdsUseThatApp() {
        XCTAssertEqual(icon("\(lib)/Caches/com.apple.Safari/WebKitCache/x.db"), .app(bundleIdentifier: "com.apple.Safari"))
        XCTAssertEqual(icon("\(lib)/Containers/com.apple.mail/Data/x"), .app(bundleIdentifier: "com.apple.mail"))
        XCTAssertEqual(
            icon("\(lib)/Group Containers/group.com.apple.notes/x"),
            .app(bundleIdentifier: "com.apple.notes")
        )
        XCTAssertEqual(
            icon("\(lib)/Group Containers/UBF8T346G9.com.microsoft.teams/x"),
            .app(bundleIdentifier: "com.microsoft.teams")
        )
        XCTAssertEqual(
            icon("\(lib)/Application Support/com.spotify.client/x"),
            .app(bundleIdentifier: "com.spotify.client")
        )
        XCTAssertEqual(icon("\(lib)/Caches/com.google.Chrome.helper/x"), .app(bundleIdentifier: "com.google.Chrome"))
        XCTAssertEqual(icon("\(lib)/Preferences/com.apple.finder.plist"), .category)
        XCTAssertEqual(icon("\(lib)/Group Containers/UBF8T346G9.Office/x"), .namedApp(name: "Office", vendor: nil))
        XCTAssertEqual(icon("\(lib)/Caches/Homebrew/downloads/a.tar.gz"), .namedApp(name: "Homebrew", vendor: nil))
        XCTAssertEqual(icon("\(lib)/Application Support/Google/Chrome/Default/x"), .namedApp(name: "Chrome", vendor: "Google"))
    }

    func testDownloadFileUsesItsOwnIcon() {
        XCTAssertEqual(icon("\(home)/Downloads/ubuntu.iso"), .file(path: "\(home)/Downloads/ubuntu.iso"))
        XCTAssertEqual(icon("\(home)/Downloads/Album/track.mp3"), .file(path: "\(home)/Downloads/Album"))
        XCTAssertEqual(icon("\(home)/Downloads"), .category)
    }

    func testOtherPlacesFallBackToCategory() {
        XCTAssertEqual(icon("\(home)/.Trash/old.zip"), .category)
        XCTAssertEqual(icon("\(home)/Documents/Archive/x.pdf"), .category)
        XCTAssertEqual(icon("/opt/homebrew/Cellar/x"), .category)
        XCTAssertEqual(UnitNamer.name(forKey: "unknown-kind|\(home)/Documents/Archive", home: home).icon, .category)
    }

    // MARK: - Resolver

    @MainActor
    func testResolverCachesPerSourceAndFallsBackForMissingApp() {
        var appLookups: [String] = []
        var fileLookups: [String] = []
        let installed = NSImage(size: NSSize(width: 16, height: 16))
        let file = NSImage(size: NSSize(width: 8, height: 8))
        let resolver = UnitIconResolver(lookup: .init(
            applicationIcon: { id in
                appLookups.append(id)
                return id == "com.apple.dt.Xcode" ? installed : nil
            },
            fileIcon: { path in
                fileLookups.append(path)
                return path == "/Users/tester/Downloads/a.iso" ? file : nil
            }
        ))

        XCTAssertTrue(resolver.icon(for: .xcode) === installed)
        XCTAssertTrue(resolver.icon(for: .xcode) === installed)
        XCTAssertNil(resolver.icon(for: .steam), "missing app falls back to the category symbol")
        XCTAssertNil(resolver.icon(for: .steam))
        XCTAssertEqual(appLookups, ["com.apple.dt.Xcode", "com.valvesoftware.steam"], "hits and misses are cached")

        XCTAssertTrue(resolver.icon(for: .file(path: "/Users/tester/Downloads/a.iso")) === file)
        XCTAssertNil(resolver.icon(for: .file(path: "/Users/tester/Downloads/gone.zip")))
        XCTAssertNil(resolver.icon(for: .file(path: "/Users/tester/Downloads/gone.zip")))
        XCTAssertEqual(fileLookups.count, 2)

        XCTAssertNil(resolver.icon(for: .category))
        XCTAssertEqual(appLookups.count + fileLookups.count, 4, "category never looks anything up")
    }

    @MainActor
    func testWorkspaceLookupFallsBackForMissingFileAndUnknownApp() {
        let resolver = UnitIconResolver(lookup: .workspace)
        XCTAssertNil(resolver.icon(for: .file(path: "/nonexistent-\(UUID().uuidString)/a.iso")))
        XCTAssertNil(resolver.icon(for: .app(bundleIdentifier: "com.example.not-installed-\(UUID().uuidString)")))
    }
}
