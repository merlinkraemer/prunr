import GRDB
import XCTest
@testable import Prunr

final class DrilldownQueryPerformanceTests: PrunrTestCase {
    private static let legacyWorkingSetEntriesSQL = """
        SELECT wse.id, 0 AS snapshotId, p.path AS path, wse.sizeBytes
        FROM workingSetEntry wse
        JOIN pathClassification pc ON pc.pathId = wse.pathId
        JOIN paths p ON p.id = wse.pathId
        WHERE wse.trackedPathId = ? AND pc.category = ? AND pc.subcategory = ?
        ORDER BY wse.sizeBytes DESC, p.path ASC
        LIMIT ? OFFSET ?
        """

    private static let legacySnapshotEntriesSQL = """
        SELECT se.id, se.snapshotId, p.path AS path, se.sizeBytes
        FROM snapshotEntry se
        JOIN pathClassification pc ON pc.pathId = se.pathId
        JOIN paths p ON p.id = se.pathId
        WHERE se.snapshotId = ? AND pc.category = ? AND pc.subcategory = ?
        ORDER BY se.sizeBytes DESC, p.path ASC
        LIMIT ? OFFSET ?
        """

    private static let legacyWorkingSetCacheApplicationSQL = """
        SELECT wse.id, 0 AS snapshotId, p.path AS path, wse.sizeBytes
        FROM workingSetEntry wse
        JOIN pathClassification pc ON pc.pathId = wse.pathId
        JOIN paths p ON p.id = wse.pathId
        WHERE wse.trackedPathId = ?
            AND pc.category = ?
            AND pc.subcategory IN (?, ?, ?)
            AND p.path LIKE ? COLLATE NOCASE
        ORDER BY wse.sizeBytes DESC, p.path ASC
        LIMIT ? OFFSET ?
        """

    private static let legacySnapshotCacheApplicationSQL = """
        SELECT se.id, se.snapshotId, p.path AS path, se.sizeBytes
        FROM snapshotEntry se
        JOIN pathClassification pc ON pc.pathId = se.pathId
        JOIN paths p ON p.id = se.pathId
        WHERE se.snapshotId = ?
            AND pc.category = ?
            AND pc.subcategory IN (?, ?, ?)
            AND p.path LIKE ? COLLATE NOCASE
        ORDER BY se.sizeBytes DESC, p.path ASC
        LIMIT ? OFFSET ?
        """

    private static let fixtureClasses: [(category: GrowthCategory, subcategory: GrowthSubcategory?, weight: Int)] = [
        (.mediaAndDocuments, .photos, 50),
        (.mediaAndDocuments, .videos, 3),
        (.mediaAndDocuments, .documents, 7),
        (.cachesAndSystem, .appCaches, 20),
        (.cachesAndSystem, .browserCaches, 5),
        (.developer, .nodeModules, 400),
        (.other, nil, 515)
    ]

    private func seedFixture(count: Int, trackedPathId: UUID, snapshotId: Int64) throws {
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
        let totalWeight = Self.fixtureClasses.reduce(0) { $0 + $1.weight }
        let now = Date()

        try dbPool.write { db in
            let insertPath = try db.makeStatement(sql: "INSERT INTO paths (id, path) VALUES (?, ?)")
            let insertClassification = try db.makeStatement(sql: """
                INSERT INTO pathClassification (pathId, category, subcategory) VALUES (?, ?, ?)
                """)
            let insertWorkingSet = try db.makeStatement(sql: """
                INSERT INTO workingSetEntry (trackedPathId, pathId, sizeBytes, updatedAt) VALUES (?, ?, ?, ?)
                """)
            let insertSnapshotEntry = try db.makeStatement(sql: """
                INSERT INTO snapshotEntry (snapshotId, pathId, sizeBytes) VALUES (?, ?, ?)
                """)

            for index in 0..<count {
                let pathId = Int64(index + 1)
                var bucket = (index * 7_919) % totalWeight
                var fixtureClass = Self.fixtureClasses[0]
                for candidate in Self.fixtureClasses {
                    if bucket < candidate.weight {
                        fixtureClass = candidate
                        break
                    }
                    bucket -= candidate.weight
                }

                let path: String
                if fixtureClass.category == .cachesAndSystem {
                    let application = ["com.apple.Safari", "com.spotify.client", "org.mozilla.firefox"][index % 3]
                    path = "/Users/tester/Library/Caches/\(application)/blob-\(index)"
                } else {
                    path = "/Users/tester/Fixture/\(fixtureClass.category.rawValue)/file-\(index)"
                }
                let sizeBytes = Int64((index % 97) * 4_096)

                try insertPath.execute(arguments: [pathId, path])
                try insertClassification.execute(arguments: [
                    pathId,
                    fixtureClass.category.rawValue,
                    fixtureClass.subcategory?.rawValue ?? ""
                ])
                try insertWorkingSet.execute(arguments: [trackedPathId.uuidString, pathId, sizeBytes, now])
                try insertSnapshotEntry.execute(arguments: [snapshotId, pathId, sizeBytes])
            }
        }
    }

