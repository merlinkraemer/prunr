import Foundation

/// ViewModel for the main window, managing snapshots, scans, and delta comparisons
@Observable
@MainActor
final class MainViewModel {

    // MARK: - Published State

    /// All available snapshots from the database
    var snapshots: [Snapshot] = []

    /// The older snapshot for comparison (before)
    var selectedBeforeSnapshot: Snapshot?

    /// The newer snapshot for comparison (after)
    var selectedAfterSnapshot: Snapshot?

    /// Current comparison results
    var deltas: [Delta] = []

    /// Whether a scan is in progress
    var isScanning = false

    /// Current path being scanned (progress feedback)
    var scanProgress: String = ""

    /// User-visible error message
    var errorMessage: String?

    // MARK: - Private Properties

    private let scanService = ScanService.shared
    private let deltaService = DeltaService.shared
    private let db = DatabaseManager.shared
    private let fileManager = FileManager.default

    #if DEBUG
    /// Test folder path inside project directory for development testing
    var testFolderPath: String {
        // Start from bundle path and navigate up to find project
        var path = Bundle.main.bundlePath
        for _ in 0..<10 {  // Limit iterations to prevent infinite loop
            let projectCheck = (path as NSString).appendingPathComponent("Prunr.xcodeproj")
            if fileManager.fileExists(atPath: projectCheck) {
                let result = (path as NSString).appendingPathComponent("PrunrTest")
                print("[DEBUG] Found project at: \(path)")
                print("[DEBUG] Test folder path: \(result)")
                return result
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { break }
            path = parent
        }

        // Fallback - use cwd and search up
        var cwd = fileManager.currentDirectoryPath
        for _ in 0..<10 {
            let projectCheck = (cwd as NSString).appendingPathComponent("Prunr.xcodeproj")
            if fileManager.fileExists(atPath: projectCheck) {
                let result = (cwd as NSString).appendingPathComponent("PrunrTest")
                print("[DEBUG] Found project from cwd at: \(cwd)")
                return result
            }
            let parent = (cwd as NSString).deletingLastPathComponent
            if parent == cwd || parent.isEmpty { break }
            cwd = parent
        }

        // Last resort - just use cwd + PrunrTest
        let result = fileManager.currentDirectoryPath.appending("/PrunrTest")
        print("[DEBUG] Using fallback path: \(result)")
        return result
    }
    #endif

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

            // Reload snapshots after successful scan
            await loadSnapshots()
            autoSelectSnapshots()

        } catch {
            let errorMsg = "Scan failed: \(error.localizedDescription)"
            print("[ERROR] \(errorMsg)")
            print("[ERROR] Full error: \(error)")
            errorMessage = errorMsg
        }

        isScanning = false
        scanProgress = ""
    }

    /// Compares the selected before and after snapshots
    func compareSnapshots() async {
        guard let before = selectedBeforeSnapshot,
              let beforeId = before.id,
              let after = selectedAfterSnapshot,
              let afterId = after.id else {
            deltas = []
            return
        }

        print("[DEBUG] Comparing snapshots: beforeId=\(beforeId), afterId=\(afterId)")

        do {
            deltas = try await deltaService.compare(beforeId: beforeId, afterId: afterId)
            print("[DEBUG] Comparison successful: \(deltas.count) deltas")
        } catch {
            let errorMsg = "Failed to compare snapshots: \(error.localizedDescription)"
            print("[ERROR] \(errorMsg)")
            print("[ERROR] Full error: \(error)")
            errorMessage = errorMsg
            deltas = []
        }
    }

    /// Automatically selects the two most recent snapshots for comparison
    func autoSelectSnapshots() {
        // Snapshots are already sorted newest first
        guard snapshots.count >= 2 else {
            selectedBeforeSnapshot = nil
            selectedAfterSnapshot = nil
            return
        }

        // Most recent is "after", second most recent is "before"
        selectedAfterSnapshot = snapshots[0]
        selectedBeforeSnapshot = snapshots[1]
    }

    /// Clears any displayed error message
    func dismissError() {
        errorMessage = nil
    }

    /// Refreshes the snapshot list while preserving current selections
    /// After reloading, attempts to restore the previously selected snapshots by ID,
    /// then triggers a comparison if both selections are still valid.
    func refreshSnapshots() async {
        // Preserve current selection IDs
        let beforeId = selectedBeforeSnapshot?.id
        let afterId = selectedAfterSnapshot?.id

        // Reload snapshots
        await loadSnapshots()

        // Restore selections by finding snapshots with matching IDs
        selectedBeforeSnapshot = snapshots.first { $0.id == beforeId }
        selectedAfterSnapshot = snapshots.first { $0.id == afterId }

        // If we have valid selections, trigger comparison
        if selectedBeforeSnapshot != nil && selectedAfterSnapshot != nil {
            await compareSnapshots()
        }
    }

    #if DEBUG
    /// Generates test data in the PrunrTest folder for development testing
    /// Creates folders and files with changing sizes to demonstrate delta tracking
    func generateTestData() async {
        let testPath = testFolderPath
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

            // Create some test files with varying sizes
            // Delete old files first if they exist
            let oldFiles = ["old_folder.txt", "changed_file.txt", "stable_file.txt"]
            for file in oldFiles {
                let filePath = (testPath as NSString).appendingPathComponent(file)
                try? fileManager.removeItem(atPath: filePath)
            }

            // Delete old "shrunk" folder
            try? fileManager.removeItem(atPath: (testPath as NSString).appendingPathComponent("shrunk_folder"))

            // Create fresh test data
            try writeData(Data(repeating: 0xAA, count: 1_000_000), to: "stable_file.txt")      // 1 MB - stays same
            try writeData(Data(repeating: 0xBB, count: 2_000_000), to: "changed_file.txt")     // 2 MB - will change
            try writeData(Data(repeating: 0xCC, count: 500_000), to: "new_file.txt")          // 0.5 MB - new

            // Create a folder with files
            let folderPath = (testPath as NSString).appendingPathComponent("test_folder")
            try fileManager.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
            try Data(repeating: 0xDD, count: 3_000_000).write(to: URL(fileURLWithPath: folderPath).appendingPathComponent("large.bin"))

            errorMessage = nil
            print("[DEBUG] Test data generated successfully")
        } catch {
            errorMessage = "Failed to generate test data: \(error.localizedDescription)"
            print("[ERROR] \(errorMessage)")
        }
    }
    #endif
}
