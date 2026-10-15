import XCTest
@testable import Prunr

final class OwnerFeedTests: XCTestCase {
    private static let home = "/Users/alex"
    private static let lib = "/Users/alex/Library"
    private static let gb: Int64 = 1_000_000_000

    private static let chrome = AppCatalogEntry(
        bundleIdentifier: "com.google.Chrome", name: "Chrome", names: ["Chrome", "Google Chrome"],
        path: "/Applications/Google Chrome.app"
    )
    private static let catalog = AppCatalog(entries: [chrome])

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private var now: Date { utc.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 18))! }

    private func slot(_ path: String, hour: Int, net: Int64) -> JournalSlot {
        let at = utc.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: hour))!
        return JournalSlot(
            unitKey: UnitResolver.resolve(path: path, home: Self.home),
            category: "other",
            subcategory: "",
            source: .watch,
            slot: Int64(floor(at.timeIntervalSince1970 / Double(JournalSlot.slotSeconds))),
            netBytes: net,
            grossBytes: abs(net),
            firstAt: at,
            observedSince: nil
        )
    }

    private func groups(_ slots: [JournalSlot], catalog: AppCatalog = OwnerFeedTests.catalog) throws -> [ChangeGroup] {
        let feed = EpisodeBuilder.build(slots: slots, now: now, calendar: utc, home: Self.home, catalog: catalog)
        return try XCTUnwrap(feed.days.first).groups
    }

    func testAnAppsPlacesAreOneRowTitledByTheAppWithItsIcon() throws {
        let groups = try groups([
            slot("\(Self.lib)/Application Support/Google/Chrome/Default/History", hour: 9, net: 2 * Self.gb),
            slot("\(Self.lib)/Caches/com.google.Chrome.helper/Cache/data_1", hour: 10, net: 7 * Self.gb)
        ])

        XCTAssertEqual(groups.count, 1)
        let chrome = try XCTUnwrap(groups.first)
        XCTAssertEqual(chrome.rowTitle, "Chrome")
        XCTAssertEqual(chrome.rowIconSource, .app(bundleIdentifier: "com.google.Chrome"))
        XCTAssertEqual(chrome.netBytes, 9 * Self.gb)
        XCTAssertTrue(chrome.isLargeGrowth)
        XCTAssertEqual(Set(chrome.episodes.map(\.title)), ["App data", "Cache"])
        XCTAssertTrue(chrome.episodes.allSatisfy { $0.rowIconSource == .app(bundleIdentifier: "com.google.Chrome") })
        XCTAssertEqual(FeedPage.feed.opening(chrome), .group(chrome))

        let cache = try XCTUnwrap(chrome.episodes.first { $0.title == "Cache" })
        XCTAssertEqual(chrome.headerTitle(for: cache), "Cache")
        XCTAssertEqual(
            EpisodeBuilder.contentsCaption(for: cache, headerTitle: chrome.headerTitle(for: cache), home: Self.home),
            "Chrome · ~/Library/Caches/com.google.Chrome.helper"
        )
    }

    func testAnAppWithOnePlaceStillReadsItsNameAndOpensTheContents() throws {
        let groups = try groups([slot("\(Self.lib)/Caches/com.spotify.client/Data/x", hour: 9, net: 2 * Self.gb)],
                                catalog: AppCatalog(entries: [
                                    AppCatalogEntry(bundleIdentifier: "com.spotify.client", name: "Spotify", path: "/Applications/Spotify.app")
                                ]))
        let spotify = try XCTUnwrap(groups.first)
        let place = try XCTUnwrap(spotify.episodes.first)

        XCTAssertEqual(spotify.rowTitle, "Spotify")
        XCTAssertNil(spotify.rowShortTitle)
        XCTAssertEqual(FeedPage.feed.opening(spotify), .place(spotify, place))
        XCTAssertEqual(spotify.headerTitle(for: place), "Spotify")
        XCTAssertEqual(spotify.headerIconSource(for: place), .app(bundleIdentifier: "com.spotify.client"))
        XCTAssertEqual(
            EpisodeBuilder.contentsCaption(for: place, headerTitle: spotify.headerTitle(for: place), home: Self.home),
            "Cache · ~/Library/Caches/com.spotify.client"
        )
    }

    func testAnUninstalledAppReadsItsNameWithTheGenericAppIcon() throws {
        let groups = try groups([slot("\(Self.lib)/Caches/com.acme.Widgets/x", hour: 9, net: 2 * Self.gb)], catalog: .empty)
        let widgets = try XCTUnwrap(groups.first)
        XCTAssertEqual(widgets.rowTitle, "Widgets")
        XCTAssertEqual(widgets.rowIconSource, .genericApp)
        XCTAssertEqual(widgets.episodes.first?.title, "Cache")
    }

    func testTheSameAppByIdAndByFolderNameIsOneOwnerOnceInstalled() throws {
        let claude = AppCatalogEntry(
            bundleIdentifier: "com.anthropic.claudefordesktop", name: "Claude", path: "/Applications/Claude.app"
        )
        let slots = [
            slot("\(Self.lib)/Application Support/Claude/vm/disk.img", hour: 9, net: 2 * Self.gb),
            slot("\(Self.lib)/Caches/com.anthropic.claudefordesktop.ShipIt/update.zip", hour: 10, net: 1 * Self.gb)
        ]
        XCTAssertEqual(try groups(slots, catalog: AppCatalog(entries: [claude])).map(\.rowTitle), ["Claude"])
        XCTAssertEqual(try groups(slots, catalog: .empty).count, 2, "without the app the two cannot be matched")
    }

    func testSystemReadsSystemEvenWithOnePlace() throws {
        let groups = try groups([slot("\(Self.lib)/Preferences/com.acme.app.plist", hour: 9, net: 2 * Self.gb)])
        let system = try XCTUnwrap(groups.first)
        let place = try XCTUnwrap(system.episodes.first)
        XCTAssertEqual(system.rowTitle, "System")
        XCTAssertNil(system.rowIconSource)
        XCTAssertEqual(system.headerTitle(for: place), "System")
    }

    func testCategoryOwnersLookAsBefore() throws {
        let iso = "\(Self.home)/Downloads/ubuntu-24.04.iso"
        let solo = try XCTUnwrap(try groups([slot(iso, hour: 9, net: 5 * Self.gb)]).first)
        let place = try XCTUnwrap(solo.episodes.first)
        XCTAssertEqual(solo.rowTitle, "Downloads · ubuntu-24.04.iso")
        XCTAssertEqual(solo.rowShortTitle, "ubuntu-24.04.iso")
        XCTAssertEqual(solo.rowIconSource, .file(path: iso))
        XCTAssertEqual(solo.headerTitle(for: place), "Downloads · ubuntu-24.04.iso")
        XCTAssertEqual(
            EpisodeBuilder.contentsCaption(for: place, headerTitle: solo.headerTitle(for: place), home: Self.home),
            "~/Downloads/ubuntu-24.04.iso"
        )

        let several = try XCTUnwrap(try groups([
            slot(iso, hour: 9, net: 5 * Self.gb),
            slot("\(Self.home)/Downloads/movie.mkv", hour: 10, net: 2 * Self.gb)
        ]).first)
        XCTAssertEqual(several.rowTitle, "Downloads")
        XCTAssertNil(several.rowIconSource)
        XCTAssertEqual(several.episodes.count, 2)
    }

    func testOwnersSortBySizeAndAppsSitBesideCategories() throws {
        let groups = try groups([
            slot("\(Self.lib)/Caches/com.google.Chrome/x", hour: 9, net: 3 * Self.gb),
            slot("\(Self.home)/Downloads/a.iso", hour: 10, net: 8 * Self.gb),
            slot("\(Self.lib)/Caches/com.acme.Widgets/x", hour: 11, net: -2 * Self.gb)
        ])
        XCTAssertEqual(groups.map(\.rowTitle), ["Downloads · a.iso", "Chrome", "Widgets"])
    }

    func testPlainFoldersUseFindersIconAndTheTrashKeepsItsSymbol() throws {
        let feed = EpisodeBuilder.build(
            slots: [
                slot("\(Self.home)/Documents/Archive/x.pdf", hour: 9, net: 2 * Self.gb),
                slot("\(Self.home)/.Trash/x", hour: 10, net: -2 * Self.gb)
            ],
            now: now, calendar: utc, home: Self.home
        )
        let archive = try XCTUnwrap(feed.episodes.first { $0.rootPath == "\(Self.home)/Documents/Archive" })
        XCTAssertEqual(archive.rowIconSource, .file(path: "\(Self.home)/Documents/Archive"))
        let trash = try XCTUnwrap(feed.episodes.first { $0.title == "Trash emptied" })
        XCTAssertEqual(trash.rowIconSource, .category)
    }

    func testRowTitlesNeverCarryTheLocation() throws {
        let feed = EpisodeBuilder.build(
            slots: [slot("\(Self.lib)/Application Support/Google/Chrome/Default/History", hour: 9, net: 2 * Self.gb)],
            now: now, calendar: utc, home: Self.home, catalog: Self.catalog
        )
        let place = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(place.title, "App data")
        XCTAssertFalse(place.title.contains("Application Support"))
    }

    func testAFeedReadWithoutTheCatalogCanBeNamedLater() throws {
        let feed = EpisodeBuilder.build(
            slots: [slot("\(Self.lib)/Caches/com.google.Chrome/x", hour: 9, net: 3 * Self.gb)],
            now: now, calendar: utc, home: Self.home
        )
        XCTAssertEqual(feed.ownerAppIdentifiers, ["com.google.Chrome"])
        XCTAssertEqual(feed.days.first?.groups.first?.rowTitle, "Google Chrome")
        XCTAssertEqual(feed.days.first?.groups.first?.rowIconSource, .genericApp)

        let named = feed.resolvingOwners(with: Self.catalog)
        XCTAssertEqual(named.days.first?.groups.first?.rowTitle, "Chrome")
        XCTAssertEqual(named.days.first?.groups.first?.rowIconSource, .app(bundleIdentifier: "com.google.Chrome"))
    }
}
