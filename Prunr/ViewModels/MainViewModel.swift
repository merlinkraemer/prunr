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

    /// Warning message when exact timeframe snapshot is unavailable
    var comparisonWarning: String?

    /// Comparison summary text (e.g., "Comparing now vs 2 days ago")
    var comparisonSummary: String?

    /// Current snapshot date for display
    var currentSnapshotDate: Date?

    /// Historical snapshot date for display
    var historicalSnapshotDate: Date?

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

    /// Updates the selected path and reloads data
    /// Called when user selects a different path in the sidebar
    func updatePath(_ path: TrackedPath) async {
        // Reset state for the new path
        selectedPath = path
        deltas = []
        errorMessage = nil
        comparisonWarning = nil

        // Reload snapshots and comparison for the new path
        await loadSnapshots()
        await compareSince()
    }

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

            // Use timestamp to vary sizes each run
            let timestamp = Int(Date().timeIntervalSince1970)
            let randomVariation = timestamp % 10 + 1  // 1-10 variation factor

            // Helper to create directory if needed
            func ensureDirectory(_ path: String) throws {
                if !fileManager.fileExists(atPath: path) {
                    try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
                }
            }

            // Helper to write data to a file (creates parent directories)
            func writeData(_ data: Data, to path: String) throws {
                let url = URL(fileURLWithPath: path)
                let dir = url.deletingLastPathComponent().path
                if !fileManager.fileExists(atPath: dir) {
                    try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
                }
                try data.write(to: url)
            }

            // MARK: - Homebrew category
            try writeData(
                Data(repeating: UInt8(0x01), count: 50_000_000 + Int(randomVariation * 5_000_000)),
                to: (testPath as NSString).appendingPathComponent("Cellar/python/libpython3.11.dylib")
            )
            try writeData(
                Data(repeating: UInt8(0x02), count: 30_000_000 + Int(randomVariation * 3_000_000)),
                to: (testPath as NSString).appendingPathComponent("Cellar/node/bin/node")
            )

            // MARK: - Docker category
            try writeData(
                Data(repeating: UInt8(0x03), count: 100_000_000 + Int(randomVariation * 10_000_000)),
                to: (testPath as NSString).appendingPathComponent(".docker/overlay2.img")
            )

            // MARK: - NPM category
            let packages = ["lodash", "react", "vue", "express", "typescript"]
            for pkg in packages {
                let size = (5_000_000 * (packages.firstIndex(of: pkg)! + 1)) + (randomVariation * 1_000_000)
                try writeData(
                    Data(repeating: UInt8(0x04), count: size),
                    to: (testPath as NSString).appendingPathComponent("node_modules/\(pkg)/index.js")
                )
            }

            // MARK: - Developer category
            try writeData(
                Data(repeating: UInt8(0x05), count: 200_000_000 + Int(randomVariation * 20_000_000)),
                to: (testPath as NSString).appendingPathComponent("DerivedData/BuildProducts")
            )

            // MARK: - Media category
            try writeData(
                Data(repeating: UInt8(0x06), count: 150_000_000 + Int(randomVariation * 15_000_000)),
                to: (testPath as NSString).appendingPathComponent("Media/vacation.mp4")
            )
            try writeData(
                Data(repeating: UInt8(0x07), count: 80_000_000 + Int(randomVariation * 8_000_000)),
                to: (testPath as NSString).appendingPathComponent("Media/birthday.mov")
            )
            try writeData(
                Data(repeating: UInt8(0x08), count: 25_000_000 + Int(randomVariation * 2_500_000)),
                to: (testPath as NSString).appendingPathComponent("Media/photo.jpg")
            )
            try writeData(
                Data(repeating: UInt8(0x09), count: 40_000_000 + Int(randomVariation * 4_000_000)),
                to: (testPath as NSString).appendingPathComponent("Media/design.psd")
            )
            try writeData(
                Data(repeating: UInt8(0x0A), count: 15_000_000 + Int(randomVariation * 1_500_000)),
                to: (testPath as NSString).appendingPathComponent("Media/logo.ai")
            )

            // MARK: - Containers category
            try writeData(
                Data(repeating: UInt8(0x0B), count: 20_000_000 + Int(randomVariation * 2_000_000)),
                to: (testPath as NSString).appendingPathComponent("Library/Containers/com.example.app/Data.sqlite")
            )

            // MARK: - Caches category
            try writeData(
                Data(repeating: UInt8(0x0C), count: 35_000_000 + Int(randomVariation * 3_500_000)),
                to: (testPath as NSString).appendingPathComponent("Library/Caches/com.apple.safaricache")
            )

            // MARK: - Packages category
            try writeData(
                Data(repeating: UInt8(0x0D), count: 45_000_000 + Int(randomVariation * 4_500_000)),
                to: (testPath as NSString).appendingPathComponent("installer.pkg")
            )

            // MARK: - Apps category
            try writeData(
                Data(repeating: UInt8(0x0E), count: 60_000_000 + Int(randomVariation * 6_000_000)),
                to: (testPath as NSString).appendingPathComponent("TestApp.app/Contents/MacOS/executable")
            )

            // MARK: - Other (miscellaneous files)
            try writeData(
                Data(repeating: UInt8(0x0F), count: 10_000_000 + Int(randomVariation * 1_000_000)),
                to: (testPath as NSString).appendingPathComponent("document.pdf")
            )
            let logContent = String(repeating: "Log entry at \(timestamp)\n", count: 1000)
            try writeData(
                logContent.data(using: .utf8)!,
                to: (testPath as NSString).appendingPathComponent("logs.txt")
            )

            // Some files that shrink (to show negative deltas)
            let shrinkingSize = max(100_000, 50_000_000 - (randomVariation * 4_000_000))
            try writeData(
                Data(repeating: 0xAA, count: shrinkingSize),
                to: (testPath as NSString).appendingPathComponent("old_backup.tar")
            )

            errorMessage = nil
            print("[DEBUG] Test data generated successfully - sizes will vary on each run")
            print("[DEBUG] Categories: Homebrew, Docker, NPM, Developer, Media, Containers, Caches, Packages, Apps")
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
