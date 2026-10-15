import GRDB
import XCTest
@testable import Prunr

/// O3 key and category changes, on a made-up home.
final class OwnerUnitsTests: PrunrTestCase {
    private let home = "/Users/alex"
    private let lib = "/Users/alex/Library"
    private let xcodeHash = "bkgqxrtyuiopasdfghjklzxcvbnm"

    private func key(_ path: String) -> String {
        UnitResolver.resolve(path: path, home: home)
    }

    private func name(_ path: String) -> UnitName {
        UnitNamer.name(path: path, home: home)
    }

    private func category(_ path: String) -> GrowthCategory {
        GrowthCategory.categorize(path: path, home: home)
    }

    // MARK: - Library areas

    func testPreferencesAreOnePlaceOwnedByTheSystem() {
        for relative in [
            "Preferences/com.apple.finder.plist",
            "Preferences/AppTests-0F8E2B9A-1C2D-4E5F-8A9B-0C1D2E3F4A5B.plist",
            "Preferences/ByHost/com.apple.screensaver.0F8E2B9A-1C2D-4E5F-8A9B-0C1D2E3F4A5B.plist"
        ] {
            XCTAssertEqual(key("\(lib)/\(relative)"), "library|\(lib)/Preferences", relative)
        }
        let unit = name("\(lib)/Preferences/com.apple.finder.plist")
        XCTAssertEqual(unit.title, "Preferences")
        XCTAssertEqual(unit.owner, .system)
    }

    func testFilesLyingDirectlyInAnAreaAreOneAreaPlace() {
        XCTAssertEqual(key("\(lib)/Application Support/default.store"), "library|\(lib)/Application Support")
        XCTAssertEqual(key("\(lib)/Cookies/com.acme.App.binarycookies"), "library|\(lib)/Cookies")
        XCTAssertEqual(key("\(lib)/Logs/install.log"), "library|\(lib)/Logs")
        let unit = name("\(lib)/Application Support/.ACCC_Lock")
        XCTAssertEqual(unit.title, "Application Support")
        XCTAssertEqual(unit.owner, .system)
        XCTAssertEqual(key("\(lib)/Caches/com.acme.App/blob"), "library|\(lib)/Caches/com.acme.App")
    }

    func testVendorFoldersGoOneLevelDeeper() {
        let chrome = "\(lib)/Application Support/Google/Chrome/Default/History"
        XCTAssertEqual(key(chrome), "library|\(lib)/Application Support/Google/Chrome")
        XCTAssertEqual(name(chrome).owner, .named("Chrome", vendor: "Google"))
        XCTAssertEqual(name(chrome).title, "App data")
        XCTAssertEqual(key("\(lib)/Caches/Google/Chrome/Default/Cache/x"), "library|\(lib)/Caches/Google/Chrome")
        XCTAssertEqual(name("\(lib)/Caches/Google/Chrome/Default/Cache/x").title, "Cache")
        XCTAssertEqual(
            key("\(lib)/Application Support/Adobe/Lightroom/Presets/x"),
            "library|\(lib)/Application Support/Adobe/Lightroom"
        )
        XCTAssertEqual(key("\(lib)/Application Support/Google/updater.log"), "library|\(lib)/Application Support/Google")
        XCTAssertEqual(key("\(lib)/Application Support/Claude/Cache/x"), "library|\(lib)/Application Support/Claude")
    }

    // MARK: - Hidden home folders

