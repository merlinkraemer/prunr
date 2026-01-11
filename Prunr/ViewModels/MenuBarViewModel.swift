import Foundation
import SwiftUI
import AppKit

/// ViewModel for the menu bar popover UI
@Observable
@MainActor
final class MenuBarViewModel {

    // MARK: - Published State

    /// Growth items calculated from baseline comparison
    var growthItems: [BaselineService.GrowthItem] = []

    /// Whether a scan is in progress
    var isLoading = false

    /// User-visible error message
    var errorMessage: String?

    /// Total disk space in bytes
    var totalBytes: Int64 = 0

    /// Used disk space in bytes
    var usedBytes: Int64 = 0

    /// Free disk space in bytes
    var freeBytes: Int64 = 0

    // MARK: - Private Properties

    private let baselineService = BaselineService.shared
    private let diskSpaceService = DiskSpaceService.shared
    private let trackedPath = TrackedPath.defaultPaths.first // Home directory

    // MARK: - Public Methods

    /// Loads the growth list by comparing current state with baseline
    func loadGrowthList() async {
        guard let trackedPath else { return }

        isLoading = true
        errorMessage = nil

        do {
            let items = try await baselineService.getGrowthList(trackedPath: trackedPath)
            growthItems = items
        } catch {
            if let baselineError = error as? BaselineService.BaselineError,
               case .noBaseline = baselineError {
                // No baseline exists yet - this is expected on first run
                growthItems = []
            } else {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    /// Refreshes disk space information
    func refreshDiskSpace() {
        freeBytes = diskSpaceService.getFreeSpace()
        totalBytes = diskSpaceService.getTotalSpace()
        usedBytes = totalBytes - freeBytes
    }

    /// Resets the baseline and clears growth data
    func resetBaseline() async {
        isLoading = true
        errorMessage = nil

        do {
            try await baselineService.resetBaseline()
            growthItems = []
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Reveals the given path in Finder
    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Initializes the view model with current disk space
    init() {
        refreshDiskSpace()
    }
}
