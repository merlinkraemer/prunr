import AppKit
import XCTest
@testable import Prunr

final class AppCatalogTests: XCTestCase {
    private let catalog = AppCatalog(entries: [
        AppCatalogEntry(
            bundleIdentifier: "com.google.Chrome", name: "Google Chrome",
            names: ["Google Chrome", "Chrome"], path: "/Applications/Google Chrome.app"
        ),
        AppCatalogEntry(bundleIdentifier: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"),
        AppCatalogEntry(
            bundleIdentifier: "com.anthropic.claudefordesktop", name: "Claude", path: "/Applications/Claude.app"
        ),
        AppCatalogEntry(bundleIdentifier: "com.acme.prunr", name: "Prunr", path: "/Applications/Prunr.app"),
        AppCatalogEntry(
            bundleIdentifier: "com.ableton.live", name: "Ableton Live 12 Suite",
            path: "/Applications/Ableton Live 12 Suite.app"
        ),
        AppCatalogEntry(bundleIdentifier: "com.jetbrains.goland", name: "GoLand", path: "/Applications/GoLand.app"),
        AppCatalogEntry(bundleIdentifier: "com.valvesoftware.steam", name: "Steam", path: "/Applications/Steam.app"),
        AppCatalogEntry(
            bundleIdentifier: "me.example.fastsapp", name: "WhatsApp", path: "/Applications/WhatsApp.app"
        ),
        AppCatalogEntry(
            bundleIdentifier: "com.adobe.LightroomClassicCC7", name: "Adobe Lightroom Classic",
            path: "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app"
        )
    ])

    // MARK: - By bundle id

    func testIdentifierHitAndHelperRetry() {
        XCTAssertEqual(catalog.entry(forIdentifier: "com.google.Chrome")?.name, "Google Chrome")
        XCTAssertEqual(catalog.entry(forIdentifier: "COM.GOOGLE.CHROME")?.name, "Google Chrome")
        XCTAssertEqual(catalog.entry(forIdentifier: "com.apple.Safari.SafeBrowsing")?.name, "Safari")
        XCTAssertNil(catalog.entry(forIdentifier: "com.apple.wallpaper"))
        XCTAssertNil(catalog.entry(forIdentifier: "com.apple"))
    }

    // MARK: - By name

    func testExactNameIsCaseInsensitive() {
        XCTAssertEqual(catalog.entry(named: "claude")?.bundleIdentifier, "com.anthropic.claudefordesktop")
        XCTAssertEqual(catalog.entry(named: "Steam")?.bundleIdentifier, "com.valvesoftware.steam")
    }

    func testPrefixMatchNeedsASeparator() {
        XCTAssertEqual(catalog.entry(named: "Prunr backup")?.bundleIdentifier, "com.acme.prunr")
        XCTAssertEqual(catalog.entry(named: "Prunr-backup-20261014-1439")?.bundleIdentifier, "com.acme.prunr")
        XCTAssertEqual(catalog.entry(named: "Ableton")?.bundleIdentifier, "com.ableton.live")
        XCTAssertNil(catalog.entry(named: "Go"), "Go is not GoLand")
        XCTAssertNil(catalog.entry(named: "Prunrish"))
    }

    func testVendorFolderMatchesWithOrWithoutTheVendor() {
        XCTAssertEqual(catalog.entry(named: "Chrome", vendor: "Google")?.bundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(catalog.entry(named: "Lightroom", vendor: "Adobe")?.bundleIdentifier, "com.adobe.LightroomClassicCC7")
        XCTAssertNil(catalog.entry(named: "Photoshop", vendor: "Adobe"))
    }

    // MARK: - Owners

    func testInstalledAppsResolveToOneKey() {
        let byId = catalog.resolve(.app(id: "com.google.Chrome"))
        let byFolder = catalog.resolve(.named("Chrome", vendor: "Google"))
        XCTAssertEqual(byId, byFolder)
        XCTAssertEqual(byId.displayName, "Google Chrome")
        XCTAssertEqual(byId.icon, .app(bundleIdentifier: "com.google.Chrome"))

        XCTAssertEqual(
            catalog.resolve(.named("Claude")).key,
            catalog.resolve(.app(id: "com.anthropic.claudefordesktop")).key,
            "the Claude folder and the Claude cache are one owner"
        )
    }

    func testUninstalledAppKeepsItsNameAndGetsTheGenericIcon() {
        let gone = catalog.resolve(.app(id: "com.tinyspeck.slackmacgap"))
        XCTAssertEqual(gone.key, "app:com.tinyspeck.slackmacgap")
        XCTAssertEqual(gone.displayName, "Slack")
        XCTAssertEqual(gone.icon, .genericApp)

        let named = catalog.resolve(.named("Office"))
        XCTAssertEqual(named.key, "name:office")
        XCTAssertEqual(named.displayName, "Office")
        XCTAssertEqual(named.icon, .genericApp)
    }

    func testAppleDaemonsBelongToTheSystem() {
        let wallpaper = catalog.resolve(.app(id: "com.apple.wallpaper"))
        XCTAssertEqual(wallpaper.key, "system")
        XCTAssertEqual(wallpaper.displayName, "System")
        XCTAssertEqual(catalog.resolve(.app(id: "com.apple.Safari")).displayName, "Safari")
    }

    func testCategoryAndSystemOwners() {
        XCTAssertEqual(catalog.resolve(.category(.developer)).displayName, "Developer")
        XCTAssertEqual(catalog.resolve(.category(.developer)).icon, .category)
        XCTAssertEqual(catalog.resolve(.system).key, "system")
    }

    func testRealOwnerKeyStaysWhenAnotherAppHasTheName() {
        let icloud = catalog.resolve(.app(id: "net.whatsapp.WhatsApp"))
        XCTAssertEqual(icloud.key, "app:net.whatsapp.whatsapp")
        XCTAssertEqual(catalog.entry(named: "WhatsApp")?.bundleIdentifier, "me.example.fastsapp")
    }

    func testEmptyCatalogFallsBack() {
        XCTAssertEqual(AppCatalog.empty.resolve(.named("Steam")).displayName, "Steam")
        XCTAssertEqual(AppCatalog.empty.resolve(.app(id: "com.google.Chrome")).displayName, "Google Chrome")
    }

    // MARK: - Icon resolver

    @MainActor
    func testResolverLooksUpNamedAppsAndTheGenericIcon() {
        let claude = NSImage(size: NSSize(width: 16, height: 16))
        let generic = NSImage(size: NSSize(width: 8, height: 8))
        var namedLookups: [String] = []
        let resolver = UnitIconResolver(lookup: .init(
            applicationIcon: { _ in nil },
            fileIcon: { _ in nil },
            namedApplicationIcon: { name, vendor in
                namedLookups.append([vendor, name].compactMap { $0 }.joined(separator: " "))
                return name == "Claude" ? claude : nil
            },
            genericApplicationIcon: { generic }
        ))
        XCTAssertTrue(resolver.icon(for: .namedApp(name: "Claude", vendor: nil)) === claude)
        XCTAssertTrue(resolver.icon(for: .namedApp(name: "Claude", vendor: nil)) === claude)
        XCTAssertNil(resolver.icon(for: .namedApp(name: "Chrome", vendor: "Google")))
        XCTAssertEqual(namedLookups, ["Claude", "Google Chrome"])
        XCTAssertTrue(resolver.icon(for: .genericApp) === generic)
    }
}
