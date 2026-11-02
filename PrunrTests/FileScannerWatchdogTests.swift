import XCTest
@testable import Prunr

final class FileScannerWatchdogTests: XCTestCase {
    private func makeDirectory(fileCount: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrunrWatchdogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<fileCount {
            try Data("x".utf8).write(to: directory.appendingPathComponent("file\(index).txt"))
        }
        return directory
    }

    private var scannerKeptAliveForTheStream: FileScanner?

    private func makeScanner(consumerStallTimeout: TimeInterval) -> FileScanner {
        let scanner = FileScanner(
            traversalStallTimeout: 1,
            consumerStallTimeout: consumerStallTimeout,
            watchdogInterval: 0.2
        )
        scannerKeptAliveForTheStream = scanner
        return scanner
    }

    func testSlowConsumerLongerThanTraversalTimeoutDoesNotStallScan() async throws {
        let directory = try makeDirectory(fileCount: 3)
        defer { try? FileManager.default.removeItem(at: directory) }

        let gate = ScanBackpressureGate(maxOutstanding: 1)
        var scanned = 0

        for try await _ in makeScanner(consumerStallTimeout: 60)
            .scan(directory, ignoredNames: [], backpressure: gate) {
            scanned += 1
            try await Task.sleep(for: .seconds(2.5))
            await gate.release(1)
        }

        XCTAssertEqual(scanned, 3)
    }

    func testConsumerThatNeverReleasesStallsAfterConsumerTimeout() async throws {
        let directory = try makeDirectory(fileCount: 3)
        defer { try? FileManager.default.removeItem(at: directory) }

        let gate = ScanBackpressureGate(maxOutstanding: 1)

        do {
            for try await _ in makeScanner(consumerStallTimeout: 2)
                .scan(directory, ignoredNames: [], backpressure: gate) {}
            XCTFail("Expected the scan to stall")
        } catch ScanError.stalled {
        }
    }

    func testTraversalStallIsDetectedWhenNotWaitingOnConsumer() {
        let now: TimeInterval = 1_000
        let snapshot = ScanTraversalState.Snapshot(
            lastProgressAt: now - 31,
            currentPath: "/slow",
            isFinished: false,
            consumerWaitStartedAt: nil
        )

        XCTAssertNotNil(FileScanner.stalledDuration(snapshot, now: now, traversalStallTimeout: 30, consumerStallTimeout: 900))
    }

    func testConsumerWaitIsNotATraversalStallUntilConsumerTimeout() {
        let now: TimeInterval = 1_000
        let waiting = ScanTraversalState.Snapshot(
            lastProgressAt: now - 300,
            currentPath: "/busy",
            isFinished: false,
            consumerWaitStartedAt: now - 300
        )
        let waitingTooLong = ScanTraversalState.Snapshot(
            lastProgressAt: now - 901,
            currentPath: "/busy",
            isFinished: false,
            consumerWaitStartedAt: now - 901
        )

        XCTAssertNil(FileScanner.stalledDuration(waiting, now: now, traversalStallTimeout: 30, consumerStallTimeout: 900))
        XCTAssertNotNil(FileScanner.stalledDuration(waitingTooLong, now: now, traversalStallTimeout: 30, consumerStallTimeout: 900))
    }
}
