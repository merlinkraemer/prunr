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
    
    /// Whether no baseline exists
    var noBaseline = false
    
    /// Current scan progress info
    var scanProgress: String = ""
    
    /// Number of files scanned
    var filesScanned: Int = 0
    
    /// Recent files being scanned (for display)
    var recentFiles: [String] = []

    /// Total disk space in bytes
    var totalBytes: Int64 = 0

    /// Used disk space in bytes
    var usedBytes: Int64 = 0

    /// Free disk space in bytes
    var freeBytes: Int64 = 0

    // MARK: - Private Properties

    private let baselineService = BaselineService.shared
    private let diskSpaceService = DiskSpaceService.shared
    private let settingsStore = SettingsStore.shared
    private let scanService = ScanService.shared

    // MARK: - Public Methods

    /// Loads the growth list by comparing current state with baseline
    func loadGrowthList() async {
        // Get first enabled tracked path from settings
        let enabledPaths = settingsStore.enabledTrackedPaths
        guard let trackedPath = enabledPaths.first else {
            print("[MenuBarViewModel] No enabled tracked paths in settings")
            errorMessage = "No paths enabled in Settings"
            return
        }

        isLoading = true
        errorMessage = nil
        noBaseline = false
        filesScanned = 0
        recentFiles = []
        scanProgress = "Scanning \(trackedPath.displayName)..."
        
        print("[MenuBarViewModel] Loading growth list for: \(trackedPath.url.path)")
        print("[MenuBarViewModel] Enabled paths: \(enabledPaths.map { $0.displayName })")

        do {
            let items = try await baselineService.getGrowthList(trackedPath: trackedPath)
            growthItems = items
            scanProgress = ""
            print("[MenuBarViewModel] Loaded \(items.count) growth items")
        } catch {
            if let baselineError = error as? BaselineService.BaselineError,
               case .noBaseline = baselineError {
                print("[MenuBarViewModel] No baseline exists - need to create one first")
                noBaseline = true
                growthItems = []
            } else if let scanError = error as? ScanError, case .cancelled = scanError {
                print("[MenuBarViewModel] Scan was cancelled")
                scanProgress = "Cancelled"
            } else {
                print("[MenuBarViewModel] Error loading growth list: \(error)")
                errorMessage = "Scan failed: \(error.localizedDescription)"
            }
        }

        isLoading = false
        scanProgress = ""
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
            noBaseline = false
            print("[MenuBarViewModel] Baseline reset successfully")
        } catch {
            print("[MenuBarViewModel] Error resetting baseline: \(error)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
    
    /// Creates a new baseline from enabled paths
    func createBaseline() async {
        let enabledPaths = settingsStore.enabledTrackedPaths
        guard let trackedPath = enabledPaths.first else {
            errorMessage = "No paths enabled in Settings"
            return
        }
        
        isLoading = true
        errorMessage = nil
        filesScanned = 0
        recentFiles = []
        scanProgress = "Creating baseline for \(trackedPath.displayName)..."
        
        print("[MenuBarViewModel] Creating baseline for: \(trackedPath.url.path)")
        
        do {
            _ = try await baselineService.createBaseline(trackedPath: trackedPath)
            noBaseline = false
            scanProgress = ""
            print("[MenuBarViewModel] Baseline created successfully")
        } catch {
            if let scanError = error as? ScanError, case .cancelled = scanError {
                print("[MenuBarViewModel] Baseline creation cancelled")
                scanProgress = "Cancelled"
            } else {
                print("[MenuBarViewModel] Error creating baseline: \(error)")
                errorMessage = error.localizedDescription
            }
        }
        
        isLoading = false
        scanProgress = ""
    }
    
    /// Stops the current scan
    func stopScan() async {
        await scanService.cancelScan()
        scanProgress = "Stopping..."
    }
    
    /// Checks if baseline exists without triggering a scan
    func checkBaseline() async {
        let hasBaseline = await baselineService.hasBaseline()
        noBaseline = !hasBaseline
        
        if noBaseline {
            print("[MenuBarViewModel] No baseline exists")
        } else {
            print("[MenuBarViewModel] Baseline exists")
        }
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


