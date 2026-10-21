import AppKit
import SwiftUI
import XCTest
@testable import Prunr

@MainActor
final class MarketingScreenshotTests: XCTestCase {
    static let outputDirectory = URL(fileURLWithPath: "/tmp/PrunrMarketingShots/reddit", isDirectory: true)

    private let shots: [(name: String, page: MarketingPanelPage, colorScheme: ColorScheme)] = [
        ("prunr-1-main-dark", .main, .dark),
        ("prunr-2-app-places-dark", .app, .dark),
        ("prunr-3-place-contents-dark", .contents, .dark),
        ("prunr-4-main-light", .main, .light)
    ]

    func testRendersPanelShotsWithSampleData() throws {
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)

        for shot in shots {
            let data = try MarketingScreenshotRenderer.panelPNG(page: shot.page, colorScheme: shot.colorScheme)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), shot.name)
            XCTAssertEqual(bitmap.pixelsWide, 2 * (320 + 2 * 24), shot.name)
            XCTAssertEqual(bitmap.pixelsHigh, 2 * (480 + 2 * 24), shot.name)
            try data.write(to: Self.outputDirectory.appendingPathComponent(shot.name + ".png"))
        }
    }
}
