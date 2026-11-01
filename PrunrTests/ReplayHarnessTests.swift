import XCTest
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
}
