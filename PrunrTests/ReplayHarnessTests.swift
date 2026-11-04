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

    private static let survivingTables = ["snapshot", "snapshotEntry", "paths", "workingSetEntry"]

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

    private static func emitSizeCounts(_ queue: DatabaseQueue) throws {
        let scalarQueries: [(String, String)] = [
            ("size.paths.orphan", """
                SELECT COUNT(*) FROM paths p
                WHERE NOT EXISTS (SELECT 1 FROM snapshotEntry se WHERE se.pathId = p.id)
                  AND NOT EXISTS (SELECT 1 FROM workingSetEntry w WHERE w.pathId = p.id)
                """),
            ("size.paths.onlySnapshotEntry", """
                SELECT COUNT(*) FROM paths p
                WHERE EXISTS (SELECT 1 FROM snapshotEntry se WHERE se.pathId = p.id)
                  AND NOT EXISTS (SELECT 1 FROM workingSetEntry w WHERE w.pathId = p.id)
                """),
            ("size.paths.onlyWorkingSet", """
                SELECT COUNT(*) FROM paths p
                WHERE NOT EXISTS (SELECT 1 FROM snapshotEntry se WHERE se.pathId = p.id)
                  AND EXISTS (SELECT 1 FROM workingSetEntry w WHERE w.pathId = p.id)
                """),
            ("size.paths.inBoth", """
                SELECT COUNT(*) FROM paths p
                WHERE EXISTS (SELECT 1 FROM snapshotEntry se WHERE se.pathId = p.id)
                  AND EXISTS (SELECT 1 FROM workingSetEntry w WHERE w.pathId = p.id)
                """),
            ("size.paths.sumPathBytes", "SELECT COALESCE(SUM(LENGTH(CAST(path AS BLOB))), 0) FROM pathText"),
            ("size.paths.maxPathBytes", "SELECT COALESCE(MAX(LENGTH(CAST(path AS BLOB))), 0) FROM pathText"),
            ("size.snapshotEntry.distinctPathIds", "SELECT COUNT(DISTINCT pathId) FROM snapshotEntry"),
            ("size.snapshotEntry.snapshotsWithEntries", "SELECT COUNT(DISTINCT snapshotId) FROM snapshotEntry"),
            ("size.snapshot.total", "SELECT COUNT(*) FROM snapshot"),
            ("size.snapshot.complete", "SELECT COUNT(*) FROM snapshot WHERE lifecycle = 'complete'"),
            ("size.snapshot.trackedPaths", "SELECT COUNT(DISTINCT trackedPathId) FROM snapshot"),
            ("size.snapshot.oldestAgeDays", """
                SELECT COALESCE(CAST(julianday('now') - julianday(MIN(createdAt)) AS INTEGER), 0) FROM snapshot
                """),
            ("size.snapshot.newestAgeHours", """
                SELECT COALESCE(CAST((julianday('now') - julianday(MAX(createdAt))) * 24 AS INTEGER), 0) FROM snapshot
                """),
            ("size.workingSetEntry.trackedPaths", "SELECT COUNT(DISTINCT trackedPathKey) FROM workingSetEntry"),
            ("size.workingSetTrackedPath.rows", "SELECT COUNT(*) FROM workingSetTrackedPath"),
            ("size.pathClassification.withoutPath", """
                SELECT COUNT(*) FROM pathClassification c WHERE NOT EXISTS (SELECT 1 FROM paths p WHERE p.id = c.pathId)
                """),
            ("size.pragma.pageCount", "PRAGMA page_count"),
            ("size.pragma.pageSize", "PRAGMA page_size"),
            ("size.pragma.freelistCount", "PRAGMA freelist_count"),
            ("size.pragma.autoVacuum", "PRAGMA auto_vacuum")
        ]
        for (name, sql) in scalarQueries {
            let value = try queue.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
            emitRealDB(name, value)
        }
        let entriesPerSnapshot = try queue.read { db in
            try Int.fetchAll(db, sql: """
                SELECT COUNT(*) FROM snapshotEntry GROUP BY snapshotId ORDER BY snapshotId DESC
                """)
        }
        for (rank, count) in entriesPerSnapshot.enumerated() {
            emitRealDB("size.snapshotEntry.rank\(rank)", count)
        }
        let objectBytes = try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name")
                .map { (name: $0["name"] as String? ?? "", bytes: $0["bytes"] as Int? ?? 0) }
        }
        for (name, bytes) in objectBytes ?? [] where bytes > 0 {
            emitRealDB("size.bytes.\(name)", bytes)
        }
    }

    private static func workingSetChecksum(_ queue: DatabaseQueue, trackedPathColumn: String) throws -> [String: Int] {
        try queue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS rows,
                       COALESCE(SUM(sizeBytes), 0) AS bytes,
                       COALESCE(SUM(pathId), 0) AS pathIdSum,
                       COUNT(DISTINCT \(trackedPathColumn)) AS trackedPaths
                FROM workingSetEntry
                """)
            var values: [String: Int] = [:]
            for name in ["rows", "bytes", "pathIdSum", "trackedPaths"] {
                values[name] = row?[name] ?? -1
            }
            return values
        }
    }

    private static func emitWorkingSetChecksum(_ stage: String, _ values: [String: Int]?) {
        guard let values else {
            emitRealDBError("wse.\(stage)", "unavailable")
            return
        }
        for name in values.keys.sorted() {
            emitRealDB("wse.\(name).\(stage)", values[name] ?? -1)
        }
    }

    private static func emitRealDBText(_ name: String, _ text: String) {
        let line = "REALDB \(name) \(text)"
        print(line)
        NSLog("%@", line)
    }

    private static func emitWorkingSetPlans(_ queue: DatabaseQueue, trackedPathId: String) {
        let key = DatabaseManager.workingSetKeySQL
        let subtree = DatabaseManager.subtreePathsSQL
        let subtreeArguments = DatabaseManager.subtreeArguments(root: "/a")
        let samplePaths = StatementArguments(DatabaseManager.pathValueArguments(["/a/x", "/b/y"]))
        let plans: [(String, String, StatementArguments)] = [
            ("fileState", """
                SELECT wse.sizeBytes, pc.category, pc.subcategory
                FROM workingSetEntry wse
                JOIN pathClassification pc ON pc.pathId = wse.pathId
                WHERE wse.trackedPathKey = \(key) AND wse.pathId = ?
                """, [trackedPathId, 1]),
            ("pathLookup", DatabaseManager.pathIdSQL, DatabaseManager.pathIdArguments("/a/b")),
            ("subtreeRows", """
                SELECT s.id, s.path, wse.sizeBytes, pc.category, pc.subcategory
                FROM (\(subtree)) s
                CROSS JOIN workingSetEntry wse ON wse.trackedPathKey = \(key) AND wse.pathId = s.id
                JOIN pathClassification pc ON pc.pathId = wse.pathId
                """, subtreeArguments + [trackedPathId]),
            ("subtreeDelete", """
                DELETE FROM workingSetEntry
                WHERE trackedPathKey = \(key)
                  AND pathId IN (SELECT id FROM (\(subtree)))
                """, [trackedPathId] + subtreeArguments),
            ("scanInsertDirs", "INSERT OR IGNORE INTO dirs (path) VALUES (?), (?)", ["/a/", "/b/"]),
            ("scanInsertPaths", """
                \(DatabaseManager.pathValuesSQL(count: 2))
                INSERT OR IGNORE INTO paths (dirId, name)
                SELECT d.id, input.name
                FROM input
                CROSS JOIN dirs d ON d.path = input.dir
                """, samplePaths),
            ("scanSelectIds", """
                \(DatabaseManager.pathValuesSQL(count: 2))
                SELECT p.id AS id, d.path || p.name AS path
                FROM input
                CROSS JOIN dirs d ON d.path = input.dir
                CROSS JOIN paths p ON p.dirId = d.id AND p.name = input.name
                """, samplePaths),
            ("stagingPaths", """
                SELECT p.id, MAX(s.sizeBytes)
                FROM workingSetRefreshStaging s
                CROSS JOIN dirs d ON d.path = s.dir
                CROSS JOIN paths p ON p.dirId = d.id AND p.name = s.name
                WHERE s.sessionId = ?
                GROUP BY p.id
                """, ["session"]),
            ("indexBuilder", """
                SELECT wse.pathId, p.path, wse.sizeBytes, pc.category, pc.subcategory
                FROM workingSetEntry wse
                JOIN pathClassification pc ON pc.pathId = wse.pathId
                JOIN pathText p ON p.id = wse.pathId
                WHERE wse.trackedPathKey = \(key)
                """, [trackedPathId]),
            ("groupFiles", """
                SELECT wse.pathId, p.path, wse.sizeBytes
                FROM pathClassification pc
                CROSS JOIN workingSetEntry wse ON wse.pathId = pc.pathId
                JOIN pathText p ON p.id = wse.pathId
                WHERE wse.trackedPathKey = \(key) AND pc.category = ? AND pc.subcategory = ?
                ORDER BY wse.sizeBytes DESC, p.path ASC
                LIMIT ? OFFSET ?
                """, [trackedPathId, "developer", "nodeModules", 50, 0]),
            ("placeChildren", """
                SELECT d.path || p.name AS path, wse.sizeBytes
                FROM dirs d
                CROSS JOIN paths p ON p.dirId = d.id
                CROSS JOIN workingSetEntry wse ON wse.trackedPathKey = \(key) AND wse.pathId = p.id
                WHERE d.path >= ? AND d.path < ?
                """, [trackedPathId, "/a/", "/a0"]),
            ("snapshotCopy", """
                SELECT pathId, sizeBytes FROM workingSetEntry WHERE trackedPathKey = \(key)
                """, [trackedPathId])
        ]
        for (name, sql, arguments) in plans {
            failSoft("plan.\(name)") {
                let details = try queue.read { db in
                    try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
                        .map { $0["detail"] as String? ?? "" }
                }
                for detail in details {
                    emitRealDBText("plan.\(name)", detail)
                }
                let scanned = details
                    .map { $0.split(separator: " ").prefix(2).map(String.init) }
                    .filter { $0.count == 2 && $0[0] == "SCAN" }
                    .map { $0[1] }
                let scansWorkingSet = scanned.contains { $0 == "wse" || $0 == "workingSetEntry" }
                let scansPathStore = scanned.contains { ["p", "d", "paths", "dirs"].contains($0) }
                emitRealDB("plan.\(name).scansWorkingSet", scansWorkingSet ? 1 : 0)
                emitRealDB("plan.\(name).scansPathStore", scansPathStore ? 1 : 0)
            }
        }
    }

    private struct PathChecksum: Equatable {
        let count: Int
        let hash: Int
    }

    private struct PathStoreCheck {
        let checksum: PathChecksum?
        let counts: [String: Int]?
    }

    private static func pathChecksum(_ queue: DatabaseQueue, source: String) throws -> PathChecksum {
        try queue.read { db in
            var hash: UInt64 = 14_695_981_039_346_656_037
            var count = 0
            let cursor = try Row.fetchCursor(db, sql: "SELECT id, path FROM \(source) ORDER BY id")
            while let row = try cursor.next() {
                let id: Int64 = row[0]
                let path: String = row[1]
                var bits = UInt64(bitPattern: id)
                for _ in 0..<8 {
                    hash = (hash ^ (bits & 0xff)) &* 1_099_511_628_211
                    bits >>= 8
                }
                for byte in path.utf8 {
                    hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
                }
                hash = (hash ^ 0x0a) &* 1_099_511_628_211
                count += 1
            }
            return PathChecksum(count: count, hash: Int(Int64(bitPattern: hash)))
        }
    }

    private static let pathStoreCountedTables = ["snapshotEntry", "workingSetEntry", "pathClassification", "workingSetTopEntry"]

    private static func pathStoreRowCounts(_ queue: DatabaseQueue) throws -> [String: Int] {
        try queue.read { db in
            var counts: [String: Int] = [:]
            for table in pathStoreCountedTables {
                guard try db.tableExists(table) else { continue }
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
            }
            return counts
        }
    }

    private static func emitPathStoreCheck(_ queue: DatabaseQueue, stage: String) -> PathStoreCheck {
        let source = stage == "before" ? "paths" : "pathText"
        var checksum: PathChecksum?
        var counts: [String: Int]?
        failSoft("paths.checksum.\(stage)") {
            let started = nowMs()
            let value = try pathChecksum(queue, source: source)
            emitPerf("pathsChecksum.\(stage)", nowMs() - started)
            emitRealDB("paths.checksum.count.\(stage)", value.count)
            emitRealDB("paths.checksum.hash.\(stage)", value.hash)
            checksum = value
        }
        failSoft("v31.counts.\(stage)") {
            let value = try pathStoreRowCounts(queue)
            for table in value.keys.sorted() {
                emitRealDB("v31.\(table).\(stage)", value[table] ?? -1)
            }
            counts = value
        }
        if stage == "before" {
            failSoft("paths.caseVariantDirs") {
                let variants = try queue.read { db in
                    try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM (
                            SELECT 1 FROM paths
                            GROUP BY prunr_path_dir(path) COLLATE NOCASE
                            HAVING COUNT(DISTINCT prunr_path_dir(path)) > 1
                        )
                        """) ?? 0
                }
                emitRealDB("paths.caseVariantDirs", variants)
            }
        }
        return PathStoreCheck(checksum: checksum, counts: counts)
    }

    private static func emitCheckpointDiagnostics(_ dbPool: DatabasePool, path: String) async {
        do {
            let pragmas = try await dbPool.read { db in
                try ["synchronous", "fullfsync", "checkpoint_fullfsync", "busy_timeout", "wal_autocheckpoint"].map {
                    ($0, try Int.fetchOne(db, sql: "PRAGMA \($0)") ?? -1)
                }
            }
            for (name, value) in pragmas {
                emitRealDB("o44.pragma.\(name)", value)
            }
        } catch {
            emitRealDBError("o44.pragma", "\(type(of: error))")
        }
        var started = nowMs()
        let fd = Darwin.open(path, O_RDWR)
        let syncResult = fd >= 0 ? fcntl(fd, F_FULLFSYNC) : -2
        if fd >= 0 { Darwin.close(fd) }
        emitPerf("o44.fullFsyncProbe", nowMs() - started)
        emitRealDB("o44.fullFsyncProbe.result", Int(syncResult))
        do {
            started = nowMs()
            let passive = try await dbPool.writeWithoutTransaction { db -> [Int] in
                let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(PASSIVE)")
                let busy: Int = row?[0] ?? -1
                let log: Int = row?[1] ?? -1
                let checkpointed: Int = row?[2] ?? -1
                return [busy, log, checkpointed]
            }
            emitPerf("o44.passiveCheckpoint", nowMs() - started)
            emitRealDB("o44.passiveCheckpoint.busy", passive[0])
            emitRealDB("o44.passiveCheckpoint.log", passive[1])
            emitRealDB("o44.passiveCheckpoint.checkpointed", passive[2])
        } catch {
            emitRealDBError("o44.passiveCheckpoint", "\(type(of: error))")
        }
    }

    private static func emitRealDBError(_ name: String, _ detail: String) {
        let line = "REALDB \(name).error \(detail)"
        print(line)
        NSLog("%@", line)
    }

    private static func failSoft(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            emitRealDBError(name, "\(type(of: error))")
        }
    }

    private static func emitMeasurements(_ queue: DatabaseQueue, home: String, tempDirectory: URL) async {
        failSoft("size.file.vacuumed") {
            let target = tempDirectory.appendingPathComponent("vacuumed.sqlite").path
            let started = nowMs()
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM INTO ?", arguments: [target])
            }
            emitPerf("vacuumInto", nowMs() - started)
            let bytes = (try FileManager.default.attributesOfItem(atPath: target)[.size] as? NSNumber)?.intValue ?? 0
            emitRealDB("size.file.vacuumed", bytes)
            try? FileManager.default.removeItem(atPath: target)
        }
        failSoft("size.bytes.workingSetEntryWithIndexes") {
            let bytes = try queue.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(d.pgsize), 0)
                    FROM dbstat d
                    JOIN sqlite_master m ON m.name = d.name
                    WHERE m.tbl_name = 'workingSetEntry'
                    """) ?? 0
            }
            emitRealDB("size.bytes.workingSetEntryWithIndexes", bytes)
        }
        failSoft("size.file.bytes") {
            let bytes = try queue.read { db in
                (try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0) * (try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0)
            }
            emitRealDB("size.file.bytes", bytes)
        }
        failSoft("size.bytes.pathStoreWithIndexes") {
            let bytes = try queue.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(d.pgsize), 0)
                    FROM dbstat d
                    JOIN sqlite_master m ON m.name = d.name
                    WHERE m.tbl_name IN ('paths', 'dirs')
                    """) ?? 0
            }
            emitRealDB("size.bytes.pathStoreWithIndexes", bytes)
        }
        failSoft("size.paths.distinctDirs") {
            let row = try queue.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT COUNT(*) AS dirs, COALESCE(SUM(LENGTH(CAST(path AS BLOB))), 0) AS dirBytes
                    FROM dirs
                    """)
            }
            emitRealDB("size.paths.distinctDirs", row?["dirs"] ?? 0)
            emitRealDB("size.paths.sumDirBytes", row?["dirBytes"] ?? 0)
        }
        failSoft("size.paths.sumNameBytes") {
            let row = try queue.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT COUNT(*) AS files,
                           COALESCE(SUM(LENGTH(CAST(name AS BLOB))), 0) AS nameBytes
                    FROM paths
                    """)
            }
            let files: Int = row?["files"] ?? 0
            let nameBytes: Int = row?["nameBytes"] ?? 0
            emitRealDB("size.paths.sumNameBytes", nameBytes)
            emitRealDB("size.paths.avgNameBytesX10", files > 0 ? nameBytes * 10 / files : 0)
        }
        failSoft("size.wse.histogram") {
            let rows = try queue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT CASE WHEN sizeBytes < 4096 THEN 'under4k'
                                WHEN sizeBytes < 65536 THEN 'under64k'
                                WHEN sizeBytes < 1048576 THEN 'under1m'
                                ELSE 'over1m' END AS bucket,
                           COUNT(*) AS files, COALESCE(SUM(sizeBytes), 0) AS bytes
                    FROM workingSetEntry GROUP BY bucket
                    """)
            }
            for row in rows {
                let bucket: String = row["bucket"] ?? "unknown"
                emitRealDB("size.wse.\(bucket).count", row["files"] ?? 0)
                emitRealDB("size.wse.\(bucket).bytes", row["bytes"] ?? 0)
            }
        }
        failSoft("size.subtree") {
            let sample = try queue.read { db in
                try String.fetchAll(db, sql: """
                    SELECT p.path FROM workingSetEntry w JOIN pathText p ON p.id = w.pathId
                    WHERE w.pathId % 997 = 0
                    """)
            }
            guard let folder = busiestFolder(in: sample, depth: 3) else {
                emitRealDBError("size.subtree", "no folder at depth 3 in \(sample.count) sampled paths")
                return
            }
            let started = nowMs()
            let count = try queue.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*)
                    FROM dirs d
                    CROSS JOIN paths p ON p.dirId = d.id
                    JOIN workingSetEntry w ON w.pathId = p.id
                    WHERE d.path >= ? AND d.path < ?
                    """, arguments: [folder + "/", folder + "0"]) ?? 0
            }
            emitPerf("subtree", nowMs() - started)
            emitRealDB("size.subtree.files", count)
        }
        failSoft("size.lookup") {
            let sample = try queue.read { db in
                try String.fetchAll(db, sql: "SELECT path FROM pathText WHERE id % 4400 = 0 LIMIT 1000")
            }
            let started = nowMs()
            let hits = try queue.read { db in
                var hits = 0
                for path in sample {
                    if try DatabaseManager.pathId(path, db: db) != nil {
                        hits += 1
                    }
                }
                return hits
            }
            emitPerf("lookup", nowMs() - started)
            emitRealDB("size.lookup.samples", sample.count)
            emitRealDB("size.lookup.hits", hits)
        }
        do {
            let pair = try await queue.read { db in
                try Int64.fetchAll(db, sql: """
                    SELECT snapshotId FROM snapshotEntry GROUP BY snapshotId ORDER BY snapshotId DESC LIMIT 2
                    """)
            }
            if pair.count == 2 {
                let started = nowMs()
                let deltas = try await DatabaseManager.shared.calculateDeltas(beforeId: pair[1], afterId: pair[0])
                emitPerf("deltas", nowMs() - started)
                emitRealDB("size.deltas.count", deltas.count)
            } else {
                emitRealDB("size.deltas.snapshotsWithEntries", pair.count)
            }
        } catch {
            emitRealDBError("size.deltas", "\(type(of: error))")
        }
    }

    static func busiestFolder(in paths: [String], depth: Int) -> String? {
        var counts: [String: Int] = [:]
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count > depth else { continue }
            counts["/" + components.prefix(depth).joined(separator: "/"), default: 0] += 1
        }
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    private static func fileBytes(_ path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func emitStorage(_ stage: String, path: String) async {
        do {
            let pool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let names = ["pages", "pageSize", "free", "autoVacuum", "entries", "payloads", "recordedCounts", "workingSet", "paths", "workingSetWithoutPath"]
            let values = try await pool.read { db -> [Int] in
                let row = try Row.fetchOne(db, sql: """
                    SELECT (SELECT page_count FROM pragma_page_count) AS pages,
                           (SELECT page_size FROM pragma_page_size) AS pageSize,
                           (SELECT freelist_count FROM pragma_freelist_count) AS free,
                           (SELECT auto_vacuum FROM pragma_auto_vacuum) AS autoVacuum,
                           (SELECT COUNT(*) FROM snapshotEntry) AS entries,
                           (SELECT COUNT(DISTINCT snapshotId) FROM snapshotEntry) AS payloads,
                           (SELECT COUNT(*) FROM snapshot WHERE entryCount IS NOT NULL) AS recordedCounts,
                           (SELECT COUNT(*) FROM workingSetEntry) AS workingSet,
                           (SELECT COUNT(*) FROM paths) AS paths,
                           (SELECT COUNT(*) FROM workingSetEntry w
                            WHERE NOT EXISTS (SELECT 1 FROM paths p WHERE p.id = w.pathId)) AS workingSetWithoutPath
                    """)
                return names.map { name -> Int in
                    let value: Int? = row?[name]
                    return value ?? -1
                }
            }
            let value = Dictionary(uniqueKeysWithValues: zip(names, values))
            let pageSize = value["pageSize"] ?? 0
            emitRealDB("o40.\(stage).file", fileBytes(path))
            emitRealDB("o40.\(stage).wal", fileBytes(path + "-wal"))
            emitRealDB("o40.\(stage).pagesBytes", (value["pages"] ?? 0) * pageSize)
            emitRealDB("o40.\(stage).freeBytes", (value["free"] ?? 0) * pageSize)
            emitRealDB("o40.\(stage).autoVacuum", value["autoVacuum"] ?? -1)
            emitRealDB("o40.\(stage).snapshotEntry", value["entries"] ?? -1)
            emitRealDB("o40.\(stage).payloads", value["payloads"] ?? -1)
            emitRealDB("o40.\(stage).recordedCounts", value["recordedCounts"] ?? -1)
            emitRealDB("o40.\(stage).workingSetEntry", value["workingSet"] ?? -1)
            emitRealDB("o40.\(stage).paths", value["paths"] ?? -1)
            emitRealDB("o40.\(stage).workingSetWithoutPath", value["workingSetWithoutPath"] ?? -1)
        } catch {
            emitRealDBError("o40.\(stage)", "\(type(of: error))")
        }
    }

    private static func conversionCode(_ outcome: DatabaseCleanupService.AutoVacuumConversion) -> Int {
        switch outcome {
        case .alreadyIncremental: return 0
        case .converted: return 1
        case .skippedLowDisk: return 2
        case .skippedBusy: return 3
        case .failed: return 4
        case .skippedBackoff: return 5
        }
    }

    private static func runStorageSlices(copy: String) async {
        await emitStorage("start", path: copy)

        var started = nowMs()
        let outcome = await DatabaseCleanupService.shared.convertToIncrementalAutoVacuumIfNeeded(busyCheck: { false })
        emitPerf("convertIncremental", nowMs() - started)
        emitRealDB("o40.convert.outcome", conversionCode(outcome))
        await emitStorage("converted", path: copy)

        started = nowMs()
        await DatabaseCleanupService.shared.performAutoCleanup()
        emitPerf("cleanupWithReclaim", nowMs() - started)
        await emitStorage("cleaned", path: copy)

        do {
            started = nowMs()
            let reclaimed = try await DatabaseCleanupService.shared.reclaimFreePages()
            emitPerf("reclaimAgain", nowMs() - started)
            emitRealDB("o40.reclaimAgain.bytes", Int(reclaimed))
        } catch {
            emitRealDBError("o40.reclaimAgain", "\(type(of: error))")
        }
        emitRealDB("o43.final.file", fileBytes(copy))
        emitRealDB("o44.final.file", fileBytes(copy))
    }

    private static func isolateTrackedPathIds(_ queue: DatabaseQueue) throws -> [String] {
        try queue.writeWithoutTransaction { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT m.name FROM sqlite_master m
                WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%'
                  AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) WHERE name = 'trackedPathId')
                """)
            let originals = try String.fetchAll(db, sql: "SELECT DISTINCT trackedPathId FROM snapshot WHERE trackedPathId != ''")
            var replacements: [String] = []
            for original in originals {
                let replacement = UUID().uuidString
                replacements.append(replacement)
                for table in tables {
                    try db.execute(
                        sql: "UPDATE \"\(table)\" SET trackedPathId = ? WHERE trackedPathId = ?",
                        arguments: [replacement, original]
                    )
                }
            }
            return replacements
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
            db.add(function: DatabaseManager.pathDirFunction)
        }
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        let migrator = DatabaseManager.makeMigrator()
        let applied = try queue.read { db in try migrator.appliedIdentifiers(db) }
        var pathStoreBefore: PathStoreCheck?
        for identifier in migrator.migrations where !applied.contains(identifier) {
            if identifier == DatabaseManager.pathDirsMigrationIdentifier {
                pathStoreBefore = emitPathStoreCheck(queue, stage: "before")
            }
            let started = nowMs()
            try migrator.migrate(queue, upTo: identifier)
            emitPerf("migrate.\(identifier)", nowMs() - started)
        }
        if let pathStoreBefore {
            let after = emitPathStoreCheck(queue, stage: "after")
            let checksumMatch = pathStoreBefore.checksum != nil && pathStoreBefore.checksum == after.checksum
            emitRealDB("paths.checksumMatch", checksumMatch ? 1 : 0)
            emitRealDB("v31.countsMatch", pathStoreBefore.counts != nil && pathStoreBefore.counts == after.counts ? 1 : 0)
        }
        emitRealDB("o44.wal.beforeMigrateClose", fileBytes(path + "-wal"))
        let closeStarted = nowMs()
        try queue.close()
        emitPerf("migrateClose", nowMs() - closeStarted)
        emitRealDB("o44.wal.afterMigrateClose", fileBytes(path + "-wal"))
    }

    func testBusiestFolderPicksTheMostCommonPrefixAtDepth() {
        let paths = [
            "/Users/x/Library/Caches/a",
            "/Users/x/Library/b",
            "/Users/x/dev/c",
            "/Users/x/file.txt"
        ]
        XCTAssertEqual(Self.busiestFolder(in: paths, depth: 3), "/Users/x/Library")
        XCTAssertNil(Self.busiestFolder(in: ["/Users/x/file.txt"], depth: 3))
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
        let ids = try Self.isolateTrackedPathIds(beforeQueue).compactMap(UUID.init(uuidString:))
        let workingSetBefore = try? Self.workingSetChecksum(beforeQueue, trackedPathColumn: "trackedPathId")
        let home = try ReplayHarness.detectHome(inDatabaseAt: copy) ?? Self.realHomeDirectory
        try beforeQueue.close()
        Self.emitRealDB("schema.before", versionBefore)

        try Self.migrateStepByStep(at: copy)

        let migratedQueue = try DatabaseQueue(path: copy)
        let workingSetAfter = try? Self.workingSetChecksum(migratedQueue, trackedPathColumn: "trackedPathKey")
        try migratedQueue.close()
        Self.emitWorkingSetChecksum("before", workingSetBefore)
        Self.emitWorkingSetChecksum("afterMigrate", workingSetAfter)
        Self.emitRealDB("wse.checksumMatch", workingSetBefore != nil && workingSetBefore == workingSetAfter ? 1 : 0)

        started = Self.nowMs()
        try DatabaseManager.shared.initialize(at: copy)
        Self.emitPerf("migrate", Self.nowMs() - started)
        Self.emitRealDB("o44.wal.afterInitialize", Self.fileBytes(copy + "-wal"))

        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
        let versionAfter = try await dbPool.read { db in try DatabaseManager.makeMigrator().appliedIdentifiers(db).count }
        let total = DatabaseManager.makeMigrator().migrations.count
        Self.emitRealDB("schema.after", versionAfter)
        XCTAssertEqual(versionAfter, total)

        started = Self.nowMs()
        try await dbPool.writeWithoutTransaction { _ in }
        Self.emitPerf("o44.writerWait", Self.nowMs() - started)

        started = Self.nowMs()
        await GrowthJournalService.shared.prune(retentionDays: GrowthJournalService.historyWindowDays)
        Self.emitPerf("prune", Self.nowMs() - started)

        started = Self.nowMs()
        await GrowthJournalService.shared.prune(retentionDays: GrowthJournalService.historyWindowDays)
        Self.emitPerf("o44.pruneAgain", Self.nowMs() - started)

        Self.emitRealDB("o44.wal.beforeCheckpoint", Self.fileBytes(copy + "-wal"))
        await Self.emitCheckpointDiagnostics(dbPool, path: copy)

        started = Self.nowMs()
        let checkpointDone = try await DatabaseManager.shared.checkpointWalTruncate()
        Self.emitPerf("checkpoint", Self.nowMs() - started)
        Self.emitRealDB("o44.checkpoint.done", checkpointDone ? 1 : 0)

        started = Self.nowMs()
        _ = try await DatabaseManager.shared.checkpointWalTruncate()
        Self.emitPerf("o44.checkpointAgain", Self.nowMs() - started)

        await Self.runStorageSlices(copy: copy)

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
        try Self.emitSizeCounts(afterQueue)
        await Self.emitMeasurements(afterQueue, home: home, tempDirectory: tempDirectory)
        if let trackedPathId = ids.first?.uuidString {
            Self.emitWorkingSetPlans(afterQueue, trackedPathId: trackedPathId)
        }
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