    func testHiddenHomeFoldersAreToolUnits() {
        let cases: [(String, String, String)] = [
            ("\(home)/.codex/packages/daemon/x", "tool|\(home)/.codex", "Codex data"),
            ("\(home)/.rustup/toolchains/stable/lib/x", "tool|\(home)/.rustup", "Rustup data"),
            ("\(home)/.local/share/uv/python/x", "tool|\(home)/.local/share/uv", "uv data"),
            ("\(home)/.local/state/opencode/x", "tool|\(home)/.local/state/opencode", "Opencode data"),
            ("\(home)/.config/gh/hosts.yml", "tool|\(home)/.config/gh", "gh data"),
            ("\(home)/.local/bin/uv", "tool|\(home)/.local/bin", "bin data"),
            ("\(home)/.nvm/versions/node/v20/lib/node_modules/x", "tool|\(home)/.nvm", "Nvm data")
        ]
        for (path, expectedKey, title) in cases {
            XCTAssertEqual(key(path), expectedKey, path)
            XCTAssertEqual(name(path).title, title, path)
            XCTAssertEqual(name(path).category, .developer, path)
            XCTAssertEqual(name(path).owner, .category(.developer), path)
        }
    }

    func testOwnRulesInsideHiddenFoldersStillWin() {
        XCTAssertEqual(key("\(home)/.Trash/x"), "trash|\(home)/.Trash")
        XCTAssertEqual(key("\(home)/.docker/x"), "docker|\(home)/.docker")
        XCTAssertEqual(key("\(home)/.colima/x"), "colima|\(home)/.colima")
        XCTAssertEqual(key("\(home)/.npm/_cacache/x"), "package-cache|\(home)/.npm")
        XCTAssertEqual(key("\(home)/.cache/uv/x"), "package-cache|\(home)/.cache/uv")
        XCTAssertEqual(key("\(home)/.ollama/models/x"), "model-store|\(home)/.ollama/models")
        XCTAssertEqual(key("\(home)/.pi/runs/x/node_modules/y/z.js"), "node-modules|\(home)/.pi/runs/x/node_modules")
        XCTAssertEqual(key("\(home)/.zsh_history"), "place|\(home)/.zsh_history")
    }

    // MARK: - DerivedData by shape

    func testDerivedDataIsFoundAnywhere() {
        let cases: [(String, String, String)] = [
            ("\(home)/Builds/pad-dd/Build/Products/Debug/Pad.app/x", "\(home)/Builds/pad-dd", "pad"),
            ("\(home)/Builds/pad-dd/Index.noindex/DataStore/x", "\(home)/Builds/pad-dd", "pad"),
            ("\(home)/Builds/pad-dd/ModuleCache.noindex/x.pcm", "\(home)/Builds/pad-dd", "pad"),
            ("\(home)/code/Weatherly/build/Build/Intermediates.noindex/x.o", "\(home)/code/Weatherly/build", "Weatherly"),
            ("/Volumes/Fast/DD/Weatherly-\(xcodeHash)/Logs/Build/x", "/Volumes/Fast/DD/Weatherly-\(xcodeHash)", "Weatherly"),
            ("\(home)/ci/agent-a01e5f558ad039a9d-dd/Index.noindex/x", "\(home)/ci/agent-a01e5f558ad039a9d-dd", "agent"),
            ("\(home)/code/pad/build/fix04/derived/Index.noindex/x", "\(home)/code/pad/build/fix04/derived", "fix04"),
            ("\(home)/code/Bounce/build/macos-dev/Index.noindex/x", "\(home)/code/Bounce/build/macos-dev", "Bounce")
        ]
        for (path, root, project) in cases {
            XCTAssertEqual(key(path), "xcode-build|\(root)", path)
            XCTAssertEqual(name(path).title, "Xcode build files · \(project)", path)
            XCTAssertEqual(name(path).shortTitle, project, path)
            XCTAssertEqual(name(path).owner, .category(.developer), path)
            XCTAssertEqual(name(path).category, .developer, path)
            if path.contains(".noindex/") || path.contains("/Build/Products/") {
                XCTAssertEqual(category(path), .developer, path)
            }
        }
    }

    func testXcodesOwnDerivedDataStaysAsBefore() {
        let base = "\(lib)/Developer/Xcode/DerivedData/Weatherly-\(xcodeHash)"
        XCTAssertEqual(key("\(base)/Build/Products/x"), "xcode-build|\(base)")
        XCTAssertEqual(name("\(base)/Build/Products/x").title, "Xcode build files · Weatherly")
        XCTAssertEqual(
            key("\(lib)/Developer/Xcode/DerivedData/ModuleCache.noindex/x"),
            "xcode-build|\(lib)/Developer/Xcode/DerivedData/ModuleCache.noindex"
        )
    }

