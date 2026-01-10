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

        isScanning = true
        scanProgress = "Starting scan..."
        errorMessage = nil

        do {
            _ = try await scanService.scan(path: path) { [weak self] progress in
                Task { @MainActor in
                    self?.scanProgress = progress.currentPath
                }
            }

            // Reload snapshots after successful scan
            await loadSnapshots()
            autoSelectSnapshots()

        } catch {
            errorMessage = "Scan failed: \(error.localizedDescription)"
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

        do {
            deltas = try await deltaService.compare(beforeId: beforeId, afterId: afterId)
        } catch {
            errorMessage = "Failed to compare snapshots: \(error.localizedDescription)"
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
}
