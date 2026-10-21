import GRDB
import XCTest
@testable import Prunr

final class DrilldownIndexTests: PrunrTestCase {
    private static let root = "/Users/tester/Fixture"
    private var db: DatabaseManager { DatabaseManager.shared }

    private func file(
        _ relative: String,
        _ sizeBytes: Int64,
        _ category: GrowthCategory = .developer,
        _ subcategory: GrowthSubcategory? = .nodeModules
    ) -> ScanResult {
        ScanResult(path: Self.root + "/" + relative, sizeBytes: sizeBytes, category: category, subcategory: subcategory)
    }

    private func path(_ relative: String) -> String {
        Self.root + "/" + relative
    }

    private struct TopState {
        let sizes: [Int64]
        let paths: Set<String>
        let isShort: Bool
        let fileCount: Int
    }

    private func topState(_ trackedPathId: UUID, _ category: GrowthCategory, _ groupKey: String) async throws -> TopState {
        let dbPool = try XCTUnwrap(db.dbPool)
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT p.path AS path, t.sizeBytes AS sizeBytes
                    FROM workingSetTopEntry t JOIN paths p ON p.id = t.pathId
                    WHERE t.trackedPathId = ? AND t.category = ? AND t.groupKey = ?
                    ORDER BY t.sizeBytes DESC
                    """,
                arguments: [trackedPathId.uuidString, category.rawValue, groupKey]
            ).map { (path: $0["path"] as String? ?? "", sizeBytes: $0["sizeBytes"] as Int64? ?? 0) }
            let group = try Row.fetchOne(
                db,
                sql: """
                    SELECT topShort, fileCount FROM workingSetGroupTotal
                    WHERE trackedPathId = ? AND category = ? AND groupKey = ?
                    """,
                arguments: [trackedPathId.uuidString, category.rawValue, groupKey]
            )
            return TopState(
                sizes: rows.map(\.sizeBytes),
                paths: Set(rows.map(\.path)),
                isShort: group.flatMap { $0["topShort"] as Bool? } ?? false,
                fileCount: group.flatMap { $0["fileCount"] as Int? } ?? 0
            )
        }
    }

    // MARK: - Exact maintenance (verify after every delta kind)

    func testIndexStaysExactAfterEveryDeltaKind() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            _ = try await db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: Self.root, entries: [
                file("a/one.js", 100),
                file("a/two.js", 200),
                file("b/three.o", 300, .developer, .buildArtifacts)
            ])
            try await assertDrilldownIndexExact(id, "subtree add")

            _ = try await db.replaceWorkingSetFile(trackedPathId: id, entry: file("a/new.js", 50))
            try await assertDrilldownIndexExact(id, "new file")

            _ = try await db.replaceWorkingSetFile(trackedPathId: id, entry: file("a/new.js", 500))
            try await assertDrilldownIndexExact(id, "grow")

            _ = try await db.replaceWorkingSetFile(trackedPathId: id, entry: file("a/new.js", 5))
            try await assertDrilldownIndexExact(id, "shrink")

            _ = try await db.replaceWorkingSetFile(trackedPathId: id, entry: file("a/empty.js", 0))
            try await assertDrilldownIndexExact(id, "zero-byte file")
            let withEmpty = try await topState(id, .developer, GrowthSubcategory.nodeModules.rawValue)
            XCTAssertEqual(withEmpty.fileCount, 4, "zero-byte files count")

            _ = try await db.replaceWorkingSetFile(trackedPathId: id, entry: file("a/one.js", 100, .other, nil))
            try await assertDrilldownIndexExact(id, "reclassified category")

            _ = try await db.replaceWorkingSetFile(trackedPathId: id, entry: file("a/two.js", 200, .developer, .buildArtifacts))
            try await assertDrilldownIndexExact(id, "reclassified group")

            let cacheFile = "/Users/tester/Library/Caches/com.example.app/blob"
            _ = try await db.replaceWorkingSetFile(
                trackedPathId: id,
                entry: ScanResult(path: cacheFile, sizeBytes: 64, category: .cachesAndSystem, subcategory: .appCaches)
            )
            _ = try await db.replaceWorkingSetFile(
                trackedPathId: id,
                entry: ScanResult(path: cacheFile, sizeBytes: 96, category: .cachesAndSystem, subcategory: .browserCaches)
            )
            try await assertDrilldownIndexExact(id, "cache file between cache subcategories")
            let cacheGroup = try await topState(id, .cachesAndSystem, DrilldownGroupKey.ownerKey(path: cacheFile))
            XCTAssertEqual(cacheGroup.sizes, [96])

            _ = try await db.removeWorkingSetPathOrSubtree(trackedPathId: id, rootPath: path("a/new.js"))
            try await assertDrilldownIndexExact(id, "file removed")

            _ = try await db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: path("a"), entries: [
                file("a/one.js", 150, .other, nil),
                file("a/added.js", 70)
            ])
            try await assertDrilldownIndexExact(id, "subtree mixed add/change/remove")

            _ = try await db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: path("c"), entries: [
                file("c/dup.js", 10),
                file("c/dup.js", 20),
                file("c/DUP.js", 30)
            ])
            try await assertDrilldownIndexExact(id, "same path twice in one batch")

            _ = try await db.removeWorkingSetPathOrSubtree(trackedPathId: id, rootPath: path("a"))
            try await assertDrilldownIndexExact(id, "subtree removed")

            try await db.clearWorkingSetEntries(trackedPathId: id)
            try await assertDrilldownIndexExact(id, "cleared")
            let groups = try await db.fetchDrilldownGroups(trackedPathIds: [id])
            XCTAssertTrue(groups.rows.isEmpty)
        }
    }

    func testJournalDeltasKeepTheirUnitAndClassification() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            let deltas = try await db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: Self.root, entries: [
                file("a/one.js", 100),
                file("b/two.o", 300, .developer, .buildArtifacts)
            ])
            let unit = UnitResolver.resolve(path: path("a/one.js"))
            XCTAssertEqual(deltas[.init(category: .developer, subcategory: .nodeModules, unitKey: unit)], 100)
            XCTAssertEqual(deltas[.init(category: .developer, subcategory: .buildArtifacts, unitKey: unit)], 300)

            let moved = try await db.replaceWorkingSetFile(trackedPathId: id, entry: file("a/one.js", 100, .other, nil))
            XCTAssertEqual(moved[.init(category: .developer, subcategory: .nodeModules, unitKey: unit)], -100)
            XCTAssertEqual(moved[.init(category: .other, subcategory: nil, unitKey: unit)], 100)
        }
    }

    func testIndexStaysExactForSeveralTrackedPaths() async throws {
        try await withEmptyTemporaryDatabase { [self] first in
            let second = UUID()
            for id in [first, second] {
                _ = try await db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: Self.root, entries: [
                    file("a/one.js", 100),
                    file("a/two.js", 200)
                ])
            }
            _ = try await db.replaceWorkingSetFile(trackedPathId: second, entry: file("a/one.js", 1_000))
            _ = try await db.removeWorkingSetPathOrSubtree(trackedPathId: first, rootPath: path("a/two.js"))

            try await assertDrilldownIndexExact(first, "first path")
            try await assertDrilldownIndexExact(second, "second path")

            let merged = try await db.fetchDrilldownGroups(trackedPathIds: [first, second])
            let nodeModules = try XCTUnwrap(merged.rows.first { $0.groupKey == GrowthSubcategory.nodeModules.rawValue })
            XCTAssertEqual(nodeModules.totalBytes, 100 + 1_000 + 200)
            XCTAssertEqual(nodeModules.fileCount, 3)

            let files = try await db.fetchDrilldownTopFiles(trackedPathIds: [first, second], category: .developer)
            XCTAssertEqual(files.map(\.sizeBytes), [1_000, 200, 100])
        }
    }

    func testDeltasInterleavedWithWorkingSetRebuildsEndExact() async throws {
        try await withTemporaryDatabase { [self] id, snapshotId in
            try await db.addEntries(to: snapshotId, entries: [file("a/one.js", 100), file("a/two.js", 200)])
            try await db.rebuildWorkingSet(from: snapshotId, trackedPathId: id)
            try await assertDrilldownIndexExact(id, "rebuilt from snapshot")

            _ = try await db.replaceWorkingSetFile(trackedPathId: id, entry: file("a/three.js", 300))
            try await db.rebuildWorkingSet(from: snapshotId, trackedPathId: id)
            try await assertDrilldownIndexExact(id, "delta then rebuild")

            _ = try await db.replaceWorkingSetFile(trackedPathId: id, entry: file("a/one.js", 50))
            try await assertDrilldownIndexExact(id, "rebuild then delta")
        }
    }

    func testFullScanWritesTheIndexFromMemory() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            let root = try createTrackedPathDirectory(named: "PrunrDrilldownScan")
            defer { try? FileManager.default.removeItem(at: root) }
            for (relative, bytes) in [("a/photo.jpg", 8_192), ("a/b/clip.mov", 16_384), ("notes.txt", 4_096), ("empty.txt", 0)] {
                let url = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x5A, count: bytes).write(to: url)
            }

            _ = try await BaselineService.shared.createBaseline(trackedPath: TrackedPath(id: id, url: root, displayName: "Scan"))
            try await assertDrilldownIndexExact(id, "after a full scan")

            let groups = try await db.fetchDrilldownGroups(trackedPathIds: [id])
            XCTAssertFalse(groups.rows.isEmpty)
            XCTAssertTrue(groups.buildingTrackedPathIds.isEmpty)
        }
    }

    func testFullScanSkipsUnreadableFoldersAndCompletes() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            let root = try createTrackedPathDirectory(named: "PrunrUnreadableScan")
            let locked = root.appendingPathComponent("locked", isDirectory: true)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
                try? FileManager.default.removeItem(at: root)
            }
            let readable = root.appendingPathComponent("open/notes.txt")
            for (url, bytes) in [(readable, 8_192), (locked.appendingPathComponent("secret.mov"), 65_536)] {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x5A, count: bytes).write(to: url)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)

            let skipLog = ScanSkipLog()
            let snapshot = try await BaselineService.shared.createBaseline(
                trackedPath: TrackedPath(id: id, url: root, displayName: "Scan"),
                ignoredNames: [],
                skipLog: skipLog
            )

            XCTAssertEqual(snapshot.lifecycle, .complete)
            XCTAssertGreaterThan(skipLog.count, 0)
            XCTAssertEqual(skipLog.locationLabels, ["locked"])

            let totals = try await db.fetchWorkingSetCategoryTotals(for: id)
            let totalBytes = totals.reduce(Int64(0)) { $0 + $1.currentSizeBytes }
            XCTAssertEqual(totalBytes, try diskUsageBytes(at: readable))
            let entryCount = try await db.fetchEntryCount(for: try XCTUnwrap(snapshot.id))
            XCTAssertEqual(entryCount, 1)
            try await assertDrilldownIndexExact(id, "after skipping an unreadable folder")
        }
    }

    func testTopFilesStayACorrectPrefixAndRefill() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            let group = GrowthSubcategory.nodeModules.rawValue
            let entries = (1...250).map { file("big/f\($0).js", Int64($0) * 10) }
            _ = try await db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: path("big"), entries: entries)

            var state = try await topState(id, .developer, group)
            XCTAssertEqual(state.sizes.count, DrilldownIndexBuilder.topLimit)
            XCTAssertFalse(state.isShort)
            XCTAssertEqual(state.sizes.first, 2_500)
            XCTAssertEqual(state.sizes.last, 510)
            try await assertDrilldownIndexExact(id, "built")

            _ = try await db.removeWorkingSetPathOrSubtree(trackedPathId: id, rootPath: path("big/f250.js"))
            state = try await topState(id, .developer, group)
            XCTAssertEqual(state.sizes.count, 199)
            XCTAssertTrue(state.isShort)
            try await assertDrilldownIndexExact(id, "top-1 deleted")

            _ = try await db.removeWorkingSetPathOrSubtree(trackedPathId: id, rootPath: path("big/f249.js"))
            _ = try await db.replaceWorkingSetFile(trackedPathId: id, entry: file("big/g-big.js", 5_000))
            state = try await topState(id, .developer, group)
            XCTAssertTrue(state.paths.contains(path("big/g-big.js")), "bigger than the minimum is inserted while short")
            XCTAssertEqual(state.sizes.count, 199)
            XCTAssertTrue(state.isShort)

            _ = try await db.replaceWorkingSetFile(trackedPathId: id, entry: file("big/g-small.js", 5))
            state = try await topState(id, .developer, group)
            XCTAssertFalse(state.paths.contains(path("big/g-small.js")), "smaller than the minimum is not inserted while short")
            XCTAssertTrue(state.isShort)
            try await assertDrilldownIndexExact(id, "short prefix")

            let refilled = try await db.refillShortTopGroups(trackedPathId: id)
            XCTAssertEqual(refilled, 1)
            state = try await topState(id, .developer, group)
            XCTAssertEqual(state.sizes.count, DrilldownIndexBuilder.topLimit)
            XCTAssertFalse(state.isShort)
            try await assertDrilldownIndexExact(id, "refilled")
            let refilledAgain = try await db.refillShortTopGroups(trackedPathId: id)
            XCTAssertEqual(refilledAgain, 0)

            let minimumBefore = try XCTUnwrap(state.sizes.last)
            _ = try await db.replaceWorkingSetFile(trackedPathId: id, entry: file("big/g-huge.js", 99_999))
            state = try await topState(id, .developer, group)
            XCTAssertEqual(state.sizes.count, DrilldownIndexBuilder.topLimit, "trimmed at N + 1")
            XCTAssertEqual(state.sizes.first, 99_999)
            XCTAssertGreaterThan(try XCTUnwrap(state.sizes.last), minimumBefore)
            XCTAssertFalse(state.isShort)
            try await assertDrilldownIndexExact(id, "trimmed")
        }
    }

    @MainActor
    func testStorePagesPastTheStoredTopFiles() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            let entries = (1...260).map { file("big/f\(String(format: "%03d", $0)).js", Int64($0)) }
            _ = try await db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: path("big"), entries: entries)

            let store = DrilldownStore()
            await store.reload(trackedPathIds: [id])
            await store.loadFiles(for: .developer, trackedPathIds: [id])
            var group = try XCTUnwrap(store.groupsByCategory[.developer]?.first)
            XCTAssertEqual(group.topFiles.count, SubcategoryGroup.initialLoadLimit)

            while let next = await store.loadMoreFiles(for: group, category: .developer, trackedPathIds: [id]) {
                group = next
            }
            XCTAssertEqual(group.topFiles.count, 260)
            XCTAssertEqual(group.topFiles.map(\.currentSizeBytes), (1...260).reversed().map(Int64.init))
            XCTAssertFalse(group.hasMoreFiles)
        }
    }

    // MARK: - Place contents

    func testPlaceContentsListsDirectChildrenLargestFirst() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            let place = "/Data/Place"
            _ = try await db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: place, entries: [
                ScanResult(path: place + "/big.iso", sizeBytes: 500, category: .other, subcategory: nil),
                ScanResult(path: place + "/Photos/a.jpg", sizeBytes: 300, category: .mediaAndDocuments, subcategory: .photos),
                ScanResult(path: place + "/Photos/2026/b.jpg", sizeBytes: 400, category: .mediaAndDocuments, subcategory: .photos),
                ScanResult(path: place + "/Docs/x.txt", sizeBytes: 100, category: .mediaAndDocuments, subcategory: .documents)
            ])
            XCTAssertEqual(UnitKey(rawValue: UnitResolver.resolve(path: place + "/Docs/x.txt"))?.rootPath, place)

            let firstPage = try await db.fetchPlaceContents(unitRoot: place, trackedPathIds: [id], limit: 2)
            XCTAssertEqual(firstPage.children.map(\.name), ["Photos", "big.iso"])
            XCTAssertEqual(firstPage.children.map(\.path), [place + "/Photos", place + "/big.iso"])
            XCTAssertEqual(firstPage.children.map(\.isFolder), [true, false])
            XCTAssertEqual(firstPage.children.first?.totalBytes, 700)
            XCTAssertEqual(firstPage.children.first?.fileCount, 2)
            XCTAssertTrue(firstPage.hasMore)

            let secondPage = try await db.fetchPlaceContents(unitRoot: place, trackedPathIds: [id], offset: 2, limit: 2)
            XCTAssertEqual(secondPage.children.map(\.name), ["Docs"])
            XCTAssertFalse(secondPage.hasMore)

            _ = try await db.removeWorkingSetPathOrSubtree(trackedPathId: id, rootPath: place + "/Photos/2026/b.jpg")
            let afterDelete = try await db.fetchPlaceContents(unitRoot: place, trackedPathIds: [id])
            XCTAssertEqual(afterDelete.children.map(\.name), ["big.iso", "Photos", "Docs"])
            try await assertDrilldownIndexExact(id, "place children")

            let second = UUID()
            _ = try await db.replaceWorkingSetFile(
                trackedPathId: second,
                entry: ScanResult(path: place + "/Docs/y.txt", sizeBytes: 1_000, category: .mediaAndDocuments, subcategory: .documents)
            )
            let merged = try await db.fetchPlaceContents(unitRoot: place, trackedPathIds: [id, second])
            XCTAssertEqual(merged.children.first?.name, "Docs")
            XCTAssertEqual(merged.children.first?.totalBytes, 1_100)
        }
    }

    func testPlaceContentsOfAFileUnitIsTheFileItself() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            let download = UnitResolver.defaultHome + "/Downloads/ubuntu.iso"
            _ = try await db.replaceWorkingSetFile(
                trackedPathId: id,
                entry: ScanResult(path: download, sizeBytes: 4_000, category: .downloads, subcategory: nil)
            )
            let root = try XCTUnwrap(UnitKey(rawValue: UnitResolver.resolve(path: download))?.rootPath)
            let page = try await db.fetchPlaceContents(unitRoot: root, trackedPathIds: [id])
            XCTAssertEqual(page.children.map(\.path), [download])
            XCTAssertEqual(page.children.map(\.name), ["ubuntu.iso"])
            XCTAssertEqual(page.children.first?.isFolder, false)
        }
    }

    // MARK: - Upgrade

    func testUpgradeClearsHistoryAndBuildsTheIndexInTheBackground() async throws {
        let directory = try createTrackedPathDirectory(named: "PrunrDrilldownUpgrade")
        defer {
            try? DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: directory)
            HistoryStart.reset()
        }
        let dbPath = directory.appendingPathComponent("prunr.sqlite").path
        let trackedPathId = UUID()
        let rowCount = 100_000

        do {
            let queue = try DatabaseQueue(path: dbPath)
            try DatabaseManager.makeMigrator().migrate(queue, upTo: "v22_journal_unit")
            try await queue.write { db in
                try db.execute(
                    sql: "INSERT INTO snapshot (createdAt, trackedPathId, lifecycle) VALUES (?, ?, 'complete')",
                    arguments: [Date().addingTimeInterval(-86_400), trackedPathId.uuidString]
                )
                let snapshotId = db.lastInsertedRowID
                let insertPath = try db.makeStatement(sql: "INSERT INTO paths (id, path) VALUES (?, ?)")
                let insertClass = try db.makeStatement(sql: "INSERT INTO pathClassification (pathId, category, subcategory) VALUES (?, ?, ?)")
                let insertEntry = try db.makeStatement(sql: "INSERT INTO snapshotEntry (snapshotId, pathId, sizeBytes) VALUES (?, ?, ?)")
                let insertLive = try db.makeStatement(sql: """
                    INSERT INTO workingSetEntry (trackedPathId, pathId, sizeBytes, updatedAt) VALUES (?, ?, ?, ?)
                    """)
                var total: Int64 = 0
                for index in 1...rowCount {
                    let size = Int64(index % 977)
                    total += size
                    try insertPath.execute(arguments: [index, "/Users/tester/Fixture/d\(index % 300)/f\(index)"])
                    try insertClass.execute(arguments: [index, "developer", "nodeModules"])
                    try insertEntry.execute(arguments: [snapshotId, index, size])
                    try insertLive.execute(arguments: [trackedPathId.uuidString, index, size, Date()])
                }
                try db.execute(
                    sql: "INSERT INTO workingSetCategoryTotal (trackedPathId, category, totalBytes, updatedAt) VALUES (?, 'developer', ?, ?)",
                    arguments: [trackedPathId.uuidString, total, Date()]
                )
                try db.execute(
                    sql: """
                        INSERT INTO growthJournalBucket (trackedPathId, bucketStart, category, subcategory, deltaBytes, unitKey)
                        VALUES (?, ?, 'developer', '', 1000, '')
                        """,
                    arguments: [trackedPathId.uuidString, Date()]
                )
                try db.execute(
                    sql: """
                        INSERT INTO subcategorySnapshot (snapshotId, category, subcategory, totalBytes, fileCount, topItemsJSON)
                        VALUES (?, 'developer', 'nodeModules', 1, 1, '[]')
                        """,
                    arguments: [snapshotId]
                )
            }
            try queue.close()
        }

        HistoryStart.restart(at: Date(timeIntervalSince1970: 0))
        let started = Date()
        try DatabaseManager.shared.initialize(at: dbPath)
        let migrationMs = Date().timeIntervalSince(started) * 1_000
        print(String(format: "DRILLDOWN_INDEX_MEASURE upgrade rows=%d migration=%.1fms", rowCount, migrationMs))
        XCTAssertLessThan(migrationMs, 1_000, "the upgrade must not wait for the index build")

        XCTAssertGreaterThanOrEqual(try XCTUnwrap(HistoryStart.stored()), started.addingTimeInterval(-1))
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
        let (journalRows, hasSubcategorySnapshot) = try await dbPool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalBucket") ?? -1,
                try db.tableExists("subcategorySnapshot")
            )
        }
        XCTAssertEqual(journalRows, 0)
        XCTAssertFalse(hasSubcategorySnapshot)

        let before = try await DatabaseManager.shared.fetchDrilldownGroups(trackedPathIds: [trackedPathId])
        XCTAssertEqual(before.buildingTrackedPathIds, [trackedPathId])
        XCTAssertTrue(before.rows.isEmpty)

        let buildStarted = Date()
        let rebuilt = try await DatabaseManager.shared.rebuildDrilldownIndexIfNeeded()
        print(String(
            format: "DRILLDOWN_INDEX_MEASURE upgrade rows=%d indexBuild=%.1fms",
            rowCount,
            Date().timeIntervalSince(buildStarted) * 1_000
        ))
        XCTAssertEqual(rebuilt, [trackedPathId.uuidString])
        try await assertDrilldownIndexExact(trackedPathId, "after the upgrade build")

        let after = try await DatabaseManager.shared.fetchDrilldownGroups(trackedPathIds: [trackedPathId])
        XCTAssertTrue(after.buildingTrackedPathIds.isEmpty)
        XCTAssertEqual(after.rows.first?.fileCount, rowCount)
        let again = try await DatabaseManager.shared.rebuildDrilldownIndexIfNeeded()
        XCTAssertTrue(again.isEmpty)
    }

    func testHistoryStartRestartWinsOverOlderSnapshots() throws {
        let suite = "PrunrTests.HistoryRestart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldSnapshot = Date(timeIntervalSince1970: 1_000)
        let restart = Date(timeIntervalSince1970: 5_000)

        XCTAssertEqual(HistoryStart.remember(oldestSnapshot: oldSnapshot, defaults: defaults), oldSnapshot)
        HistoryStart.restart(at: restart, defaults: defaults)
        XCTAssertEqual(HistoryStart.remember(oldestSnapshot: oldSnapshot, defaults: defaults), restart)
    }

    // MARK: - Timing

    /// 1 M working-set rows. Reads are asserted against the design budget
    /// (best of several runs); the full rebuild is only reported. Look for
    /// "DRILLDOWN_INDEX_MEASURE" in the test log.
    func testIndexReadsStayWithinBudgetOnALargeWorkingSet() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            let rowCount = 1_000_000
            let dbPool = try XCTUnwrap(db.dbPool)
            let seeded = Date()
            try await dbPool.write { db in
                let insertPath = try db.makeStatement(sql: "INSERT INTO paths (id, path) VALUES (?, ?)")
                let insertClass = try db.makeStatement(sql: "INSERT INTO pathClassification (pathId, category, subcategory) VALUES (?, ?, ?)")
                let insertLive = try db.makeStatement(sql: """
                    INSERT INTO workingSetEntry (trackedPathId, pathId, sizeBytes, updatedAt) VALUES (?, ?, ?, ?)
                    """)
                let now = Date()
                for index in 1...rowCount {
                    let path: String
                    let category: GrowthCategory
                    let subcategory: GrowthSubcategory?
                    switch index % 10 {
                    case 0, 1, 2, 3:
                        path = "/Data/Flat/photo-\(index).jpg"
                        (category, subcategory) = (.mediaAndDocuments, .photos)
                    case 4, 5:
                        path = "/Data/Tree/d\(index % 5_000)/file-\(index)"
                        (category, subcategory) = (.developer, .nodeModules)
                    case 6:
                        path = "/Users/tester/Library/Caches/app\(index % 40)/blob-\(index)"
                        (category, subcategory) = (.cachesAndSystem, .appCaches)
                    case 7:
                        path = "/Users/tester/Movies/clip-\(index).mov"
                        (category, subcategory) = (.mediaAndDocuments, .videos)
                    default:
                        path = "/Users/tester/Misc/m\(index % 100)/f-\(index)"
                        (category, subcategory) = (.other, nil)
                    }
                    try insertPath.execute(arguments: [index, path])
                    try insertClass.execute(arguments: [index, category.rawValue, subcategory?.rawValue ?? ""])
                    try insertLive.execute(arguments: [id.uuidString, index, Int64((index * 7_919) % 1_000_003), now])
                }
                try db.execute(
                    sql: """
                        INSERT INTO workingSetCategoryTotal (trackedPathId, category, totalBytes, updatedAt)
                        SELECT ?, pc.category, SUM(wse.sizeBytes), ?
                        FROM workingSetEntry wse JOIN pathClassification pc ON pc.pathId = wse.pathId
                        WHERE wse.trackedPathId = ?
                        GROUP BY pc.category
                        """,
                    arguments: [id.uuidString, now, id.uuidString]
                )
            }
            let seedMs = Date().timeIntervalSince(seeded) * 1_000

            let rebuildStarted = Date()
            try await db.rebuildDrilldownIndex(trackedPathId: id)
            let rebuildMs = Date().timeIntervalSince(rebuildStarted) * 1_000
            try await db.optimizeQueryPlanner()
            // The seed leaves a huge WAL; without this every timed commit pays its auto-checkpoint.
            try await dbPool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }

            func bestOf(_ runs: Int, _ body: () async throws -> Void) async throws -> (best: Double, median: Double) {
                var samples: [Double] = []
                for _ in 0..<runs {
                    let started = DispatchTime.now().uptimeNanoseconds
                    try await body()
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                }
                samples.sort()
                return (samples[0], samples[samples.count / 2])
            }

            var groupCount = 0
            let groups = try await bestOf(7) {
                groupCount = try await self.db.fetchDrilldownGroups(trackedPathIds: [id]).rows.count
            }
            var fileCount = 0
            let files = try await bestOf(7) {
                fileCount = try await self.db.fetchDrilldownTopFiles(
                    trackedPathIds: [id],
                    category: .mediaAndDocuments,
                    groupKey: GrowthSubcategory.photos.rawValue
                ).count
            }
            let categoryFiles = try await bestOf(7) {
                _ = try await self.db.fetchDrilldownTopFiles(trackedPathIds: [id], category: .mediaAndDocuments)
            }
            var flatChildren = 0
            let flatPlace = try await bestOf(7) {
                flatChildren = try await self.db.fetchPlaceContents(unitRoot: "/Data/Flat", trackedPathIds: [id]).children.count
            }
            var treeChildren = 0
            let treePlace = try await bestOf(7) {
                treeChildren = try await self.db.fetchPlaceContents(unitRoot: "/Data/Tree", trackedPathIds: [id], offset: 50).children.count
            }
            var delta = 0
            let fileDelta = try await bestOf(7) {
                delta += 1
                _ = try await self.db.replaceWorkingSetFile(
                    trackedPathId: id,
                    entry: ScanResult(
                        path: "/Data/Flat/photo-\(delta * 10).jpg",
                        sizeBytes: Int64(2_000_000 + delta),
                        category: .mediaAndDocuments,
                        subcategory: .photos
                    )
                )
            }
            var batch = 0
            let subtreeDelta = try await bestOf(3) {
                batch += 1
                let entries = (0..<1_000).map {
                    ScanResult(
                        path: "/Data/Batch\(batch)/f\($0).jpg",
                        sizeBytes: Int64($0 * 1_000),
                        category: .mediaAndDocuments,
                        subcategory: .photos
                    )
                }
                _ = try await self.db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: "/Data/Batch\(batch)", entries: entries)
            }

            print(String(
                format: "DRILLDOWN_INDEX_MEASURE rows=%d seed=%.0fms rebuild=%.0fms groups=%d groupList=%.2f/%.2fms photoFiles=%d files=%.2f/%.2fms categoryFiles=%.2f/%.2fms",
                rowCount, seedMs, rebuildMs, groupCount, groups.best, groups.median, fileCount,
                files.best, files.median, categoryFiles.best, categoryFiles.median
            ))
            print(String(
                format: "DRILLDOWN_INDEX_MEASURE rows=%d placeFlat=%d %.2f/%.2fms placeTreePage2=%d %.2f/%.2fms fileDelta=%.2f/%.2fms subtreeDelta1k=%.1f/%.1fms (best/median)",
                rowCount, flatChildren, flatPlace.best, flatPlace.median, treeChildren, treePlace.best, treePlace.median,
                fileDelta.best, fileDelta.median, subtreeDelta.best, subtreeDelta.median
            ))

            XCTAssertEqual(fileCount, DrilldownIndexBuilder.topLimit)
            XCTAssertEqual(flatChildren, 50)
            XCTAssertEqual(treeChildren, 50)
            XCTAssertLessThan(groups.best, 5)
            XCTAssertLessThan(files.best, 10)
            XCTAssertLessThan(flatPlace.best, 50)
            XCTAssertLessThan(treePlace.best, 50)
            XCTAssertLessThan(fileDelta.best, 5)
            XCTAssertLessThan(subtreeDelta.best, 100)
            try await assertDrilldownIndexExact(id, "after the timed deltas")

            let indexedTreePage = try await db.fetchPlaceContents(unitRoot: "/Data/Tree", trackedPathIds: [id], offset: 50)
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE workingSetIndexState SET state = 'building' WHERE trackedPathId = ?",
                    arguments: [id.uuidString]
                )
            }
            var onDemandTreePage: PlaceContentsPage?
            let onDemandTree = try await bestOf(3) {
                onDemandTreePage = try await self.db.fetchPlaceContents(unitRoot: "/Data/Tree", trackedPathIds: [id], offset: 50)
            }
            let onDemandUsersTester = try await bestOf(3) {
                _ = try await self.db.fetchPlaceContents(unitRoot: "/Users/tester", trackedPathIds: [id])
            }
            var developerGroups = 0
            let onDemandDeveloper = try await bestOf(3) {
                developerGroups = try await self.db.fetchDrilldownCategoryFromWorkingSet(trackedPathIds: [id], category: .developer).rows.count
            }
            var cacheGroups = 0
            let onDemandCaches = try await bestOf(3) {
                cacheGroups = try await self.db.fetchDrilldownCategoryFromWorkingSet(trackedPathIds: [id], category: .cachesAndSystem).rows.count
            }
            print(String(
                format: "DRILLDOWN_INDEX_MEASURE onDemand placeTree200k=%.0f/%.0fms placeUsersTester=%.0f/%.0fms developer200k=%.0f/%.0fms caches100k groups=%d %.0f/%.0fms (best/median)",
                onDemandTree.best, onDemandTree.median, onDemandUsersTester.best, onDemandUsersTester.median,
                onDemandDeveloper.best, onDemandDeveloper.median, cacheGroups, onDemandCaches.best, onDemandCaches.median
            ))
            XCTAssertEqual(onDemandTreePage, indexedTreePage)
            XCTAssertEqual(developerGroups, 1)
        }
    }

    // MARK: - Planner statistics

    private func hasPlannerStatistics(for table: String) async throws -> Bool {
        let dbPool = try XCTUnwrap(db.dbPool)
        return try await dbPool.read { db in
            let statTableExists = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_stat1')
                """) ?? false
            guard statTableExists else { return false }
            return try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM sqlite_stat1 WHERE tbl = ?)",
                arguments: [table]
            ) ?? false
        }
    }

    func testOptimizeQueryPlannerSeedsStatisticsForTheDrilldownTables() async throws {
        try await withTemporaryDatabase { [self] trackedPathId, snapshotId in
            try await db.addEntries(to: snapshotId, entries: (0..<500).map { file("p/f\($0).js", Int64($0)) })
            try await db.rebuildWorkingSet(from: snapshotId, trackedPathId: trackedPathId)
            let pathClassificationHadStatistics = try await self.hasPlannerStatistics(for: "pathClassification")
            XCTAssertFalse(pathClassificationHadStatistics)

            try await db.optimizeQueryPlanner()

            for table in ["pathClassification", "workingSetEntry", "snapshotEntry"] {
                let hasStatistics = try await self.hasPlannerStatistics(for: table)
                XCTAssertTrue(hasStatistics, table)
            }
        }
    }

    @MainActor
    func testFullScanSchedulesQueryPlannerOptimization() async throws {
        try await withEmptyTemporaryDatabase { [self] _ in
            let root = try self.createTrackedPathDirectory(named: "PrunrPlannerStats")
            defer { try? FileManager.default.removeItem(at: root) }
            try Data(repeating: 0x5A, count: 8_192).write(to: root.appendingPathComponent("photo.jpg"))
            try Data(repeating: 0x5B, count: 4_096).write(to: root.appendingPathComponent("notes.txt"))

            let manager = MenuBarManager()
            XCTAssertNil(manager.queryPlannerOptimizationTask)

            let trackedPath = TrackedPath(url: root, displayName: "Planner")
            let succeeded = await manager.loadInventory(isAutomatic: true, trackedPathsOverride: [trackedPath])
            XCTAssertTrue(succeeded)

            let optimization = try XCTUnwrap(manager.queryPlannerOptimizationTask)
            await optimization.value

            let hasStatistics = try await self.hasPlannerStatistics(for: "pathClassification")
            XCTAssertTrue(hasStatistics)
        }
    }
}
