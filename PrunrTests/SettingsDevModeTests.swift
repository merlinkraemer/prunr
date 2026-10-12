import SwiftUI
import XCTest
@testable import Prunr

@MainActor
final class SettingsDevModeTests: PrunrTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PrunrTests.DevMode.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDevModeDefaultsToOnInDebugAndOffInRelease() {
        XCTAssertTrue(DevMode.resolve(arguments: [], defaults: defaults, isDebugBuild: true))
        XCTAssertFalse(DevMode.resolve(arguments: [], defaults: defaults, isDebugBuild: false))
    }

    func testStoredDevModeOverridesBuildDefault() {
        defaults.set(false, forKey: DevMode.defaultsKey)
        XCTAssertFalse(DevMode.resolve(arguments: [], defaults: defaults, isDebugBuild: true))

        defaults.set(true, forKey: DevMode.defaultsKey)
        XCTAssertTrue(DevMode.resolve(arguments: [], defaults: defaults, isDebugBuild: false))
    }

    func testLaunchArgumentOverridesStoredValue() {
        defaults.set(false, forKey: DevMode.defaultsKey)
        XCTAssertTrue(DevMode.resolve(arguments: ["Prunr", "-devMode", "YES"], defaults: defaults, isDebugBuild: false))

        defaults.set(true, forKey: DevMode.defaultsKey)
        XCTAssertFalse(DevMode.resolve(arguments: ["Prunr", "-devMode", "NO"], defaults: defaults, isDebugBuild: true))
    }

    func testUnreadableLaunchArgumentFallsBackToStoredValue() {
        defaults.set(true, forKey: DevMode.defaultsKey)
        XCTAssertTrue(DevMode.resolve(arguments: ["Prunr", "-devMode", "maybe"], defaults: defaults, isDebugBuild: false))
        XCTAssertTrue(DevMode.resolve(arguments: ["Prunr", "-devMode"], defaults: defaults, isDebugBuild: false))
    }

    func testToggleStoresValueAndTurningOffReturnsPanelToLive() {
        let devMode = DevMode(defaults: defaults, arguments: [], isDebugBuild: false)
        XCTAssertFalse(devMode.isEnabled)

        let posted = expectation(forNotification: .devModeDidChange, object: devMode)
        devMode.toggle()
        wait(for: [posted], timeout: 1)
        XCTAssertTrue(devMode.isEnabled)
        XCTAssertEqual(defaults.object(forKey: DevMode.defaultsKey) as? Bool, true)

        devMode.panelPreview = .sample
        devMode.toggle()
        XCTAssertFalse(devMode.isEnabled)
        XCTAssertEqual(devMode.panelPreview, .live)
        XCTAssertEqual(defaults.object(forKey: DevMode.defaultsKey) as? Bool, false)
    }

    func testSettingsTabsHideDeveloperUnlessDevMode() {
        XCTAssertEqual(SettingsTab.visibleTabs(devMode: false), [.general, .folder, .feedback])
        XCTAssertEqual(SettingsTab.visibleTabs(devMode: true), [.general, .folder, .feedback, .developer])
        XCTAssertEqual(SettingsTab.visibleTabs(devMode: false).map(\.title), ["General", "Folder", "Feedback"])
    }

    func testRestoredTabFallsBackWhenDeveloperIsHidden() {
        XCTAssertEqual(SettingsTab.restored(rawValue: SettingsTab.developer.rawValue, devMode: false), .general)
        XCTAssertEqual(SettingsTab.restored(rawValue: SettingsTab.developer.rawValue, devMode: true), .developer)
        XCTAssertEqual(SettingsTab.restored(rawValue: 2, devMode: false), .folder)
        XCTAssertEqual(SettingsTab.restored(rawValue: 3, devMode: false), .feedback)
        XCTAssertEqual(SettingsTab.restored(rawValue: 99, devMode: true), .general)
    }

    func testFolderNameForHome() {
        let folder = ScanFolderName(path: "/Users/sample", homePath: "/Users/sample")
        XCTAssertTrue(folder.isHome)
        XCTAssertEqual(folder.title, "Home")
        XCTAssertEqual(folder.displayPath, "/Users/sample")
        XCTAssertEqual(
            ChangeFeedStateView.dayOneText(folder: folder),
            "Watching your home folder since today. Changes show here from tomorrow."
        )
    }

    func testFolderNameForChosenFolderReplacesHomeInCopy() {
        let folder = ScanFolderName(path: "/Users/sample/dev/", homePath: "/Users/sample")
        XCTAssertFalse(folder.isHome)
        XCTAssertEqual(folder.title, "dev")
        XCTAssertEqual(folder.displayPath, "~/dev")

        let dayOne = ChangeFeedStateView.dayOneText(folder: folder)
        XCTAssertTrue(dayOne.contains("the dev folder"))
        XCTAssertFalse(dayOne.contains("home folder"))
    }

    func testFolderNameForWholeDisk() {
        let folder = ScanFolderName(path: "/", homePath: "/Users/sample")
        XCTAssertEqual(folder.title, "Whole disk")
        XCTAssertTrue(ChangeFeedStateView.dayOneText(folder: folder).contains("your whole disk"))
    }

    func testPanelPreviewOverridesOnlyWhatThePanelShows() {
        let now = Date()
        let live = ChangeFeedResult.loaded(MarketingSample.feed)

        XCTAssertEqual(PanelPreview.live.changeFeed(over: live, now: now), live)
        XCTAssertEqual(PanelPreview.live.errorMessage(over: "boom"), "boom")
        XCTAssertEqual(PanelPreview.error.changeFeed(over: live, now: now), .failed)
        XCTAssertNil(PanelPreview.error.errorMessage(over: "boom"))
        XCTAssertEqual(PanelPreview.sample.changeFeed(over: nil, now: now), .loaded(MarketingSample.feed))
        XCTAssertEqual(PanelPreview.dayOne.changeFeed(over: live, now: now)?.feed?.isDayOne(now: now), true)
    }

    func testPanelPreviewNeverTouchesTheDatabaseOrManagerState() async throws {
        try await withTemporaryDatabase { trackedPathId, _ in
            let snapshotsBefore = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPathId)
            let manager = MenuBarManager()
            let feedBefore = manager.changeFeed
            let categoriesBefore = manager.allCategories.map(\.category)
            let devMode = DevMode(defaults: self.defaults, arguments: [], isDebugBuild: true)

            for preview in PanelPreview.allCases {
                devMode.panelPreview = preview
                _ = preview.changeFeed(over: manager.changeFeed)
                _ = preview.errorMessage(over: manager.errorMessage)
            }
            let renderer = ImageRenderer(content: PanelSamplePreview().frame(width: 320, height: 480))
            XCTAssertNotNil(renderer.nsImage)
            devMode.panelPreview = .live

            let snapshotsAfter = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPathId)
            XCTAssertEqual(snapshotsAfter.map(\.id), snapshotsBefore.map(\.id))
            XCTAssertEqual(manager.changeFeed, feedBefore)
            XCTAssertEqual(manager.allCategories.map(\.category), categoriesBefore)
            XCTAssertNil(self.defaults.object(forKey: HistoryStart.defaultsKey))
        }
    }

    func testPerfLoggingDefaultsOnAndCanBeTurnedOff() {
        XCTAssertTrue(PerfLogging.isEnabled(defaults: defaults))
        PerfLogging.setEnabled(false, defaults: defaults)
        XCTAssertFalse(PerfLogging.isEnabled(defaults: defaults))
    }
}
