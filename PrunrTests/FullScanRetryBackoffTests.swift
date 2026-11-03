import XCTest
@testable import Prunr

@MainActor
final class FullScanRetryBackoffTests: PrunrTestCase {
    func testBackoffDoublesFromOneMinuteAndCapsAtSixHours() {
        let manager = MenuBarManager()

        XCTAssertEqual(manager.failedScanBackoff(for: 0), 0)
        XCTAssertEqual(manager.failedScanBackoff(for: 1), 60)
        XCTAssertEqual(manager.failedScanBackoff(for: 2), 120)
        XCTAssertEqual(manager.failedScanBackoff(for: 5), 960)
        XCTAssertEqual(manager.failedScanBackoff(for: 50), 6 * 60 * 60)
    }

    func testRepeatedScanFailuresKeepTheRetryGateClosed() async throws {
        try await withEmptyTemporaryDatabase { _ in
            let manager = MenuBarManager()
            manager.noBaseline = true
            let missingRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("PrunrMissing-\(UUID().uuidString)", isDirectory: true)
            let trackedPath = TrackedPath(url: missingRoot, displayName: "Missing")

            XCTAssertFalse(manager.isWithinFullRescanCooldown())

            for failure in 1...4 {
                let succeeded = await manager.loadInventory(trackedPathsOverride: [trackedPath])

                XCTAssertFalse(succeeded)
                XCTAssertEqual(manager.consecutiveFailedFullScans, failure)
                XCTAssertTrue(
                    manager.isWithinFullRescanCooldown(),
                    "a failed scan must not leave the gate open for an immediate retry"
                )
                XCTAssertFalse(
                    manager.isWithinFullRescanCooldown(
                        at: Date().addingTimeInterval(manager.failedScanBackoff(for: failure) + 1)
                    )
                )
            }
        }
    }

    func testMissingTrackedPathDoesNotBlockSnapshotsForAvailablePaths() async throws {
        try await withEmptyTemporaryDatabase { _ in
            let manager = MenuBarManager()
            manager.noBaseline = true
            let availableRoot = try self.createTrackedPathDirectory(named: "PrunrPartialScan")
            defer { try? FileManager.default.removeItem(at: availableRoot) }
            try Data(repeating: 0xAB, count: 64).write(to: availableRoot.appendingPathComponent("file.bin"))
            let missingRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("PrunrMissing-\(UUID().uuidString)", isDirectory: true)
            let availablePath = TrackedPath(url: availableRoot, displayName: "Available")
            let missingPath = TrackedPath(url: missingRoot, displayName: "Missing")

            let succeeded = await manager.loadInventory(trackedPathsOverride: [missingPath, availablePath])

            XCTAssertTrue(succeeded)
            XCTAssertEqual(manager.consecutiveFailedFullScans, 0)
            let availableSnapshots = try await DatabaseManager.shared.fetchRecentSnapshots(
                trackedPathId: availablePath.id,
                limit: 1
            )
            let missingSnapshots = try await DatabaseManager.shared.fetchRecentSnapshots(
                trackedPathId: missingPath.id,
                limit: 1
            )
            XCTAssertEqual(availableSnapshots.count, 1)
            XCTAssertTrue(missingSnapshots.isEmpty)
            XCTAssertTrue(manager.needsAuthoritativeReconciliation)
            XCTAssertTrue(manager.hasPendingRecentChanges)
        }
    }

    func testRetryAfterPartialScanTargetsOnlyTheFailedPath() async throws {
        try await withEmptyTemporaryDatabase { _ in
            let manager = MenuBarManager()
            manager.noBaseline = true
            let availableRoot = try self.createTrackedPathDirectory(named: "PrunrRetryAvailable")
            defer { try? FileManager.default.removeItem(at: availableRoot) }
            try Data(repeating: 0xAB, count: 64).write(to: availableRoot.appendingPathComponent("file.bin"))
            let missingRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("PrunrRetryMissing-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: missingRoot) }
            let availablePath = TrackedPath(url: availableRoot, displayName: "Available")
            let missingPath = TrackedPath(url: missingRoot, displayName: "Missing")
            let paths = [missingPath, availablePath]

            _ = await manager.loadInventory(trackedPathsOverride: paths)
            XCTAssertEqual(manager.failedScanRetryPathIDs, [missingPath.id])

            let stillFailing = await manager.retryFailedScanPaths([missingPath.id], in: paths)

            XCTAssertFalse(stillFailing)
            XCTAssertEqual(manager.failedScanRetryPathIDs, [missingPath.id])
            XCTAssertEqual(manager.consecutiveFailedFullScans, 0)
            let availableAfterFailedRetry = try await DatabaseManager.shared.fetchRecentSnapshots(
                trackedPathId: availablePath.id,
                limit: 5
            )
            XCTAssertEqual(availableAfterFailedRetry.count, 1)

            try FileManager.default.createDirectory(at: missingRoot, withIntermediateDirectories: true)
            try Data(repeating: 0xCD, count: 64).write(to: missingRoot.appendingPathComponent("late.bin"))

            let recovered = await manager.retryFailedScanPaths([missingPath.id], in: paths)

            XCTAssertTrue(recovered)
            XCTAssertNil(manager.failedScanRetryPathIDs)
            let availableAfterRecovery = try await DatabaseManager.shared.fetchRecentSnapshots(
                trackedPathId: availablePath.id,
                limit: 5
            )
            let missingAfterRecovery = try await DatabaseManager.shared.fetchRecentSnapshots(
                trackedPathId: missingPath.id,
                limit: 5
            )
            XCTAssertEqual(availableAfterRecovery.count, 1)
            XCTAssertEqual(missingAfterRecovery.count, 1)
        }
    }

    func testAllTrackedPathsMissingStillCountsAsFailedScan() async throws {
        try await withEmptyTemporaryDatabase { _ in
            let manager = MenuBarManager()
            manager.noBaseline = true
            let paths = (0..<2).map { index in
                TrackedPath(
                    url: FileManager.default.temporaryDirectory
                        .appendingPathComponent("PrunrMissing\(index)-\(UUID().uuidString)", isDirectory: true),
                    displayName: "Missing\(index)"
                )
            }

            let succeeded = await manager.loadInventory(trackedPathsOverride: paths)

            XCTAssertFalse(succeeded)
            XCTAssertEqual(manager.consecutiveFailedFullScans, 1)
        }
    }

    func testFullySuccessfulMultiPathScanLeavesNoPendingReconciliation() async throws {
        try await withEmptyTemporaryDatabase { _ in
            let manager = MenuBarManager()
            manager.noBaseline = true
            let roots = try (0..<2).map { index in
                try self.createTrackedPathDirectory(named: "PrunrBothOK\(index)")
            }
            defer { roots.forEach { try? FileManager.default.removeItem(at: $0) } }
            let paths = roots.enumerated().map { index, root in
                TrackedPath(url: root, displayName: "OK\(index)")
            }

            let succeeded = await manager.loadInventory(trackedPathsOverride: paths)

            XCTAssertTrue(succeeded)
            XCTAssertFalse(manager.needsAuthoritativeReconciliation)
            XCTAssertNil(manager.failedScanRetryPathIDs)
        }
    }
}
