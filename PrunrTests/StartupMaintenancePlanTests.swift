import XCTest
@testable import Prunr

final class StartupMaintenancePlanTests: XCTestCase {
    private let mb: Int64 = 1024 * 1024
    private let now: TimeInterval = 1_800_000_000
    private let hour: TimeInterval = 60 * 60

    private func plan(
        versionChanged: Bool = false,
        walBytes: Int64 = 0,
        freelistBytes: Int64 = 0,
        lastCleanupAt: TimeInterval? = nil,
        lastCheckpointAt: TimeInterval? = nil
    ) -> DatabaseCleanupService.StartupMaintenancePlan {
        DatabaseCleanupService.startupMaintenancePlan(
            versionChanged: versionChanged,
            walBytes: walBytes,
            freelistBytes: freelistBytes,
            lastCleanupAt: lastCleanupAt ?? now - 60,
            lastCheckpointAt: lastCheckpointAt ?? now - 10,
            now: now
        )
    }

    func testLargeDatabaseWithoutFreePagesNeverReclaims() {
        let result = plan(
            versionChanged: true,
            walBytes: 3000 * mb,
            freelistBytes: 0,
            lastCleanupAt: 0,
            lastCheckpointAt: 0
        )
        XCTAssertFalse(result.reclaimFreePages)
        XCTAssertTrue(result.checkpoint)
        XCTAssertTrue(result.runCleanup)
    }

    func testVersionChangeCheckpointsOnly() {
        let result = plan(versionChanged: true)
        XCTAssertEqual(result, .init(runCleanup: true, checkpoint: true, reclaimFreePages: false))
    }

    func testQuietRecentLaunchDoesNothing() {
        XCTAssertEqual(plan(), .init(runCleanup: false, checkpoint: false, reclaimFreePages: false))
    }

    func testLargeWalTriggersCheckpoint() {
        let result = plan(walBytes: 64 * mb)
        XCTAssertTrue(result.checkpoint)
        XCTAssertTrue(result.runCleanup)
        XCTAssertFalse(result.reclaimFreePages)
    }

    func testDueCheckpointIntervalCheckpoints() {
        XCTAssertTrue(plan(lastCheckpointAt: now - 120).checkpoint)
    }

    func testDueCleanupIntervalRunsCleanup() {
        XCTAssertTrue(plan(lastCleanupAt: now - 13 * hour).runCleanup)
    }

    func testReclaimableFreelistReclaimsAndCheckpoints() {
        let result = plan(freelistBytes: 600 * mb)
        XCTAssertTrue(result.reclaimFreePages)
        XCTAssertTrue(result.checkpoint)
    }

    func testFreelistUnderThresholdIsLeftForReuse() {
        XCTAssertFalse(DatabaseCleanupService.freePagesWorthReclaiming(freelistBytes: 63 * mb))
        XCTAssertTrue(DatabaseCleanupService.freePagesWorthReclaiming(freelistBytes: 64 * mb))
    }

    func testIncrementalConversionNeedsTwiceTheDatabaseOnDisk() {
        XCTAssertTrue(
            DatabaseCleanupService.hasDiskForIncrementalConversion(databaseBytes: 3_500 * mb, availableBytes: 7_000 * mb)
        )
        XCTAssertFalse(
            DatabaseCleanupService.hasDiskForIncrementalConversion(databaseBytes: 3_500 * mb, availableBytes: 6_999 * mb)
        )
        XCTAssertFalse(
            DatabaseCleanupService.hasDiskForIncrementalConversion(databaseBytes: 3_500 * mb, availableBytes: nil)
        )
    }

    func testIncrementalVacuumStepsAreBoundedByBytes() {
        XCTAssertEqual(DatabaseCleanupService.incrementalVacuumPagesPerStep(pageSize: 4096), 16_384)
        XCTAssertEqual(DatabaseCleanupService.incrementalVacuumPagesPerStep(pageSize: 0), 1)
    }
}
