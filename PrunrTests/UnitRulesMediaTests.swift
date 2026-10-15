import XCTest
@testable import Prunr

final class UnitRulesMediaTests: XCTestCase {
    private let home = "/Users/tester"

    private func key(_ path: String) -> String {
        UnitResolver.resolve(path: path, home: home)
    }

    private func name(_ path: String) -> UnitName {
        UnitNamer.name(forKey: key(path), home: home)
    }

    // MARK: - Photos

    func testPhotosLibraryTakesBundleAsRoot() {
        let path = "/Users/tester/Pictures/Photos Library.photoslibrary/originals/A/IMG_0001.heic"
        XCTAssertEqual(key(path), "photos-library|/Users/tester/Pictures/Photos Library.photoslibrary")
        XCTAssertEqual(name(path), UnitName(title: "Photos library", category: .mediaAndDocuments, icon: .photos))
    }

    func testCustomPhotosLibraryNameIsShown() {
        let path = "/Volumes/Archive/Wedding 2019.photoslibrary/database/Photos.sqlite"
        XCTAssertEqual(key(path), "photos-library|/Volumes/Archive/Wedding 2019.photoslibrary")
        XCTAssertEqual(name(path).title, "Photos library · Wedding 2019")
    }

    // MARK: - iCloud

    func testICloudDriveTopFolder() {
        let path = "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/Projects/Client/file.psd"
        XCTAssertEqual(key(path), "icloud-drive|/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/Projects")
        XCTAssertEqual(name(path), UnitName(title: "iCloud Drive · Projects", category: .mediaAndDocuments))
    }

    func testICloudDriveRoot() {
        let path = "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs"
        XCTAssertEqual(name(path).title, "iCloud Drive")
    }

    func testOtherICloudContainersBelongToTheirApp() {
        let cases: [(String, String, String)] = [
            ("com~apple~Pages", "com.apple.Pages", "Pages · iCloud"),
            ("iCloud~com~culturedcode~ThingsMac", "com.culturedcode.ThingsMac", "ThingsMac · iCloud"),
            ("27N4MQEA55~pro~writer", "pro.writer", "Writer · iCloud"),
            ("57T9237FN3~net~whatsapp~WhatsApp", "net.whatsapp.WhatsApp", "WhatsApp · iCloud"),
            ("com~apple~Numbers", "com.apple.Numbers", "Numbers · iCloud")
        ]
        for (container, id, standalone) in cases {
            let path = "/Users/tester/Library/Mobile Documents/\(container)/Documents/a/b.bin"
            XCTAssertEqual(
                key(path),
                "icloud-container|/Users/tester/Library/Mobile Documents/\(container)",
                container
            )
            XCTAssertEqual(name(path).title, "iCloud", container)
            XCTAssertEqual(name(path).owner, .app(id: id), container)
            XCTAssertEqual(name(path).standaloneTitle, standalone, container)
            XCTAssertEqual(name(path).category, .mediaAndDocuments, container)
        }
    }

    // MARK: - Final Cut Pro

    func testFinalCutLibraryTakesBundleAsRoot() {
        let path = "/Users/tester/Movies/Trip.fcpbundle/2024-05-01/Original Media/clip.mov"
        XCTAssertEqual(key(path), "fcp-library|/Users/tester/Movies/Trip.fcpbundle")
        XCTAssertEqual(name(path), UnitName(title: "Final Cut Pro library · Trip", category: .mediaAndDocuments, icon: .finalCutPro))
    }

    func testFinalCutRenderAndCacheFoldersReadAsRenderFiles() {
        for folder in ["Render Files", "Cache"] {
            let path = "/Users/tester/Movies/Trip.fcpbundle/2024-05-01/\(folder)/High Quality Media/x.mov"
            XCTAssertEqual(key(path), "fcp-render|/Users/tester/Movies/Trip.fcpbundle/2024-05-01/\(folder)", folder)
            XCTAssertEqual(
                name(path),
                UnitName(
                    title: "Final Cut Pro render files · Trip", context: "2024-05-01",
                    category: .mediaAndDocuments, icon: .finalCutPro
                ),
                folder
            )
        }
    }

