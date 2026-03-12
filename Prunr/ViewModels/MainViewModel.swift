import Foundation
import SwiftUI

/// ViewModel for the main window, managing snapshots, scans, and delta comparisons
@Observable
@MainActor
final class MainViewModel {
    private struct ComparisonSelection {
        let historicalSnapshot: Snapshot
        let skippedSnapshotCount: Int
    }

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

    /// Warning message when exact timeframe snapshot is unavailable
    var comparisonWarning: String?

    /// Comparison summary text (e.g., "Comparing now vs 2 days ago")
    var comparisonSummary: String?

    /// Current snapshot date for display
    var currentSnapshotDate: Date?

    /// Historical snapshot date for display
    var historicalSnapshotDate: Date?

    /// Current-only mode when only one snapshot exists
    var currentOnlyMode: Bool {
        snapshots.count == 1 || !hasComparableHistoricalSnapshot
    }

    /// Current snapshot entries for current-only mode display
    var currentSnapshotEntries: [SnapshotEntryWithPath] = []

    // MARK: - Private Properties

    private let scanService = ScanService.shared
    private let deltaService = DeltaService.shared
    private let db = DatabaseManager.shared
    private let fileManager = FileManager.default

    /// The ID of the most recent current-state snapshot (for comparison)
    private var currentSnapshotId: Int64?

    /// The ID of the historical snapshot being compared against
    private var historicalSnapshotId: Int64?
    private var hasComparableHistoricalSnapshot = false
    private let minimumComparableSnapshotEntryCount = 100

    // MARK: - Public Methods

    /// Updates the selected path and reloads data
    /// Called when user selects a different path in the sidebar
    func updatePath(_ path: TrackedPath) async {
        // Reset state for the new path
        selectedPath = path
        deltas = []
        errorMessage = nil
        comparisonWarning = nil
        comparisonSummary = nil
        currentSnapshotEntries = []
        hasComparableHistoricalSnapshot = false

        // Reload snapshots and comparison for the new path
        await loadSnapshots()
        await compareSince()
    }

    /// Loads all snapshots from the database for the currently selected path
    func loadSnapshots() async {
        guard let path = selectedPath else {
            snapshots = []
            return
        }
        do {
            snapshots = try await db.fetchAllSnapshots(trackedPathId: path.id)
        } catch {
            errorMessage = "Failed to load snapshots: \(error.localizedDescription)"
        }
    }

    /// Scans the given path and creates a new snapshot
    /// - Parameter path: The file system path to scan
    func scan(path: String) async {
        guard !isScanning else { return }
        guard let trackedPathId = selectedPath?.id else {
            errorMessage = "No path selected for scanning"
            return
        }

        // Check if path exists before attempting scan
        var isDirectory: ObjCBool = false
        let pathExists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)

        guard pathExists else {
            errorMessage = "Path does not exist: \(path)"
            return
        }

        guard isDirectory.boolValue else {
            errorMessage = "Path is not a directory: \(path)"
            return
        }

        // Check if we can read the directory
        let isReadable = fileManager.isReadableFile(atPath: path)
        guard isReadable else {
            errorMessage = "No permission to access \(path). Grant Full Disk Access in System Settings > Privacy & Security > Full Disk Access"
            return
        }

        isScanning = true
        scanProgress = "Starting scan..."
        errorMessage = nil

        do {
            let snapshot = try await scanService.scan(path: path, trackedPathId: trackedPathId) { [weak self] progress in
                Task { @MainActor in
                    self?.scanProgress = progress.currentPath
                }
            }

            // Store the current snapshot ID for comparison
            if let snapshotId = snapshot.id {
                currentSnapshotId = snapshotId
            }

            // Reload snapshots after successful scan
            await loadSnapshots()

        } catch {
            // Don't show error for cancelled scans
            if let scanError = error as? ScanError, case .cancelled = scanError {
                // Silent - cancelled scans are expected
            } else if let scanError = error as? ScanError {
                // Handle specific scan errors with helpful messages
                switch scanError {
                case .permissionDenied(let path):
                    errorMessage = "Permission denied: \(path)\n\nGrant Full Disk Access in System Settings > Privacy & Security > Full Disk Access"
                case .invalidPath:
                    errorMessage = "Invalid path or path does not exist"
                case .unknown(let err):
                    errorMessage = "Scan failed: \(err.localizedDescription)"
                case .cancelled:
                    break // Already handled above
                }
            } else {
                errorMessage = "Scan failed: \(error.localizedDescription)"
            }
        }

