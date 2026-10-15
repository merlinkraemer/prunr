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
        freelistRatio: Double = 0,
        lastCleanupAt: TimeInterval? = nil,
        lastCheckpointAt: TimeInterval? = nil,
        lastVacuumAt: TimeInterval? = nil
    ) -> DatabaseCleanupService.StartupMaintenancePlan {
        DatabaseCleanupService.startupMaintenancePlan(
            versionChanged: versionChanged,
            walBytes: walBytes,
            freelistBytes: freelistBytes,
            freelistRatio: freelistRatio,
            lastCleanupAt: lastCleanupAt ?? now - 60,
            lastCheckpointAt: lastCheckpointAt ?? now - 10,
            lastVacuumAt: lastVacuumAt ?? now - 60,
            now: now
        )
    }

    func testLargeDatabaseWithoutFreePagesNeverVacuums() {
        let result = plan(
            versionChanged: true,
            walBytes: 3000 * mb,
            freelistBytes: 0,
            freelistRatio: 0,
            lastCleanupAt: 0,
            lastCheckpointAt: 0,
            lastVacuumAt: 0
        )
        XCTAssertFalse(result.vacuum)
        XCTAssertTrue(result.checkpoint)
        XCTAssertTrue(result.runCleanup)
    }

    func testVersionChangeCheckpointsOnly() {
        let result = plan(versionChanged: true)
        XCTAssertEqual(result, .init(runCleanup: true, checkpoint: true, vacuum: false))
    }

    func testQuietRecentLaunchDoesNothing() {
        XCTAssertEqual(plan(), .init(runCleanup: false, checkpoint: false, vacuum: false))
    }

    func testLargeWalTriggersCheckpoint() {
        let result = plan(walBytes: 64 * mb)
        XCTAssertTrue(result.checkpoint)
        XCTAssertTrue(result.runCleanup)
        XCTAssertFalse(result.vacuum)
    }

    func testDueCheckpointIntervalCheckpoints() {
        XCTAssertTrue(plan(lastCheckpointAt: now - 120).checkpoint)
    }

    func testDueCleanupIntervalRunsCleanup() {
        XCTAssertTrue(plan(lastCleanupAt: now - 13 * hour).runCleanup)
    }

    func testReclaimableFreelistVacuumsWhenIntervalPassed() {
        let result = plan(freelistBytes: 600 * mb, freelistRatio: 0.3, lastVacuumAt: now - 13 * hour)
        XCTAssertTrue(result.vacuum)
        XCTAssertTrue(result.checkpoint)
    }

    func testReclaimableFreelistWaitsForVacuumInterval() {
        let result = plan(freelistBytes: 600 * mb, freelistRatio: 0.3, lastVacuumAt: now - 1 * hour)
        XCTAssertFalse(result.vacuum)
    }

    func testLowRatioDoesNotVacuumEvenWithManyFreeBytes() {
        XCTAssertFalse(
            DatabaseCleanupService.vacuumWorthwhile(
                freelistBytes: 200 * mb,
                freelistRatio: 0.05,
                lastVacuumAt: 0,
                now: now
            )
        )
    }

    func testHighRatioOnTinyDatabaseDoesNotVacuum() {
        XCTAssertFalse(
            DatabaseCleanupService.vacuumWorthwhile(
                freelistBytes: 2 * mb,
                freelistRatio: 0.5,
                lastVacuumAt: 0,
                now: now
            )
        )
    }

    func testNeverVacuumedWithReclaimableSpaceVacuums() {
        XCTAssertTrue(
            DatabaseCleanupService.vacuumWorthwhile(
                freelistBytes: 200 * mb,
                freelistRatio: 0.2,
                lastVacuumAt: 0,
                now: now
            )
        )
    }
}
