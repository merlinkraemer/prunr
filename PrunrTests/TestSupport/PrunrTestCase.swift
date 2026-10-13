import XCTest
import GRDB
import Darwin
@testable import Prunr

class PrunrTestCase: XCTestCase {
    func withEmptyTemporaryDatabase(
        _ body: @escaping (_ trackedPathId: UUID) async throws -> Void
    ) async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrunrTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let dbPath = tempDirectory.appendingPathComponent("prunr.sqlite").path
        try DatabaseManager.shared.initialize(at: dbPath)

        try await body(UUID())
    }

    func withTemporaryDatabase(
        _ body: @escaping (_ trackedPathId: UUID, _ snapshotId: Int64) async throws -> Void
    ) async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrunrTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let dbPath = tempDirectory.appendingPathComponent("prunr.sqlite").path
        try DatabaseManager.shared.initialize(at: dbPath)

        let trackedPathId = UUID()
        let snapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPathId)
        guard let snapshotId = snapshot.id else {
            XCTFail("snapshot id should be created")
            return
        }

        try await body(trackedPathId, snapshotId)
    }

    func createTrackedPathDirectory(named prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A category's drilldown groups with their stored top files, read the way
    /// the categories view reads them.
    @MainActor
    func drilldownGroups(_ category: GrowthCategory, trackedPathIds: [UUID]) async -> [SubcategoryGroup] {
        let store = DrilldownStore()
        await store.reload(trackedPathIds: trackedPathIds)
        await store.loadFiles(for: category, trackedPathIds: trackedPathIds)
        return store.groupsByCategory[category] ?? []
    }

    func assertDrilldownIndexExact(
        _ trackedPathId: UUID,
        _ context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let problems = try await DatabaseManager.shared.verifyDrilldownIndex(trackedPathId: trackedPathId)
        XCTAssertEqual(problems, [], context, file: file, line: line)
    }

    func diskUsageBytes(at url: URL) throws -> Int64 {
        var fileStat = stat()
        XCTAssertEqual(lstat(url.path, &fileStat), 0)
        return FileScanner.diskUsageBytes(for: fileStat)
    }
}
