import XCTest
@testable import Prunr

@MainActor
final class DrilldownNavigationGuardTests: PrunrTestCase {
    func testCanStartWhenIdle() {
        let manager = MenuBarManager()

        XCTAssertTrue(manager.canStartDrilldownTransition)
    }

    func testCannotStartWhileSlideIsAnimating() {
        let manager = MenuBarManager()
        manager.isDrillDownTransitionAnimating = true

        XCTAssertFalse(manager.canStartDrilldownTransition)
    }

    func testCannotStartWhileTransitionIsQueued() {
        let manager = MenuBarManager()
        manager.hasQueuedDrilldownTransition = true

        XCTAssertFalse(manager.canStartDrilldownTransition)
    }
}
