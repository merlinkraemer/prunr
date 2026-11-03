import XCTest
import GRDB
@testable import Prunr

final class ReplayHarnessTests: PrunrTestCase {
    static var outputRoot: URL {
        let path = ProcessInfo.processInfo.environment["PRUNR_SNAPSHOT_DIR"] ?? "/tmp/PrunrSnapshots"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var realHomeDirectory: String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }

    static var realSnapshotPath: String? {
        let candidates = [
            ProcessInfo.processInfo.environment["PRUNR_REPLAY_DB"],
            realHomeDirectory + "/dev/build/prunr-snap/slim.db"
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    @MainActor
    func testFixtureReplayRebuildsRowsAndDrilldowns() async throws {
        FixtureLibrary.useSyntheticHome()
        defer { FixtureLibrary.restoreProductionHome() }
        try await withEmptyTemporaryDatabase { trackedPathId in
            try await FixtureLibrary.seed(trackedPathId: trackedPathId)
            let result = try await ReplayHarness.run(
                source: "fixture",
                trackedPathIds: [trackedPathId],
                home: FixtureLibrary.home,
                now: FixtureLibrary.now,
                catalog: FixtureLibrary.catalog
            )
            try ReplayHarness.write(result, named: "fixture", to: Self.outputRoot.appendingPathComponent("replay"))

            let rows = result.report.rows
            XCTAssertGreaterThanOrEqual(rows.count, 6, ReplayHarness.text(result.report))

            let game = try XCTUnwrap(rows.first { $0.unitKey.hasSuffix("/dev/game") })
            XCTAssertEqual(game.netBytes, 32_000_000_000)
            XCTAssertEqual(game.drilldown.map(\.name), ["Assets", "Builds", "Library", "README.md"])
            XCTAssertEqual(game.drilldown.map(\.totalBytes), game.drilldown.map(\.totalBytes).sorted(by: >))

            let photos = try XCTUnwrap(rows.first { $0.unitKey.hasPrefix("photos-library|") })
            XCTAssertEqual(photos.netBytes, 13_000_000_000)
            XCTAssertFalse(photos.drilldown.isEmpty)
        }
    }

    @MainActor
    func testRealSnapshotReplayWhenAvailable() async throws {
        guard let source = Self.realSnapshotPath else {
            throw XCTSkip("no real snapshot (set PRUNR_REPLAY_DB)")
        }
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrunrReplay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        let copy = tempDirectory.appendingPathComponent("prunr.sqlite").path
        try ReplayHarness.copySlimSnapshotRestoringDroppedStagingTable(from: source, to: copy)

        let ids = try ReplayHarness.trackedPathIds(inDatabaseAt: copy)
        let newest = try XCTUnwrap(ReplayHarness.newestBucketTime(inDatabaseAt: copy))
        let home = try XCTUnwrap(ReplayHarness.detectHome(inDatabaseAt: copy))
        try DatabaseManager.shared.initialize(at: copy)

        let now = newest.addingTimeInterval(30 * 60)
        let result = try await ReplayHarness.run(source: "real-snapshot", trackedPathIds: ids, home: home, now: now)
        let output = Self.outputRoot.appendingPathComponent("real")
        try ReplayHarness.write(result, named: "replay", to: output)
        XCTAssertFalse(result.report.rows.isEmpty)

        let panels = try PanelSnapshot.writePanels(
            of: result,
            to: output,
            metrics: PanelSnapshotMetrics(home: home, now: now),
            groupLimit: 6
        )
        XCTAssertFalse(panels.isEmpty)
    }

    private static let survivingTables = ["snapshot", "snapshotEntry", "paths"]

    private static func nowMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }

    private static func emitPerf(_ name: String, _ milliseconds: Double) {
        let line = String(format: "PERF realdb.%@ %.2f", name, milliseconds)
        print(line)
        NSLog("%@", line)
    }

    private static func emitRealDB(_ name: String, _ value: Int) {
        let line = "REALDB \(name) \(value)"
        print(line)
        NSLog("%@", line)
    }

    private static func rowCounts(_ queue: DatabaseQueue) throws -> [String: Int] {
        try queue.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name
                """)
            var counts: [String: Int] = [:]
            for table in tables {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
            }
            return counts
        }
    }

    private static func appliedMigrationCount(_ queue: DatabaseQueue) throws -> Int {
        try queue.read { db in try DatabaseManager.makeMigrator().appliedIdentifiers(db).count }
    }

    private static func migrateStepByStep(at path: String) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            db.add(function: DatabaseManager.unitKeyFunction)
            db.add(function: DatabaseManager.ownerGroupFunction)
        }
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        let migrator = DatabaseManager.makeMigrator()
        let applied = try queue.read { db in try migrator.appliedIdentifiers(db) }
        for identifier in migrator.migrations where !applied.contains(identifier) {
            let started = nowMs()
            try migrator.migrate(queue, upTo: identifier)
            emitPerf("migrate.\(identifier)", nowMs() - started)
        }
        try queue.close()
    }

    @MainActor
    func testRealDatabaseCopyMigratesPrunesAndBuildsFeed() async throws {
        let source = Self.realHomeDirectory + "/Library/Application Support/Prunr/prunr.db"
        guard FileManager.default.isReadableFile(atPath: source) else {
            throw XCTSkip("no real Prunr database on this machine")
        }
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrunrRealDB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        let copy = tempDirectory.appendingPathComponent("prunr.sqlite").path

        var readOnly = Configuration()
        readOnly.readonly = true
        var started = Self.nowMs()
        do {
            let sourceQueue = try DatabaseQueue(path: source, configuration: readOnly)
            let copyQueue = try DatabaseQueue(path: copy)
            try sourceQueue.backup(to: copyQueue)
        }
        Self.emitPerf("copy", Self.nowMs() - started)

        let beforeQueue = try DatabaseQueue(path: copy)
        let before = try Self.rowCounts(beforeQueue)
        let versionBefore = try Self.appliedMigrationCount(beforeQueue)
        let ids = try await beforeQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT trackedPathId FROM snapshot WHERE trackedPathId != ''")
        }.compactMap(UUID.init(uuidString:))
        let home = try ReplayHarness.detectHome(inDatabaseAt: copy) ?? Self.realHomeDirectory
        try beforeQueue.close()
        Self.emitRealDB("schema.before", versionBefore)

        try Self.migrateStepByStep(at: copy)

        started = Self.nowMs()
        try DatabaseManager.shared.initialize(at: copy)
        Self.emitPerf("migrate", Self.nowMs() - started)

        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
        let versionAfter = try await dbPool.read { db in try DatabaseManager.makeMigrator().appliedIdentifiers(db).count }
        let total = DatabaseManager.makeMigrator().migrations.count
        Self.emitRealDB("schema.after", versionAfter)
        XCTAssertEqual(versionAfter, total)

        started = Self.nowMs()
        await GrowthJournalService.shared.prune(retentionDays: GrowthJournalService.historyWindowDays)
        Self.emitPerf("prune", Self.nowMs() - started)

        started = Self.nowMs()
        try await DatabaseManager.shared.checkpointWalTruncate()
        Self.emitPerf("checkpoint", Self.nowMs() - started)

        let now = Date()
        let paths = ids.map {
            TrackedPath(id: $0, url: URL(fileURLWithPath: home, isDirectory: true), displayName: "Home")
        }
        started = Self.nowMs()
        let feed = try await GrowthJournalService.shared.changeFeed(trackedPaths: paths, now: now, home: home)
        Self.emitPerf("feed", Self.nowMs() - started)
        Self.emitRealDB("feed.episodes", feed.episodes.count)

        started = Self.nowMs()
        let groups = try await DatabaseManager.shared.fetchDrilldownGroups(trackedPathIds: ids)
        Self.emitPerf("drilldownGroups", Self.nowMs() - started)
        Self.emitRealDB("drilldown.groups", groups.rows.count)

        let afterQueue = try DatabaseQueue(path: copy)
        let after = try Self.rowCounts(afterQueue)
        try afterQueue.close()
        for table in after.keys.sorted() {
            Self.emitRealDB("\(table).after", after[table] ?? 0)
        }
        for table in before.keys.sorted() {
            Self.emitRealDB("\(table).before", before[table] ?? 0)
        }
        for table in Self.survivingTables where (before[table] ?? 0) > 0 {
            XCTAssertGreaterThan(after[table] ?? 0, 0, "core table ended empty: \(table)")
        }
    }
}