    func testPlainBuildFoldersAreNotDerivedData() {
        XCTAssertEqual(key("\(home)/code/acme/build/out.o"), "build-output|\(home)/code/acme/build")
        XCTAssertEqual(key("\(home)/Documents/Notes/Build/a.txt"), "place|\(home)/Documents/Notes")
    }

    // MARK: - Categories

    func testSteamGamesAreApplications() {
        let path = "\(lib)/Application Support/Steam/steamapps/common/Celeste/Content/Music/a.ogg"
        XCTAssertEqual(category(path), .applications)
        XCTAssertEqual(name(path).category, .applications)
        XCTAssertEqual(name(path).owner, .named("Steam"))
    }

    func testHomebrewCacheIsAnAppCache() {
        let path = "\(lib)/Caches/Homebrew/downloads/x.tar.gz"
        XCTAssertEqual(category(path), .cachesAndSystem)
        XCTAssertEqual(GrowthCategory.subcategorize(path: path, home: home), .appCaches)
        XCTAssertEqual(category("/opt/homebrew/Cellar/x/1.0/bin/x"), .applications)
    }

    func testUserFoldersAreMediaAndHiddenFoldersAreDeveloper() {
        let media = [
            "\(home)/Music/Mixes/set.bin", "\(home)/Movies/raw/clip.braw", "\(home)/Desktop/notes.txt",
            "\(home)/Documents/Codex/2026-09-30/x.json", "\(home)/Archive/2024/x.bin", "\(home)/notes.txt"
        ]
        for path in media {
            XCTAssertEqual(category(path), .mediaAndDocuments, path)
            XCTAssertEqual(name(path).category, .mediaAndDocuments, path)
        }
        for path in ["\(home)/.codex/x", "\(home)/.local/share/uv/x", "\(home)/.zsh_history"] {
            XCTAssertEqual(category(path), .developer, path)
        }
        for path in ["\(home)/workspace/app/main.go", "\(home)/Developer/app/main.swift", "\(home)/dev/x/y.c"] {
            XCTAssertEqual(category(path), .developer, path)
        }
        XCTAssertEqual(category("/opt/stuff/x.bin"), .other)
        XCTAssertEqual(category("\(lib)/Fonts/x.ttf"), .cachesAndSystem)
        XCTAssertEqual(category("\(home)/Downloads/x.bin"), .downloads)
    }

    func testCategoryIsRenamedNotRecoded() {
        XCTAssertEqual(GrowthCategory.cachesAndSystem.displayName, "Apps & System")
        XCTAssertEqual(GrowthCategory.cachesAndSystem.rawValue, "cachesAndSystem")
        XCTAssertEqual(GrowthCategory.allCases.count, 8)
    }

    // MARK: - Place children follow the new units

    func testPlaceChildrenAreKeyedByTheNewUnitRoots() {
        var builder = DrilldownIndexBuilder()
        for path in [
            "\(lib)/Preferences/a.plist",
            "\(lib)/Preferences/ByHost/b.plist",
            "\(lib)/Application Support/Google/Chrome/Default/History"
        ] {
            builder.add(
                path: path, sizeBytes: 10, category: .cachesAndSystem, subcategory: nil,
                unitKey: UnitResolver.resolve(path: path, home: home)
            )
        }
        let children = Set(builder.placeChildren.keys)
        XCTAssertEqual(children, [
            PlaceChildKey(unitRoot: "\(lib)/Preferences", name: "a.plist", isFolder: false),
            PlaceChildKey(unitRoot: "\(lib)/Preferences", name: "ByHost", isFolder: true),
            PlaceChildKey(unitRoot: "\(lib)/Application Support/Google/Chrome", name: "Default", isFolder: true)
        ])
    }

    // MARK: - Migration

