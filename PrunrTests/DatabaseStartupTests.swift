import XCTest
import GRDB
@testable import Prunr

final class DatabaseStartupTests: PrunrTestCase {
    func testTestHostSkipsAppStartupAndUsesIsolatedHome() {
        XCTAssertTrue(TestHost.isActive)
        XCTAssertNil(NSApp.delegate)
        XCTAssertNotEqual(NSHomeDirectory(), "/Users/\(NSUserName())")
    }

    func testCheckpointWalTruncateRunsOutsideTransaction() async throws {
        try await withTemporaryDatabase { _, _ in
            try await DatabaseManager.shared.checkpointWalTruncate()
        }
    }

    func testInitializeWaitsForWriteLockHeldByAnotherConnection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrunrTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let dbPath = directory.appendingPathComponent("prunr.sqlite").path
        try DatabaseManager.shared.initialize(at: dbPath)
        try DatabaseManager.shared.close()

        let other = try DatabaseQueue(path: dbPath)
        let lockHeld = expectation(description: "other connection holds the write lock")
        let released = expectation(description: "other connection released the write lock")
        DispatchQueue.global().async {
            try? other.inDatabase { db in
                try db.execute(sql: "BEGIN IMMEDIATE TRANSACTION")
                lockHeld.fulfill()
                Thread.sleep(forTimeInterval: 1)
                try db.execute(sql: "COMMIT")
            }
            released.fulfill()
        }
        wait(for: [lockHeld], timeout: 5)

        XCTAssertNoThrow(try DatabaseManager.shared.initialize(at: dbPath))
        wait(for: [released], timeout: 5)
    }

    func testWorkingSetSizesAreKeyedByTheRequestedSpelling() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let db = DatabaseManager.shared
            let snapshot = try await db.createSnapshot(trackedPathId: trackedPathId)
            try await db.addEntriesWithWorkingSet(
                to: try XCTUnwrap(snapshot.id),
                entries: [
                    ScanResult(path: "/x/foo/b", sizeBytes: 200),
                    ScanResult(path: "/x/Foo/", sizeBytes: 300),
                    ScanResult(path: "/x/Foo/a", sizeBytes: 100)
                ],
                trackedPathId: trackedPathId,
                updatedAt: snapshot.createdAt
            )

            let dbPool = try XCTUnwrap(db.dbPool)
            let storedDirs = try await dbPool.read { db in
                try String.fetchAll(db, sql: "SELECT path FROM dirs WHERE path LIKE '/x/_%' ORDER BY id")
            }
            XCTAssertEqual(storedDirs, ["/x/Foo/"])

            let sizes = try await db.fetchWorkingSetSizes(
                trackedPathId: trackedPathId,
                paths: ["/x/foo/a", "/x/FOO/b", "/x/foo"]
            )
            XCTAssertEqual(sizes["/x/foo/a"], 100)
            XCTAssertEqual(sizes["/x/FOO/b"], 200)
            XCTAssertEqual(sizes["/x/foo"], 300)
            XCTAssertEqual(sizes.count, 3)
        }
    }

    func testRootSubtreeReturnsTheRootRowOnce() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let db = DatabaseManager.shared
            let snapshot = try await db.createSnapshot(trackedPathId: trackedPathId)
            let snapshotId = try XCTUnwrap(snapshot.id)
            try await db.addEntriesWithWorkingSet(
                to: snapshotId,
                entries: [
                    ScanResult(path: "/", sizeBytes: 1),
                    ScanResult(path: "/a.txt", sizeBytes: 2),
                    ScanResult(path: "/b/c.txt", sizeBytes: 3)
                ],
                trackedPathId: trackedPathId,
                updatedAt: snapshot.createdAt
            )

            let dbPool = try XCTUnwrap(db.dbPool)
            let subtreePaths = try await dbPool.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT path FROM (\(DatabaseManager.subtreePathsSQL)) ORDER BY path",
                    arguments: DatabaseManager.subtreeArguments(root: "/")
                )
            }
            XCTAssertEqual(subtreePaths, ["/", "/a.txt", "/b/c.txt"])

            let workingSet = try await db.fetchWorkingSetEntries(
                trackedPathId: trackedPathId,
                atOrBelow: "/",
                afterPath: nil,
                limit: 10
            )
            XCTAssertEqual(workingSet.map(\.path), ["/", "/a.txt", "/b/c.txt"])

            let entries = try await db.fetchEntries(for: snapshotId, atOrBelow: "/", afterPath: nil, limit: 10)
            XCTAssertEqual(entries.map(\.path), ["/", "/a.txt", "/b/c.txt"])

            let nested = try await dbPool.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT path FROM (\(DatabaseManager.subtreePathsSQL)) ORDER BY path",
                    arguments: DatabaseManager.subtreeArguments(root: "/b")
                )
            }
            XCTAssertEqual(nested, ["/b/c.txt"])
        }
    }

    func testMigrationsAfterPathDirsKeepImmediateForeignKeyChecks() throws {
        let directory = try createTrackedPathDirectory(named: "PrunrMigrationForeignKeys")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("prunr.sqlite").path)
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(queue, upTo: DatabaseManager.pathDirsMigrationIdentifier)

        let later = Array(migrator.migrations.drop { $0 != DatabaseManager.pathDirsMigrationIdentifier }.dropFirst())
        XCTAssertFalse(later.isEmpty)
        let statements = MigrationStatementLog()
        queue.inDatabase { db in
            db.trace(options: .statement) { event in
                statements.append(event.description)
            }
        }
        for identifier in later {
            statements.clear()
            try migrator.migrate(queue, upTo: identifier)
            let disabling = statements.all().filter {
                $0.replacingOccurrences(of: " ", with: "").lowercased().contains("foreign_keys=off")
            }
            XCTAssertTrue(
                disabling.isEmpty,
                "\(identifier) runs with foreign keys off; register it with foreignKeyChecks: .immediate"
            )
        }
    }

    func testMigrationHeadroomIsOneAndAHalfDatabaseSizesCapped() {
        XCTAssertEqual(DatabaseManager.migrationHeadroomRequirement(databaseBytes: 1_000_000), 1_500_000)
        XCTAssertEqual(
            DatabaseManager.migrationHeadroomRequirement(databaseBytes: 3_470_000_000),
            5_205_000_000
        )
        XCTAssertEqual(
            DatabaseManager.migrationHeadroomRequirement(databaseBytes: 40_000_000_000),
            DatabaseManager.migrationHeadroomCapBytes
        )
    }
}

private final class MigrationStatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []

    func append(_ statement: String) {
        lock.lock()
        statements.append(statement)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        statements.removeAll()
        lock.unlock()
    }

    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return statements
    }
}