    private func legacyRows(_ sql: String, arguments: StatementArguments) async throws -> [String] {
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
        return try await dbPool.read { db in
            try SnapshotEntryWithPath.fetchAll(db, sql: sql, arguments: arguments).map(Self.rowKey)
        }
    }

    private static func rowKey(_ entry: SnapshotEntryWithPath) -> String {
        "\(entry.id ?? -1)|\(entry.snapshotId)|\(entry.path)|\(entry.sizeBytes)"
    }

    private func queryPlan(_ sql: String, arguments: StatementArguments) async throws -> [String] {
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
        return try await dbPool.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { row in
                row["detail"] ?? ""
            }
        }
    }

    private func hasPlannerStatistics(for table: String) async throws -> Bool {
        let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
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

    // MARK: - Results

    func testTopFileQueriesReturnTheSameRowsAsTheLegacyJoinOrder() async throws {
        try await withTemporaryDatabase { [self] trackedPathId, snapshotId in
            try self.seedFixture(count: 3_000, trackedPathId: trackedPathId, snapshotId: snapshotId)
            let db = DatabaseManager.shared

            for fixtureClass in Self.fixtureClasses {
                let category = fixtureClass.category
                let subcategory = fixtureClass.subcategory
                let subcategoryValue = subcategory?.rawValue ?? ""

                for (offset, limit) in [(0, 20), (20, 20), (0, 500)] {
                    let workingSet = try await db.fetchWorkingSetEntriesByClassification(
                        trackedPathId: trackedPathId,
                        category: category,
                        subcategory: subcategory,
                        offset: offset,
                        limit: limit
                    ).map(Self.rowKey)
                    let legacyWorkingSet = try await self.legacyRows(
                        Self.legacyWorkingSetEntriesSQL,
                        arguments: [trackedPathId.uuidString, category.rawValue, subcategoryValue, limit, offset]
                    )
                    if offset == 0 {
                        XCTAssertFalse(legacyWorkingSet.isEmpty, "\(category) \(subcategoryValue)")
                    }
                    XCTAssertEqual(workingSet, legacyWorkingSet, "\(category) \(subcategoryValue) offset \(offset)")

                    let snapshot = try await db.fetchSnapshotEntriesByClassification(
                        snapshotId: snapshotId,
                        category: category,
                        subcategory: subcategory,
                        offset: offset,
                        limit: limit
                    ).map(Self.rowKey)
                    let legacySnapshot = try await self.legacyRows(
                        Self.legacySnapshotEntriesSQL,
                        arguments: [snapshotId, category.rawValue, subcategoryValue, limit, offset]
                    )
                    if offset == 0 {
                        XCTAssertFalse(legacySnapshot.isEmpty, "\(category) \(subcategoryValue)")
                    }
                    XCTAssertEqual(snapshot, legacySnapshot, "\(category) \(subcategoryValue) offset \(offset)")
                }
            }

            for applicationKey in [nil, "com.apple.Safari", "com.spotify.client"] as [String?] {
                let pattern = applicationKey.map { "%/Library/Caches/\($0)/%" } ?? "%/Library/Caches/%"
                let category = GrowthCategory.cachesAndSystem.rawValue
                let appCaches = GrowthSubcategory.appCaches.rawValue
                let browserCaches = GrowthSubcategory.browserCaches.rawValue
                let spotifyCache = GrowthSubcategory.spotifyCache.rawValue

                let workingSet = try await db.fetchWorkingSetEntriesByCacheApplication(
                    trackedPathId: trackedPathId,
                    applicationKey: applicationKey,
                    offset: 5,
                    limit: 25
                ).map(Self.rowKey)
                let legacyWorkingSet = try await self.legacyRows(
                    Self.legacyWorkingSetCacheApplicationSQL,
                    arguments: [
                        trackedPathId.uuidString, category, appCaches, browserCaches, spotifyCache, pattern, 25, 5
                    ]
                )
                XCTAssertFalse(legacyWorkingSet.isEmpty)
                XCTAssertEqual(workingSet, legacyWorkingSet, "cache app \(applicationKey ?? "all")")

                let snapshot = try await db.fetchSnapshotEntriesByCacheApplication(
                    snapshotId: snapshotId,
                    applicationKey: applicationKey,
                    offset: 5,
                    limit: 25
                ).map(Self.rowKey)
                let legacySnapshot = try await self.legacyRows(
                    Self.legacySnapshotCacheApplicationSQL,
                    arguments: [snapshotId, category, appCaches, browserCaches, spotifyCache, pattern, 25, 5]
                )
                XCTAssertFalse(legacySnapshot.isEmpty)
                XCTAssertEqual(snapshot, legacySnapshot, "cache app \(applicationKey ?? "all")")
            }
        }
    }

    // MARK: - Plan

    func testTopFileQueryPlansStartFromThePathClassificationIndex() async throws {
        try await withTemporaryDatabase { [self] trackedPathId, snapshotId in
            try self.seedFixture(count: 2_000, trackedPathId: trackedPathId, snapshotId: snapshotId)
            let category = GrowthCategory.mediaAndDocuments.rawValue
            let subcategory = GrowthSubcategory.photos.rawValue

            let plans = [
                (
                    "working set",
                    try await self.queryPlan(
                        DatabaseManager.workingSetEntriesByClassificationSQL,
                        arguments: [trackedPathId.uuidString, category, subcategory, 20, 0]
                    )
                ),
                (
                    "snapshot",
                    try await self.queryPlan(
                        DatabaseManager.snapshotEntriesByClassificationSQL,
                        arguments: [snapshotId, category, subcategory, 20, 0]
                    )
                )
            ]

            for (name, plan) in plans {
                let outerLoop = try XCTUnwrap(plan.first, "\(name): empty plan")
                XCTAssertTrue(
                    outerLoop.contains("pc USING COVERING INDEX idx_pathClassification_category_subcategory_pathId"),
                    "\(name) plan must start from pathClassification: \(plan)"
                )
                XCTAssertFalse(
                    plan.contains { $0.hasPrefix("SCAN") },
                    "\(name) plan must not scan a table: \(plan)"
                )
                XCTAssertFalse(
                    plan.contains { $0.contains("(trackedPathId=?)") || $0.contains("(snapshotId=?)") },
                    "\(name) plan must not walk every entry of the tracked path: \(plan)"
                )
            }
        }
    }

    // MARK: - Planner statistics

    func testOptimizeQueryPlannerSeedsStatisticsForTheDrilldownTables() async throws {
        try await withTemporaryDatabase { [self] trackedPathId, snapshotId in
            try self.seedFixture(count: 500, trackedPathId: trackedPathId, snapshotId: snapshotId)
            let pathClassificationHadStatistics = try await self.hasPlannerStatistics(for: "pathClassification")
            XCTAssertFalse(pathClassificationHadStatistics)

            try await DatabaseManager.shared.optimizeQueryPlanner()

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

    // MARK: - Warmup

    func testInitialWarmupPicksOnlyTheLargestCategory() {
        let items = [
            CategoryInventoryItem(category: .downloads, currentSizeBytes: 300, recentGrowthStory: nil),
            CategoryInventoryItem(category: .mediaAndDocuments, currentSizeBytes: 9_000, recentGrowthStory: nil),
            CategoryInventoryItem(category: .developer, currentSizeBytes: 9_000, recentGrowthStory: nil),
            CategoryInventoryItem(category: .other, currentSizeBytes: 10, recentGrowthStory: nil)
        ]

        XCTAssertEqual(MenuBarManager.initialWarmupCategory(in: items), .mediaAndDocuments)
        XCTAssertNil(MenuBarManager.initialWarmupCategory(in: []))
    }

    // MARK: - Cost

    /// Legacy vs pathClassification-driven top-20 over a 200k-file working set.
    /// Reported, not asserted (look for "DRILLDOWN_TOP_FILES_MEASURE" in the test log).
    func testMeasureTopFileQueryOn200kWorkingSet() async throws {
        try await withTemporaryDatabase { [self] trackedPathId, snapshotId in
            try self.seedFixture(count: 200_000, trackedPathId: trackedPathId, snapshotId: snapshotId)
            let db = DatabaseManager.shared

            for subcategory in [GrowthSubcategory.photos, .videos] {
                let arguments: StatementArguments = [
                    trackedPathId.uuidString,
                    GrowthCategory.mediaAndDocuments.rawValue,
                    subcategory.rawValue,
                    20,
                    0
                ]

                let legacyStarted = Date()
                let legacy = try await self.legacyRows(Self.legacyWorkingSetEntriesSQL, arguments: arguments)
                let legacyMs = Date().timeIntervalSince(legacyStarted) * 1_000

                let currentStarted = Date()
                let current = try await db.fetchWorkingSetEntriesByClassification(
                    trackedPathId: trackedPathId,
                    category: .mediaAndDocuments,
                    subcategory: subcategory,
                    offset: 0,
                    limit: 20
                ).map(Self.rowKey)
                let currentMs = Date().timeIntervalSince(currentStarted) * 1_000

                XCTAssertEqual(current, legacy)
                print(String(
                    format: "DRILLDOWN_TOP_FILES_MEASURE subcategory=%@ rows=200000 legacy=%.1fms pcDriven=%.1fms",
                    subcategory.rawValue,
                    legacyMs,
                    currentMs
                ))
            }
        }
    }
}