    // MARK: - Ableton

    func testAbletonProjectFolder() {
        let path = "/Users/tester/Music/Ableton/Night Drive Project/Samples/Recorded/take1.wav"
        XCTAssertEqual(key(path), "ableton-project|/Users/tester/Music/Ableton/Night Drive Project")
        XCTAssertEqual(name(path), UnitName(title: "Ableton project · Night Drive", category: .audioProduction, icon: .abletonLive))
    }

    func testAbletonSetParentResolvesToProject() {
        let path = "/Users/tester/Audio Production/Tracks/Lost Signal/Lost Signal.als"
        XCTAssertEqual(key(path), "ableton-project|/Users/tester/Audio Production/Tracks/Lost Signal")
        XCTAssertEqual(name(path), UnitName(title: "Ableton project · Lost Signal", category: .audioProduction, icon: .abletonLive))
    }

    func testBothAbletonFormsGiveSameName() {
        XCTAssertEqual(
            name("/Users/tester/Music/Night Drive Project/Night Drive.als").title,
            "Ableton project · Night Drive"
        )
        XCTAssertEqual(
            name("/Users/tester/Music/Night Drive/Night Drive.als").title,
            "Ableton project · Night Drive"
        )
    }

    func testAbletonUserLibrary() {
        let path = "/Users/tester/Music/Ableton/User Library/Samples/Imported/kick.wav"
        XCTAssertEqual(key(path), "ableton-library|/Users/tester/Music/Ableton/User Library")
        XCTAssertEqual(name(path), UnitName(title: "Ableton library", category: .audioProduction, icon: .abletonLive))
    }

    func testSetDirectlyInHomeIsNotAProject() {
        XCTAssertNotEqual(UnitResolver.resolveKey(path: "/Users/tester/loose.als", home: home).kind, .abletonProject)
    }

    // MARK: - Guard fixture

    private static let fixture = [
        "/Users/tester/Pictures/Photos Library.photoslibrary/resources/derivatives/0/0_0_abcdef0123456789abcdef0123456789.jpeg",
        "/Users/tester/Pictures/Wedding.photoslibrary/database/Photos.sqlite",
        "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/Desktop/a.txt",
        "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/Work/b.txt",
        "/Users/tester/Library/Mobile Documents/com~apple~Pages/Documents/c.pages",
        "/Users/tester/Library/Mobile Documents/iCloud~com~culturedcode~ThingsMac/Documents/db",
        "/Users/tester/Library/Mobile Documents/27N4MQEA55~pro~writer/Documents/x.txt",
        "/Users/tester/Movies/Trip.fcpbundle/2024-05-01/Render Files/a.mov",
        "/Users/tester/Movies/Trip.fcpbundle/2024-05-01/Original Media/a.mov",
        "/Users/tester/Music/Ableton/Night Drive Project/Samples/a.wav",
        "/Users/tester/Music/Ableton/User Library/Presets/a.adg",
        "/Users/tester/Audio Production/Lost Signal/Lost Signal.als"
    ]

    func testNoNameShowsForbiddenTokensOrFallsToPlace() {
        for path in Self.fixture {
            let resolved = UnitResolver.resolveKey(path: path, home: home)
            XCTAssertNotEqual(resolved.kind, .place, path)
            XCTAssertNotEqual(resolved.kind, .library, path)
            let unitName = UnitNamer.name(for: resolved, home: home)
            XCTAssertFalse(UnitNamer.containsForbiddenToken(unitName.title), unitName.title)
            XCTAssertFalse(UnitNamer.containsForbiddenToken(unitName.context ?? ""), path)
            XCTAssertFalse(unitName.title.contains("Library/"), unitName.title)
        }
    }
}