        isScanning = false
        scanProgress = ""
    }

    /// Stops the current scan operation
    func stopScan() async {
        guard isScanning else { return }
        await scanService.cancelScan()
    }

    /// Compares the two most recent snapshots
    /// Always compares newest vs second-newest
    func compareSince() async {
        guard selectedPath != nil else {
            deltas = []
            comparisonWarning = nil
            comparisonSummary = nil
            currentSnapshotEntries = []
            hasComparableHistoricalSnapshot = false
            return
        }

        guard let currentSnapshot = snapshots.first,
              let currentId = currentSnapshot.id else {
            currentSnapshotEntries = []
            deltas = []
            comparisonSummary = nil
            comparisonWarning = nil
            hasComparableHistoricalSnapshot = false
            return
        }

        currentSnapshotId = currentId
        currentSnapshotDate = currentSnapshot.createdAt

        guard snapshots.count >= 2 else {
            await enterCurrentOnlyMode(using: currentId, warning: nil)
            return
        }

        do {
            let currentEntryCount = try await db.fetchEntryCount(for: currentId)
            guard let selection = try await selectHistoricalSnapshot(currentEntryCount: currentEntryCount),
                  let historicalId = selection.historicalSnapshot.id else {
                await enterCurrentOnlyMode(
                    using: currentId,
                    warning: "Recent history is incomplete. Showing the latest snapshot until another full scan is available."
                )
                return
            }

            hasComparableHistoricalSnapshot = true
            currentSnapshotEntries = []
            historicalSnapshotId = historicalId
            historicalSnapshotDate = selection.historicalSnapshot.createdAt
            comparisonSummary = formattedComparisonSummary(
                current: currentSnapshot.createdAt,
                historical: selection.historicalSnapshot.createdAt
            )
            comparisonWarning = selection.skippedSnapshotCount > 0
                ? "Skipped \(selection.skippedSnapshotCount) incomplete snapshot\(selection.skippedSnapshotCount == 1 ? "" : "s") in the comparison window."
                : nil

            await performComparison(historicalId: historicalId, currentId: currentId)
        } catch {
            errorMessage = "Failed to compare snapshots: \(error.localizedDescription)"
            deltas = []
            comparisonSummary = nil
            hasComparableHistoricalSnapshot = false
        }
    }

    /// Performs the delta comparison between two snapshots
    private func performComparison(historicalId: Int64, currentId: Int64) async {
        do {
            deltas = try await deltaService.compare(beforeId: historicalId, afterId: currentId)
        } catch {
            errorMessage = "Failed to compare snapshots: \(error.localizedDescription)"
            deltas = []
        }
    }

    private func enterCurrentOnlyMode(using snapshotId: Int64, warning: String?) async {
        hasComparableHistoricalSnapshot = false
        historicalSnapshotId = nil
        historicalSnapshotDate = nil
        comparisonSummary = nil
        comparisonWarning = warning
        deltas = []

        do {
            currentSnapshotEntries = try await db.fetchEntries(for: snapshotId)
        } catch {
            currentSnapshotEntries = []
        }
    }

    private func selectHistoricalSnapshot(currentEntryCount: Int) async throws -> ComparisonSelection? {
        guard snapshots.count >= 2 else { return nil }

        let minimumExpectedEntryCount = max(
            minimumComparableSnapshotEntryCount,
            currentEntryCount / 2
        )

        for (index, snapshot) in snapshots.dropFirst().enumerated() {
            guard let snapshotId = snapshot.id else { continue }

            let entryCount = try await db.fetchEntryCount(for: snapshotId)
            guard entryCount >= minimumExpectedEntryCount else { continue }

            return ComparisonSelection(
                historicalSnapshot: snapshot,
                skippedSnapshotCount: index
            )
        }

        return nil
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

    /// Clears any displayed error message
    func dismissError() {
        errorMessage = nil
    }

    #if DEBUG
    /// Generates test data in the test_data folder for development testing
    /// Creates folders and files with changing sizes to demonstrate delta tracking
    /// Each call modifies file sizes to create visible deltas when scanning
    func generateTestData() async {
        let testPath = "/Users/merlinkramer/dev/projects/prunr/test_data"

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
        } catch {
            errorMessage = "Failed to generate test data: \(error.localizedDescription)"
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

    /// Formats a time span into a human-readable string
    /// - Parameter interval: Time interval in seconds
    /// - Returns: Formatted string like "2 hours ago", "3 days ago"
    private func formattedTimeSpan(_ interval: TimeInterval) -> String {
        let hours = Int(interval / 3600)
        let days = hours / 24

        if days >= 1 {
            return "\(days) day\(days == 1 ? "" : "s")"
        } else if hours >= 1 {
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        } else {
            let minutes = Int(interval / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
    }

    /// Formats a snapshot date for display in comparison summary
    /// - Parameter date: The date to format
    /// - Returns: Formatted string like "2h ago", "3d ago", or "Jan 10"
    func formattedSnapshotDate(_ date: Date) -> String {
        let hoursAgo = Int(Date().timeIntervalSince(date) / 3600)

        if hoursAgo < 1 {
            let minutesAgo = Int(Date().timeIntervalSince(date) / 60)
            return "\(minutesAgo)m ago"
        } else if hoursAgo < 24 {
            return "\(hoursAgo)h ago"
        }

        let daysAgo = hoursAgo / 24
        if daysAgo < 7 {
            return "\(daysAgo)d ago"
        }

        // Use date formatter for older dates
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// Creates a comparison summary string
    /// - Parameters:
    ///   - current: The current snapshot date
    ///   - historical: The historical snapshot date
    /// - Returns: Formatted summary like "2h ago vs 2d ago"
    private func formattedComparisonSummary(current: Date, historical: Date) -> String {
        let currentLabel = formattedSnapshotDate(current)
        let historicalLabel = formattedSnapshotDate(historical)
        return "\(currentLabel) vs \(historicalLabel)"
    }
}
