import Foundation
import Sparkle

@MainActor
final class SparkleUpdateObserver: NSObject, SPUUpdaterDelegate {
    private weak var menuBarManager: MenuBarManager?

    init(menuBarManager: MenuBarManager) {
        self.menuBarManager = menuBarManager
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        menuBarManager?.notifyUpdateAvailable(
            shortVersion: item.displayVersionString,
            buildVersion: item.versionString
        )
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        menuBarManager?.notifyUpdateNotAvailable()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        menuBarManager?.notifyUpdateNotAvailable()
    }
}
