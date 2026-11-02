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

    func testGateReservesChunkBoundedByFreeCapacity() async throws {
        let gate = ScanBackpressureGate(maxOutstanding: 10)

        let first = await gate.waitToProduce(upTo: 256)
        XCTAssertEqual(first, 10)

        async let blocked = gate.waitToProduce(upTo: 256)
        try await Task.sleep(for: .milliseconds(40))
        await gate.release(4)
        let second = await blocked
        XCTAssertEqual(second, 4)

        async let closedWait = gate.waitToProduce(upTo: 5)
        try await Task.sleep(for: .milliseconds(20))
        await gate.close()
        let afterClose = await closedWait
        XCTAssertEqual(afterClose, 0)
    }

    func testProgressMarkIsBatchedByTimeOrEntryCount() {
        XCTAssertFalse(FileScanner.shouldMarkProgress(now: 10.1, lastMarkedAt: 10, entriesSinceMark: 5))
        XCTAssertTrue(FileScanner.shouldMarkProgress(now: 10.3, lastMarkedAt: 10, entriesSinceMark: 1))
        XCTAssertTrue(FileScanner.shouldMarkProgress(
            now: 10.01,
            lastMarkedAt: 10,
            entriesSinceMark: FileScanner.progressMarkEntryInterval
        ))
        XCTAssertLessThan(FileScanner.progressMarkInterval, FileScanner.defaultTraversalStallTimeout / 10)
    }

    func testChunkedReservationDeliversEveryFileUnderTightGate() async throws {
        let directory = try makeDirectory(fileCount: 700)
        defer { try? FileManager.default.removeItem(at: directory) }

        let gate = ScanBackpressureGate(maxOutstanding: 300)
        var scanned = 0
        var pendingRelease = 0

        for try await _ in makeScanner(consumerStallTimeout: 60)
            .scan(directory, ignoredNames: [], backpressure: gate) {
            scanned += 1
            pendingRelease += 1
            if pendingRelease == 100 {
                await gate.release(pendingRelease)
                pendingRelease = 0
            }
        }

        XCTAssertEqual(scanned, 700)
    }

    func testCancellationStopsChunkedProducerPromptly() async throws {
        let directory = try makeDirectory(fileCount: 700)
        defer { try? FileManager.default.removeItem(at: directory) }

        let gate = ScanBackpressureGate(maxOutstanding: 1_000)
        let token = ScanCancellationToken()
        var scanned = 0

        for try await _ in makeScanner(consumerStallTimeout: 60)
            .scan(directory, ignoredNames: [], cancellationToken: token, backpressure: gate) {
            scanned += 1
            if scanned == 10 { token.cancel() }
        }

        XCTAssertLessThan(scanned, 700)
    }
}

final class FileScannerHardLinkTests: XCTestCase {
    func testHardLinkedFileCountsBytesOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrunrHardLinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = directory.appendingPathComponent("original.bin")
        let link = directory.appendingPathComponent("link.bin")
        try Data(repeating: 7, count: 64 * 1024).write(to: original)
        try FileManager.default.linkItem(at: original, to: link)

        var fileStat = stat()
        XCTAssertEqual(lstat(original.path, &fileStat), 0)
        let singleLinkBytes = FileScanner.diskUsageBytes(for: fileStat)

        let scanner = FileScanner()
        var total: Int64 = 0
        var entries = 0
        for try await result in scanner.scan(directory, ignoredNames: []) {
            total += result.sizeBytes
            entries += 1
        }

        XCTAssertEqual(entries, 2)
        XCTAssertEqual(total, singleLinkBytes)
    }

    func testCountedBytesCountsOnlyFirstLinkAndAllSingleLinkFiles() {
        var multi = stat()
        multi.st_nlink = 2
        multi.st_dev = 1
        multi.st_ino = 10
        multi.st_blocks = 8
        var single = stat()
        single.st_nlink = 1
        single.st_dev = 1
        single.st_ino = 11
        single.st_blocks = 8

        var seen = Set<LinkedFileIdentity>()
        let first = FileScanner.countedBytes(for: multi, seenLinks: &seen)
        let second = FileScanner.countedBytes(for: multi, seenLinks: &seen)
        let singleFirst = FileScanner.countedBytes(for: single, seenLinks: &seen)
        let singleSecond = FileScanner.countedBytes(for: single, seenLinks: &seen)

        XCTAssertEqual(first, FileScanner.diskUsageBytes(for: multi))
        XCTAssertEqual(second, 0)
        XCTAssertEqual(singleFirst, singleSecond)
        XCTAssertEqual(seen.count, 1)
    }
}
