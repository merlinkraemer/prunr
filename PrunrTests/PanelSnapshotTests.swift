import SwiftUI
import XCTest
@testable import Prunr

@MainActor
final class PanelSnapshotTests: PrunrTestCase {
    func testRendersFixturePanelsToPNG() async throws {
        let directory = ReplayHarnessTests.outputRoot.appendingPathComponent("fixture")
        try? FileManager.default.removeItem(at: directory)

        try await withEmptyTemporaryDatabase { trackedPathId in
            try await FixtureLibrary.seed(trackedPathId: trackedPathId)
            let result = try await ReplayHarness.run(
                source: "fixture",
                trackedPathIds: [trackedPathId],
                home: FixtureLibrary.home,
                now: FixtureLibrary.now,
                catalog: FixtureLibrary.catalog
            )

            let names = try PanelSnapshot.writePanels(
                of: result,
                to: directory,
                metrics: FixtureLibrary.metrics,
                groupLimit: 4
            )
            XCTAssertTrue(names.contains("main"))
            XCTAssertTrue(names.contains { $0.contains("-place-") })

            let light = try PanelSnapshot.png(.main(result.feed), metrics: FixtureLibrary.metrics, colorScheme: .light)
            try light.write(to: directory.appendingPathComponent("main-light.png"))

            for name in names {
                let data = try Data(contentsOf: directory.appendingPathComponent(name + ".png"))
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), name)
                XCTAssertEqual(bitmap.pixelsWide, 2 * (320 + 48), name)
                XCTAssertEqual(bitmap.pixelsHigh, 2 * (480 + 48), name)
            }
        }
    }
}
