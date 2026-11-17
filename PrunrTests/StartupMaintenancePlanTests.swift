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

    func testRewriteDiskRequirementUsesLivePagesTwiceAndTheWal() {
        let required = DatabaseCleanupService.rewriteDiskRequirement(
            pageCount: 1_000,
            freelistCount: 400,
            pageSize: 4_096,
            walBytes: 50 * mb
        )
        XCTAssertEqual(required, 600 * 4_096 * 2 + 50 * mb)
    }

    func testRewriteDiskCheckComparesAgainstAvailableSpace() {
        XCTAssertTrue(DatabaseCleanupService.hasDiskForRewrite(requiredBytes: 7_000 * mb, availableBytes: 7_000 * mb))
        XCTAssertFalse(DatabaseCleanupService.hasDiskForRewrite(requiredBytes: 7_000 * mb, availableBytes: 6_999 * mb))
        XCTAssertFalse(DatabaseCleanupService.hasDiskForRewrite(requiredBytes: 1, availableBytes: nil))
    }

    func testConversionBackoffIsOneDayThenSevenDays() {
        let day: TimeInterval = 24 * hour
        XCTAssertFalse(DatabaseCleanupService.conversionBackoffActive(failedAt: 0, failureCount: 0, now: now))
        XCTAssertTrue(DatabaseCleanupService.conversionBackoffActive(failedAt: now - day + 1, failureCount: 1, now: now))
        XCTAssertFalse(DatabaseCleanupService.conversionBackoffActive(failedAt: now - day, failureCount: 1, now: now))
        XCTAssertTrue(DatabaseCleanupService.conversionBackoffActive(failedAt: now - 6 * day, failureCount: 2, now: now))
        XCTAssertFalse(DatabaseCleanupService.conversionBackoffActive(failedAt: now - 7 * day, failureCount: 2, now: now))
        XCTAssertTrue(DatabaseCleanupService.conversionBackoffActive(failedAt: now - 6 * day, failureCount: 5, now: now))
    }

    func testReclaimKeepsOneThirdOfLiveSizeAsHeadroom() {
        XCTAssertEqual(DatabaseCleanupService.reclaimablePages(pageCount: 1_000, freelistCount: 400), 200)
        XCTAssertEqual(DatabaseCleanupService.reclaimablePages(pageCount: 1_000, freelistCount: 100), 0)
        XCTAssertEqual(DatabaseCleanupService.reclaimablePages(pageCount: 1_000, freelistCount: 0), 0)
        XCTAssertEqual(DatabaseCleanupService.reclaimablePages(pageCount: 0, freelistCount: 0), 0)
    }

    func testIncrementalVacuumStepsAreBoundedByBytes() {
        XCTAssertEqual(DatabaseCleanupService.incrementalVacuumPagesPerStep(pageSize: 4096), 16_384)
        XCTAssertEqual(DatabaseCleanupService.incrementalVacuumPagesPerStep(pageSize: 0), 1)
    }
}
