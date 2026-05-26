import AppKit
import Darwin
import Sparkle

// MARK: - Pure AppKit Entry Point
//
// IMPORTANT: We do NOT use SwiftUI's `App` protocol here.
//
// The SwiftUI `App` protocol always creates at least one NSHostingView per Scene
// (WindowGroup, Settings). Even an EmptyView WindowGroup creates an NSHostingView
// that participates in the Core Animation display cycle. When @Observable properties
// on MenuBarManager change (from background scans, watcher callbacks, timer updates),
// SwiftUI's observation system invalidates ALL hosting views, causing continuous
// layout passes on every CA frame (~17% idle CPU).
//
// By using a pure AppKit AppDelegate, we avoid creating ANY SwiftUI hosting views
// until the user explicitly opens the dropdown panel. MenuBarManager creates its
// panel's NSHostingView lazily on first show. Settings is opened via openSettings()
// which creates a programmatic NSWindow with NSHostingController<SettingsView>.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBarManager = MenuBarManager()
    private var updaterController: SPUStandardUpdaterController?
    private var sparkleUpdateObserver: SparkleUpdateObserver?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Handle headless CLI commands (stress-scan, e2e, etc.)
        if let exitCode = HeadlessCommandRouter.runIfNeeded(arguments: Array(CommandLine.arguments.dropFirst())) {
            Darwin.exit(exitCode)
        }

        NSApp.setActivationPolicy(.accessory)
        configureUpdaterIfPossible()

        do {
            try DatabaseManager.shared.initialize()
            Task { @MainActor [menuBarManager] in
                await menuBarManager.configureMonitoringOnLaunch()
            }
            Task.detached(priority: .utility) {
                _ = try? await DatabaseCleanupService.shared.cleanupAbandonedSnapshots()
                await DatabaseCleanupService.shared.performStartupMaintenance()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Prunr could not start"
            alert.informativeText = "The database failed to initialize: \(error.localizedDescription)\n\nTry relaunching the app. If the problem persists, delete ~/Library/Application Support/Prunr and relaunch."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func configureUpdaterIfPossible() {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String

        guard let feedURL, !feedURL.isEmpty, let publicKey, !publicKey.isEmpty else {
            menuBarManager.disableUpdater()
            return
        }

        let sparkleUpdateObserver = SparkleUpdateObserver(menuBarManager: menuBarManager)
        self.sparkleUpdateObserver = sparkleUpdateObserver

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: sparkleUpdateObserver,
            userDriverDelegate: nil
        )
        self.updaterController = updaterController
        menuBarManager.configureUpdater(
            checkForUpdates: { [updaterController] sender in
                updaterController.checkForUpdates(sender)
            },
            checkForUpdatesInBackground: { [updaterController] in
                updaterController.updater.checkForUpdatesInBackground()
            }
        )
    }
}

// Manual entry point — no SwiftUI App scene graph, no implicit hosting views.
@main
struct PrunrEntryPoint {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Set activation policy BEFORE starting the run loop to prevent
        // the system UpdateCycle timer from running at 60fps for a menu-bar-only app.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
