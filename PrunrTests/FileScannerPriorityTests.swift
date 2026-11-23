import XCTest
@testable import Prunr

final class FileScannerPriorityTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrunrPriorityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appendingPathComponent("file.txt"))
        return directory
    }

    private func drain(_ stream: AsyncThrowingStream<ScanResult, Error>) async throws {
        for try await _ in stream {}
    }

    func testBackgroundPriorityRunsProducerAtBackground() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scanner = FileScanner()
        try await drain(scanner.scan(directory, ignoredNames: [], priority: .background))

        XCTAssertEqual(scanner.lastProducerPriority, .background)
    }

    func testDefaultPriorityInheritsCallerPriority() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scanner = FileScanner()
        let callerPriority = try await Task(priority: .userInitiated) {
            try await self.drain(scanner.scan(directory, ignoredNames: []))
            return Task.currentPriority
        }.value

        XCTAssertEqual(scanner.lastProducerPriority, callerPriority)
        XCTAssertNotEqual(scanner.lastProducerPriority, .background)
    }
}
