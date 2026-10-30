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
}
