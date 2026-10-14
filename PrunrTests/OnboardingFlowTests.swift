import XCTest
@testable import Prunr

@MainActor
final class OnboardingFlowTests: PrunrTestCase {
    private let home = URL(fileURLWithPath: "/Users/sample", isDirectory: true)

    func testFolderOptionsAreHomeDesktopAndFullDisk() {
        let options = OnboardingFolderOption.options(home: home, custom: nil)

        XCTAssertEqual(options.map(\.title), ["Home", "Desktop", "Full disk"])
        XCTAssertEqual(options.map(\.subtitle), ["~", "~/Desktop", "/"])
        XCTAssertEqual(options.first?.badge, "Recommended")
        XCTAssertEqual(options.dropFirst().compactMap(\.badge), [])
        XCTAssertFalse(options.contains { $0.url.lastPathComponent == "dev" })
    }

    func testCustomFolderLeadsTheListUnlessItIsAlreadyAnOption() {
        let custom = home.appendingPathComponent("Projects", isDirectory: true)
        let withCustom = OnboardingFolderOption.options(home: home, custom: custom)
        XCTAssertEqual(withCustom.map(\.subtitle), ["~/Projects", "~", "~/Desktop", "/"])

        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        XCTAssertEqual(OnboardingFolderOption.options(home: home, custom: desktop).count, 3)
    }

    func testDisplayPathShortensOnlyTheHomeFolder() {
        XCTAssertEqual(OnboardingFolderOption.displayPath(for: home, home: home), "~")
        XCTAssertEqual(OnboardingFolderOption.displayPath(for: URL(fileURLWithPath: "/"), home: home), "/")
        XCTAssertEqual(
            OnboardingFolderOption.displayPath(for: URL(fileURLWithPath: "/Users/sample2/x"), home: home),
            "/Users/sample2/x"
        )
    }

    func testNotNowUnlocksTheScanStepWithoutAccess() {
        XCTAssertEqual(OnboardingPage.maxUnlocked(folderChosen: false, accessGranted: true, accessSkipped: true), .folder)
        XCTAssertEqual(OnboardingPage.maxUnlocked(folderChosen: true, accessGranted: false, accessSkipped: false), .permissions)
        XCTAssertEqual(OnboardingPage.maxUnlocked(folderChosen: true, accessGranted: false, accessSkipped: true), .scan)
        XCTAssertEqual(OnboardingPage.maxUnlocked(folderChosen: true, accessGranted: true, accessSkipped: false), .scan)
    }

    func testStepPillsReadFolderAccessScan() {
        XCTAssertEqual(OnboardingPage.allCases.map(\.title), ["Folder", "Access", "Scan"])
    }
}
