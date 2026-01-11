import Foundation
import SwiftUI

/// ViewModel for the main window, managing snapshots, scans, and delta comparisons
@Observable
@MainActor
final class MainViewModel {

    // MARK: - Published State

    /// All available snapshots from the database
    var snapshots: [Snapshot] = []

    /// Current comparison results
    var deltas: [Delta] = []

    /// Whether a scan is in progress
    var isScanning = false

    /// Current path being scanned (progress feedback)
    var scanProgress: String = ""

    /// User-visible error message
    var errorMessage: String?

    /// Currently selected path for scanning and comparison
    var selectedPath: TrackedPath?

    /// The comparison interval in seconds (default 24 hours)
    var comparisonInterval: TimeInterval = 86400

    // MARK: - Private Properties

    private let scanService = ScanService.shared
    private let deltaService = DeltaService.shared
    private let db = DatabaseManager.shared
    private let fileManager = FileManager.default

    /// The ID of the most recent current-state snapshot (for comparison)
    private var currentSnapshotId: Int64?

    /// The ID of the historical snapshot being compared against
    private var historicalSnapshotId: Int64?

    // MARK: - Initialization

    init() {
        // Load the comparison interval from AppStorage
        if let storedValue = UserDefaults.standard.object(forKey: "comparisonInterval") as? TimeInterval {
            self.comparisonInterval = storedValue
        }
    }

    // MARK: - Public Methods

    /// Loads all snapshots from the database
    func loadSnapshots() async {
        do {
            snapshots = try await db.fetchAllSnapshots()
        } catch {
            errorMessage = "Failed to load snapshots: \(error.localizedDescription)"
        }
    }

    /// Scans the given path and creates a new snapshot
    /// - Parameter path: The file system path to scan
    func scan(path: String) async {
        guard !isScanning else { return }

        print("[DEBUG] Starting scan of: \(path)")
        isScanning = true
        scanProgress = "Starting scan..."
        errorMessage = nil

        do {
            let snapshot = try await scanService.scan(path: path) { [weak self] progress in
                Task { @MainActor in
                    self?.scanProgress = progress.currentPath
                }
            }
            print("[DEBUG] Scan completed, snapshot ID: \(snapshot.id ?? -1)")

            // Store the current snapshot ID for comparison
            if let snapshotId = snapshot.id {
                currentSnapshotId = snapshotId
            }

            // Reload snapshots after successful scan
            await loadSnapshots()

        } catch {
            // Don't show error for cancelled scans
            if let scanError = error as? ScanError, case .cancelled = scanError {
                print("[DEBUG] Scan cancelled")
            } else {
                let errorMsg = "Scan failed: \(error.localizedDescription)"
                print("[ERROR] \(errorMsg)")
                print("[ERROR] Full error: \(error)")
                errorMessage = errorMsg
            }
        }

        isScanning = false
        scanProgress = ""
    }

    /// Stops the current scan operation
    func stopScan() async {
        guard isScanning else { return }
        print("[DEBUG] Stopping scan...")
        await scanService.cancelScan()
    }

    /// Compares the two most recent snapshots
    /// Simplified workflow: always compare newest vs second-newest
    func compareSince() async {
        guard selectedPath != nil else {
            deltas = []
            return
        }

        guard snapshots.count >= 2 else {
            errorMessage = "Need at least 2 snapshots to compare. Scan this path at least twice."
            deltas = []
            return
        }

        // Use the two most recent snapshots
        // snapshots[0] = newest (current), snapshots[1] = second newest (previous)
        guard let currentId = snapshots[0].id,
              let previousId = snapshots[1].id else {
            errorMessage = "Invalid snapshot IDs."
            deltas = []
            return
        }

        print("[DEBUG] Comparing snapshots: previousId=\(previousId), currentId=\(currentId)")

        await performComparison(historicalId: previousId, currentId: currentId)
    }

