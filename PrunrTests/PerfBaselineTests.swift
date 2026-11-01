import XCTest
import GRDB
@testable import Prunr

/// Timings of the hot paths, printed as `PERF <name> <ms>` (best of several
/// runs; `median` lines next to it). Reported, not asserted, apart from a
/// sanity ceiling: read the numbers in the test log and compare them with
/// docs/perf-real-data-2026-10-31.md. The `real.*` lines need the real snapshot
/// (`PRUNR_REPLAY_DB`, else `~/dev/build/prunr-snap/slim.db`) and are skipped
/// without one.
final class PerfBaselineTests: PrunrTestCase {
    private let db = DatabaseManager.shared
    private static let bigPlace = "/Data/Big"
    private static let bigPlaceChildCount = 20_000

    // MARK: - Helpers

    private func emit(_ name: String, _ milliseconds: Double) {
        let line = String(format: "PERF %@ %.2f", name, milliseconds)
        print(line)
        NSLog("%@", line)
    }

    private func nowMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }

    @discardableResult
    private func time(_ name: String, runs: Int = 5, _ body: () async throws -> Void) async throws -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            let started = nowMs()
            try await body()
            samples.append(nowMs() - started)
        }
        samples.sort()
        emit(name, samples[0])
        emit(name + ".median", samples[samples.count / 2])
        return samples[0]
    }

    private func once(_ name: String, _ body: () async throws -> Void) async throws {
        let started = nowMs()
        try await body()
        emit(name, nowMs() - started)
    }

    private func trackedPath(_ id: UUID, home: String) -> TrackedPath {
        TrackedPath(id: id, url: URL(fileURLWithPath: home, isDirectory: true), displayName: "Home")
    }

    private func seedBigPlace(trackedPathId: UUID, now: Date) async throws {
        let entries = (0..<Self.bigPlaceChildCount).map {
            ScanResult(
                path: Self.bigPlace + "/f\($0).bin",
                sizeBytes: Int64(1_000 + ($0 * 7_919) % 1_000_003),
                category: .other,
                subcategory: nil
            )
        }
        _ = try await db.replaceWorkingSetSubtree(
            trackedPathId: trackedPathId,
            rootPath: Self.bigPlace,
            entries: entries,
            updatedAt: now
        )
    }

    private func seedDetail(trackedPathId: UUID, now: Date, days: Int) async throws {
        var buckets: [Date: [PlaceChildKey: Int64]] = [:]
        for slot in 0..<(days * 48) {
            let at = GrowthJournalService.bucketStart(for: now.addingTimeInterval(-TimeInterval(slot * 30 * 60)))
            var deltas: [PlaceChildKey: Int64] = [:]
            for child in 0..<GrowthJournalDetail.topChildren {
                deltas[PlaceChildKey(unitRoot: Self.bigPlace, name: "f\(child).bin", isFolder: false)] =
                    Int64((slot + child) % 7 + 1) * 1_000_000
            }
            buckets[at] = deltas
        }
        try await db.upsertJournalDetail(trackedPathId: trackedPathId, deltasByBucketStart: buckets, source: .watch)
    }

    // MARK: - Feed

    @MainActor
    func testPerfFeedRebuildOnFixture() async throws {
        try await withEmptyTemporaryDatabase { id in
            try await FixtureLibrary.seed(trackedPathId: id)
            let paths = [self.trackedPath(id, home: FixtureLibrary.home)]
            var rows = 0
            try await self.time("feed.fixture.changeFeed") {
                let feed = try await GrowthJournalService.shared.changeFeed(
                    trackedPaths: paths, now: FixtureLibrary.now, home: FixtureLibrary.home
                )
                rows = feed.episodes.count
            }
            XCTAssertGreaterThan(rows, 0)
        }
    }

    func testPerfFeedRebuildOn200kBuckets() async throws {
        let directory = try createTrackedPathDirectory(named: "PrunrPerfFeed")
        defer {
            try? DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: directory)
        }
        try DatabaseManager.shared.initialize(at: directory.appendingPathComponent("prunr.sqlite").path)
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)

        let ids = [UUID(), UUID()]
        let now = Date()
        let calendar = Calendar.current
        let since = EpisodeBuilder.windowStart(now: now, calendar: calendar)
        let unitCount = 2_000
        let bucketsPerUnit = 100
        let windowMinutes = max(1, Int(now.timeIntervalSince(since) / 60) - 1)
        try await dbPool.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO growthJournalBucket
                    (trackedPathId, bucketStart, category, subcategory, deltaBytes, source, unitKey)
                VALUES (?, ?, ?, '', ?, 'watch', ?)
                """)
            for unit in 0..<unitCount {
                let unitKey = "place|/Users/tester/projects/p\(unit)"
                let trackedPathId = ids[unit % ids.count].uuidString
                for index in 0..<bucketsPerUnit {
                    let minute = (unit * 7 + index * (windowMinutes / bucketsPerUnit)) % windowMinutes
                    let bucketStart = since.addingTimeInterval(TimeInterval(minute * 60))
                    let delta = Int64((index % 3 == 0 ? -1 : 1) * (10 + unit % 90 + index)) * 1_000_000
                    try statement.execute(arguments: [trackedPathId, bucketStart, "developer", delta, unitKey])
                }
            }
        }

        var input = ChangeFeedInput(slots: [], carries: [:])
        try await time("feed.200k.sqlSlots", runs: 3) {
            input = try await self.db.fetchChangeFeedInput(trackedPathIds: ids)
        }
        try await time("feed.200k.episodeBuild", runs: 3) {
            _ = EpisodeBuilder.build(slots: input.slots, now: now, calendar: calendar, carries: input.carries)
        }
        let paths = ids.map { self.trackedPath($0, home: "/Users/tester") }
        var rows = 0
        try await time("feed.200k.changeFeed", runs: 3) {
            rows = try await GrowthJournalService.shared.changeFeed(
                trackedPaths: paths, now: now, calendar: calendar, home: "/Users/tester"
            ).episodes.count
        }
        XCTAssertGreaterThan(rows, 0)
    }

    func testPerfFirstPruneAfterUpgrade() async throws {
        try await withEmptyTemporaryDatabase { id in
            let now = Date()
            let calendar = Calendar.current
            let cutoff = EpisodeBuilder.windowStart(now: now, calendar: calendar)
            let days = 59
            let places = 900
            let bucketsPerDay = 2
            let dbPool = try XCTUnwrap(self.db.dbPool)
            try await self.once("prune.first.seed60dx900places") {
                try await dbPool.write { db in
                    let statement = try db.makeStatement(sql: """
                        INSERT INTO growthJournalBucket
                            (trackedPathId, bucketStart, category, subcategory, deltaBytes, source, unitKey)
                        VALUES (?, ?, 'developer', '', ?, 'watch', ?)
                        """)
                    let firstDay = now.addingTimeInterval(-60 * 24 * 3_600)
                    for place in 0..<places {
                        let unitKey = "place|/Users/tester/projects/p\(place)"
                        for day in 0..<days {
                            for index in 0..<bucketsPerDay {
                                let seconds = day * 24 * 3_600 + (place % 40) * 1_800 + index * 6 * 3_600
                                let delta = Int64((index + day + place) % 5 + 1) * 40_000_000
                                try statement.execute(arguments: [
                                    id.uuidString,
                                    firstDay.addingTimeInterval(TimeInterval(seconds)),
                                    delta,
                                    unitKey
                                ])
                            }
                        }
                    }
                }
            }
            let paths = [self.trackedPath(id, home: "/Users/tester")]
            var rows = 0
            try await self.time("prune.first.changeFeedFullJournal", runs: 3) {
                rows = try await GrowthJournalService.shared.changeFeed(
                    trackedPaths: paths, now: now, calendar: calendar, home: "/Users/tester"
                ).episodes.count
            }
            XCTAssertGreaterThan(rows, 0)
            try await self.once("prune.first.pruneGrowthJournalBuckets") {
                try await self.db.pruneGrowthJournalBuckets(olderThan: cutoff, calendar: calendar)
            }
            let checkpoints = try await self.db.fetchJournalCheckpoints()
            self.emit("prune.first.checkpoints", Double(checkpoints.count))
            try await self.time("prune.first.changeFeedAfterPrune", runs: 3) {
                _ = try await GrowthJournalService.shared.changeFeed(
                    trackedPaths: paths, now: now, calendar: calendar, home: "/Users/tester"
                )
            }
        }
    }

    // MARK: - Place page

    func testPerfPlacePageQueries() async throws {
        try await withEmptyTemporaryDatabase { id in
            let now = Date()
            try await self.once("place.seed.workingSet20k") { try await self.seedBigPlace(trackedPathId: id, now: now) }
            try await self.once("place.seed.detail30d") { try await self.seedDetail(trackedPathId: id, now: now, days: 30) }
            try await self.db.optimizeQueryPlanner()

            var children = 0
            try await self.time("place.fetchPlaceContents.page1") {
                children = try await self.db.fetchPlaceContents(unitRoot: Self.bigPlace, trackedPathIds: [id]).children.count
            }
            XCTAssertEqual(children, 50)
            try await self.time("place.fetchPlaceContents.page2") {
                _ = try await self.db.fetchPlaceContents(unitRoot: Self.bigPlace, trackedPathIds: [id], offset: 50)
            }
            try await self.time("place.fetchPlaceContents.twoTrackedPaths") {
                _ = try await self.db.fetchPlaceContents(unitRoot: Self.bigPlace, trackedPathIds: [id, UUID()])
            }

            var listed = 0
            try await self.time("place.fetchPlaceChanges.1day") {
                let page = try await self.db.fetchPlaceChanges(
                    unitRoot: Self.bigPlace,
                    trackedPathIds: [id],
                    from: now.addingTimeInterval(-24 * 3_600),
                    to: now
                )
                listed = page.children?.count ?? 0
            }
            XCTAssertGreaterThan(listed, 0)
            try await self.time("place.fetchPlaceChanges.7days") {
                _ = try await self.db.fetchPlaceChanges(
                    unitRoot: Self.bigPlace,
                    trackedPathIds: [id],
                    from: now.addingTimeInterval(-7 * 24 * 3_600),
                    to: now
                )
            }
            try await self.time("place.fetchPlaceChanges.beforeDetail") {
                _ = try await self.db.fetchPlaceChanges(
                    unitRoot: Self.bigPlace,
                    trackedPathIds: [id],
                    from: now.addingTimeInterval(-60 * 24 * 3_600),
                    to: now
                )
            }
            try await self.time("place.fetchJournalDetailTotals.7days") {
                _ = try await self.db.fetchJournalDetailTotals(
                    trackedPathId: id,
                    from: now.addingTimeInterval(-7 * 24 * 3_600),
                    to: now
                )
            }
            try await self.time("place.pruneJournal.30d", runs: 1) {
                await GrowthJournalService.shared.prune(retentionDays: 30, now: now.addingTimeInterval(24 * 3_600))
            }
        }
    }

    // MARK: - Watcher

    func testPerfWatcherBurstWithDetail() async throws {
        try await withEmptyTemporaryDatabase { id in
            let now = Date()
            try await self.seedBigPlace(trackedPathId: id, now: now)
            try await self.db.optimizeQueryPlanner()

            let events = 200
            var round = 0
            let total = try await self.time("watcher.burst200.singleFileEvents", runs: 3) {
                round += 1
                for index in 0..<events {
                    _ = try await self.db.replaceWorkingSetFile(
                        trackedPathId: id,
                        entry: ScanResult(
                            path: Self.bigPlace + "/f\(index).bin",
                            sizeBytes: Int64(5_000_000 + round * 1_000 + index),
                            category: .other,
                            subcategory: nil
                        ),
                        updatedAt: now.addingTimeInterval(TimeInterval(round * 60 + index))
                    )
                }
            }
            self.emit("watcher.burst200.perEvent", total / Double(events))

            var batch = 0
            try await self.time("watcher.subtree1k", runs: 3) {
                batch += 1
                let entries = (0..<1_000).map {
                    ScanResult(
                        path: Self.bigPlace + "/Batch\(batch)/g\($0).bin",
                        sizeBytes: Int64($0 * 1_000 + 1),
                        category: .other,
                        subcategory: nil
                    )
                }
                _ = try await self.db.replaceWorkingSetSubtree(
                    trackedPathId: id, rootPath: Self.bigPlace + "/Batch\(batch)", entries: entries
                )
            }
        }
    }

    // MARK: - Scan persistence

    func testPerfScanPersistenceBatch() async throws {
        try await withEmptyTemporaryDatabase { id in
            let snapshot = try await self.db.createSnapshot(trackedPathId: id)
            let snapshotId = try XCTUnwrap(snapshot.id)
            let entries = (0..<10_000).map {
                ScanResult(
                    path: "/Data/Scan/dir\($0 % 200)/file\($0).bin",
                    sizeBytes: Int64(1_000 + $0),
                    category: .other,
                    subcategory: nil
                )
            }
            try await self.once("scan.addEntriesWithWorkingSet.10k") {
                try await self.db.addEntriesWithWorkingSet(
                    to: snapshotId, entries: entries, trackedPathId: id, updatedAt: Date()
                )
            }
            try await self.once("scan.addEntriesWithWorkingSet.10k.again") {
                try await self.db.addEntriesWithWorkingSet(
                    to: snapshotId, entries: entries, trackedPathId: id, updatedAt: Date()
                )
            }
            try await self.once("scan.rebuildDrilldownIndex.20k") {
                try await self.db.rebuildDrilldownIndex(trackedPathId: id)
            }
        }
    }

    // MARK: - Startup

    func testPerfStartupOnEmptyDatabase() throws {
        let directory = try createTrackedPathDirectory(named: "PrunrPerfStartup")
        defer {
            try? DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let started = nowMs()
        try DatabaseManager.shared.initialize(at: directory.appendingPathComponent("prunr.sqlite").path)
        emit("startup.initialize.emptyDatabase", nowMs() - started)
    }

    // MARK: - Real snapshot

    @MainActor
    func testPerfRealSnapshot() async throws {
        guard let source = ReplayHarnessTests.realSnapshotPath else {
            throw XCTSkip("no real snapshot (set PRUNR_REPLAY_DB)")
        }
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrunrPerfReal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        let copy = tempDirectory.appendingPathComponent("prunr.sqlite").path
        try FileManager.default.copyItem(atPath: source, toPath: copy)

        let ids = try ReplayHarness.trackedPathIds(inDatabaseAt: copy)
        let newest = try XCTUnwrap(ReplayHarness.newestBucketTime(inDatabaseAt: copy))
        let home = try XCTUnwrap(ReplayHarness.detectHome(inDatabaseAt: copy))
        let now = newest.addingTimeInterval(30 * 60)
        let paths = ids.map { trackedPath($0, home: home) }

        let started = nowMs()
        try DatabaseManager.shared.initialize(at: copy)
        emit("real.startup.initialize", nowMs() - started)
        try await once("real.startup.optimizeQueryPlanner") { try await self.db.optimizeQueryPlanner() }

        var feed: ChangeFeed?
        try await time("real.feed.changeFeed", runs: 5) {
            feed = try await GrowthJournalService.shared.changeFeed(trackedPaths: paths, now: now, home: home)
        }
        let roots = Array(Set((feed?.episodes ?? []).compactMap(\.rootPath)))
        emit("real.feed.rows", Double(feed?.episodes.count ?? 0))
        emit("real.feed.places", Double(roots.count))

        try await time("real.feed.sqlSlots", runs: 5) {
            _ = try await self.db.fetchChangeFeedInput(trackedPathIds: ids)
        }

        var slowestContents = 0.0
        var slowestChanges = 0.0
        try await once("real.places.contentsAllRows") {
            for root in roots {
                let began = self.nowMs()
                _ = try await self.db.fetchPlaceContents(unitRoot: root, trackedPathIds: ids)
                slowestContents = max(slowestContents, self.nowMs() - began)
            }
        }
        try await once("real.places.changesAllRows") {
            for root in roots {
                let began = self.nowMs()
                _ = try await self.db.fetchPlaceChanges(
                    unitRoot: root, trackedPathIds: ids, from: now.addingTimeInterval(-7 * 24 * 3_600), to: now
                )
                slowestChanges = max(slowestChanges, self.nowMs() - began)
            }
        }
        emit("real.places.contents.slowestRow", slowestContents)
        emit("real.places.changes.slowestRow", slowestChanges)

        let dbPool = try XCTUnwrap(db.dbPool)
        let biggest: (root: String, children: Int)? = try await dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT unitRoot, COUNT(*) AS children FROM workingSetPlaceChild
                GROUP BY unitRoot ORDER BY children DESC LIMIT 1
                """) else { return nil }
            let root: String = row["unitRoot"] ?? ""
            let children: Int = row["children"] ?? 0
            return (root: root, children: children)
        }
        if let biggest {
            let root = biggest.root
            let children = biggest.children
            emit("real.biggestPlace.children", Double(children))
            try await time("real.biggestPlace.fetchPlaceContents") {
                _ = try await self.db.fetchPlaceContents(unitRoot: root, trackedPathIds: ids)
            }
            try await time("real.biggestPlace.fetchPlaceChanges") {
                _ = try await self.db.fetchPlaceChanges(
                    unitRoot: root, trackedPathIds: ids, from: now.addingTimeInterval(-7 * 24 * 3_600), to: now
                )
            }
        }
    }
}