    func testOwnerUnitsMigrationReclassifiesClearsHistoryAndRebuildsTheIndex() throws {
        let directory = try createTrackedPathDirectory(named: "PrunrOwnerUnitsMigration")
        defer { try? FileManager.default.removeItem(at: directory) }
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("prunr.sqlite").path)
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(queue, upTo: DatabaseManager.drilldownIndexMigrationIdentifier)

        let trackedPathId = UUID().uuidString
        let rows: [(path: String, category: String, subcategory: String, size: Int64)] = [
            ("\(realHome)/Music/Mixes/set.bin", "other", "", 100),
            ("\(realHome)/.codex/packages/x", "other", "", 20),
            ("\(realHome)/Library/Application Support/Steam/steamapps/common/Celeste/a.ogg", "audioProduction", "audioFiles", 7),
            ("\(realHome)/Library/Caches/Homebrew/downloads/x.tar.gz", "applications", "homebrew", 3),
            ("\(realHome)/dev/acme/node_modules/x.js", "developer", "nodeModules", 50),
            ("/opt/stuff/x.bin", "other", "", 1)
        ]
        try queue.write { db in
            for (index, row) in rows.enumerated() {
                let pathId = index + 1
                try db.execute(sql: "INSERT INTO paths (id, path) VALUES (?, ?)", arguments: [pathId, row.path])
                try db.execute(
                    sql: "INSERT INTO pathClassification (pathId, category, subcategory) VALUES (?, ?, ?)",
                    arguments: [pathId, row.category, row.subcategory]
                )
                try db.execute(
                    sql: "INSERT INTO workingSetEntry (trackedPathId, pathId, sizeBytes, updatedAt) VALUES (?, ?, ?, ?)",
                    arguments: [trackedPathId, pathId, row.size, Date()]
                )
            }
            for (category, total) in [("other", 121), ("audioProduction", 7), ("applications", 3), ("developer", 50)] {
                try db.execute(
                    sql: """
                        INSERT INTO workingSetCategoryTotal (trackedPathId, category, totalBytes, updatedAt)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [trackedPathId, category, total, Date()]
                )
            }
            try db.execute(
                sql: "INSERT INTO workingSetIndexState (trackedPathId, state) VALUES (?, ?)",
                arguments: [trackedPathId, DatabaseManager.DrilldownIndexState.ready.rawValue]
            )
            try db.execute(
                sql: """
                    INSERT INTO growthJournalBucket (trackedPathId, bucketStart, category, subcategory, deltaBytes, unitKey)
                    VALUES (?, ?, 'other', '', 1000, 'place|/x')
                    """,
                arguments: [trackedPathId, Date()]
            )
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let categories = try Dictionary(uniqueKeysWithValues: Row.fetchAll(
                db, sql: "SELECT pathId, category FROM pathClassification"
            ).map { row -> (Int64, String) in (row["pathId"], row["category"]) })
            XCTAssertEqual(categories[1], "mediaAndDocuments")
            XCTAssertEqual(categories[2], "developer")
            XCTAssertEqual(categories[3], "applications")
            XCTAssertEqual(categories[4], "cachesAndSystem")
            XCTAssertEqual(categories[5], "developer")
            XCTAssertEqual(categories[6], "other")

            let totals = try Dictionary(uniqueKeysWithValues: Row.fetchAll(
                db, sql: "SELECT category, totalBytes FROM workingSetCategoryTotal WHERE trackedPathId = ?",
                arguments: [trackedPathId]
            ).map { row -> (String, Int64) in (row["category"], row["totalBytes"]) })
            XCTAssertEqual(totals, [
                "mediaAndDocuments": 100, "developer": 70, "applications": 7, "cachesAndSystem": 3, "other": 1
            ])

            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalBucket"), 0)
            XCTAssertEqual(
                try String.fetchOne(
                    db, sql: "SELECT state FROM workingSetIndexState WHERE trackedPathId = ?", arguments: [trackedPathId]
                ),
                DatabaseManager.DrilldownIndexState.building.rawValue
            )
        }
    }
}