    /// Performs the delta comparison between two snapshots
    private func performComparison(historicalId: Int64, currentId: Int64) async {
        print("[DEBUG] Comparing snapshots: historicalId=\(historicalId), currentId=\(currentId)")

        do {
            deltas = try await deltaService.compare(beforeId: historicalId, afterId: currentId)
            print("[DEBUG] Comparison successful: \(deltas.count) deltas")
        } catch {
            let errorMsg = "Failed to compare snapshots: \(error.localizedDescription)"
            print("[ERROR] \(errorMsg)")
            print("[ERROR] Full error: \(error)")
            errorMessage = errorMsg
            deltas = []
        }
    }

    /// Scans the current state of the selected path
    func scanCurrentState() async {
        guard let path = selectedPath else {
            errorMessage = "No path selected for scanning"
            return
        }
        await scan(path: path.url.path)
        // Re-run comparison after scanning
        await compareSince()
    }

    /// Updates the comparison interval and persists it to UserDefaults
    func updateComparisonInterval(_ interval: TimeInterval) {
        comparisonInterval = interval
        UserDefaults.standard.set(interval, forKey: "comparisonInterval")
    }

    /// Clears any displayed error message
    func dismissError() {
        errorMessage = nil
    }

    #if DEBUG
    /// Generates test data in the test_data folder for development testing
    /// Creates folders and files with changing sizes to demonstrate delta tracking
    /// Each call modifies file sizes to create visible deltas when scanning
    func generateTestData() async {
        print("[DEBUG] ========== generateTestData called ==========")
        let testPath = "/Users/merlinkramer/dev/projects/prunr/test_data"
        print("[DEBUG] Generating test data in: \(testPath)")

        do {
            // Create test folder if it doesn't exist
            if !fileManager.fileExists(atPath: testPath) {
                try fileManager.createDirectory(atPath: testPath, withIntermediateDirectories: true)
            }

            // Helper to write data to a file
            func writeData(_ data: Data, to file: String) throws {
                try data.write(to: URL(fileURLWithPath: testPath).appendingPathComponent(file))
            }

            // Use timestamp to vary sizes each run
            let timestamp = Int(Date().timeIntervalSince1970)
            let randomVariation = timestamp % 10 + 1  // 1-10 variation factor

            // Files that grow: growing_file.txt (increases each run)
            let baseSize = 1_000_000  // 1 MB base
            let growingSize = baseSize + (randomVariation * 500_000)  // Add 0.5-5 MB
            try writeData(Data(repeating: UInt8(randomVariation), count: growingSize), to: "growing_file.txt")

            // Files that shrink: shrinking_file.txt (decreases each run)
            let shrinkingSize = max(100_000, 5_000_000 - (randomVariation * 400_000))  // Start at 5 MB, shrink
            try writeData(Data(repeating: 0xAA, count: shrinkingSize), to: "shrinking_file.txt")

            // Stable file (same size, different timestamp content)
            try writeData("Stable content at \(timestamp)".data(using: .utf8)!, to: "stable_file.txt")

            // New file with timestamp (appears as new each time if deleted)
            try writeData("New content \(timestamp)".data(using: .utf8)!, to: "timestamp_file.txt")

            // Create a folder with a large file
            let folderPath = (testPath as NSString).appendingPathComponent("test_folder")
            if !fileManager.fileExists(atPath: folderPath) {
                try fileManager.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
            }
            try Data(repeating: 0xDD, count: 2_000_000 + Int(randomVariation * 200_000))
                .write(to: URL(fileURLWithPath: folderPath).appendingPathComponent("folder_file.bin"))

            errorMessage = nil
            print("[DEBUG] Test data generated successfully - sizes will vary on each run")
        } catch {
            let msg = "Failed to generate test data: \(error.localizedDescription)"
            errorMessage = msg
            print("[ERROR] \(msg)")
        }
    }
    #endif

    // MARK: - Helpers

    /// Formats the comparison interval for display
    private func formattedInterval(_ interval: TimeInterval) -> String {
        let hours = Int(interval / 3600)
        let days = hours / 24

        if days >= 1 {
            return "\(days)d"
        } else if hours >= 1 {
            return "\(hours)h"
        } else {
            let minutes = Int(interval / 60)
            return "\(minutes)m"
        }
    }
}
