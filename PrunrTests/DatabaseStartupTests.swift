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
}
