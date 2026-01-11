import Foundation

/// Actor that manages baseline snapshots and growth list calculations.
///
/// BaselineService provides a "single baseline" design for MVP. It stores
/// one baseline snapshot ID in UserDefaults and provides growth list
/// calculations with intelligent drill-down that stops at generated content boundaries.
actor BaselineService {

    // MARK: - Types

    /// Errors specific to baseline operations
    enum BaselineError: Error, LocalizedError {
        case noBaseline

        var errorDescription: String? {
            switch self {
            case .noBaseline:
                return "No baseline has been created yet"
            }
        }
    }

    /// An item in the growth list representing a path that grew since baseline
    struct GrowthItem: Identifiable, Sendable {
        let id = UUID()
        let path: String
        let growthBytes: Int64
        let currentSizeBytes: Int64
        let percentOfParent: Double
    }

    // MARK: - Properties

    /// Shared singleton instance
    static let shared = BaselineService()

    /// Database manager reference
    private let db = DatabaseManager.shared

    /// Scan service reference
    private let scanService = ScanService.shared

    /// Boundary configuration for stopping drill-down
    private let boundaryConfig = BoundaryConfig.default

    /// UserDefaults key for storing baseline snapshot ID
    private let baselineIdKey = "baselineSnapshotId"

    /// MainActor-isolated property for UI state
    @MainActor var isCreatingBaseline = false

    private init() {}

    // MARK: - Baseline Lifecycle

    /// Creates a new baseline snapshot for the given tracked path.
    ///
    /// - Parameter trackedPath: The TrackedPath to create a baseline for
    /// - Returns: The created Snapshot
    /// - Throws: ScanError if scanning fails
    func createBaseline(trackedPath: TrackedPath) async throws -> Snapshot {
        // Set UI state
        await MainActor.run {
            isCreatingBaseline = true
        }

        defer {
            Task { @MainActor in
                isCreatingBaseline = false
            }
        }

        // Run full scan
        let snapshot = try await scanService.scan(
            path: trackedPath.url.path,
            trackedPathId: trackedPath.id,
            progress: nil
        )

        // Store snapshot ID in UserDefaults
        guard let snapshotId = snapshot.id else {
            throw ScanError.unknown(NSError(
                domain: "BaselineService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create snapshot with ID"]
            ))
        }

        UserDefaults.standard.set(snapshotId, forKey: baselineIdKey)
        print("[BaselineService] Created baseline snapshot ID: \(snapshotId)")

        return snapshot
    }

    /// Returns the current baseline snapshot.
    ///
    /// - Returns: The current baseline Snapshot
    /// - Throws: BaselineError.noBaseline if no baseline has been created
    func getCurrentBaseline() async throws -> Snapshot {
        guard let baselineId = getCurrentBaselineId(),
              baselineId > 0 else {
            throw BaselineError.noBaseline
        }

        // Fetch the snapshot by ID - need to query database
        guard let dbPool = db.dbPool else {
            throw DatabaseManager.DatabaseError.notInitialized
        }

        return try await dbPool.read { db in
            guard let snapshot = try Snapshot.fetchOne(db, key: baselineId) else {
                throw BaselineError.noBaseline
            }
            return snapshot
        }
    }

    /// Resets the baseline, clearing UserDefaults and deleting the snapshot.
    ///
    /// - Throws: DatabaseError if database operation fails
    func resetBaseline() async throws {
        guard let baselineId = getCurrentBaselineId(), baselineId > 0 else {
            return // Nothing to reset
        }

        // Delete from database
        try await db.deleteSnapshot(id: baselineId)

        // Clear UserDefaults
        UserDefaults.standard.removeObject(forKey: baselineIdKey)

        print("[BaselineService] Reset baseline snapshot ID: \(baselineId)")
    }

    /// Checks whether a baseline has been created.
    ///
    /// - Returns: `true` if a baseline exists
    func hasBaseline() -> Bool {
        guard let baselineId = getCurrentBaselineId() else {
            return false
        }
        return baselineId > 0
    }

    // MARK: - Growth List

    /// Calculates the growth list since the baseline snapshot.
    ///
    /// This method:
    /// 1. Creates a new "current" snapshot via scanning
    /// 2. Calculates deltas between baseline and current
    /// 3. Filters items that grew (changeBytes > 0)
    /// 4. Applies 70% threshold for meaningful growth
    /// 5. Returns sorted by growthBytes descending
    ///
    /// - Parameter trackedPath: The TrackedPath to scan
    /// - Returns: Array of GrowthItem sorted by growthBytes descending
    /// - Throws: BaselineError.noBaseline if no baseline exists, or ScanError if scanning fails
    func getGrowthList(trackedPath: TrackedPath) async throws -> [GrowthItem] {
        guard let baselineId = getCurrentBaselineId(), baselineId > 0 else {
            throw BaselineError.noBaseline
        }

        // Create current snapshot
        let currentSnapshot = try await scanService.scan(
            path: trackedPath.url.path,
            trackedPathId: trackedPath.id,
            progress: nil
        )

        guard let currentId = currentSnapshot.id else {
            throw ScanError.unknown(NSError(
                domain: "BaselineService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create current snapshot"]
            ))
        }

        // Calculate deltas
        let deltas = try await db.calculateDeltas(beforeId: baselineId, afterId: currentId)

        // Build growth list with 70% threshold
        let growthItems = buildGrowthList(from: deltas, parentPath: trackedPath.url.path)

        // Sort by growthBytes descending
        return growthItems.sorted { $0.growthBytes > $1.growthBytes }
    }

    /// Drills down into a specific path to find growth contributors.
    ///
    /// Uses the same logic as getGrowthList but filtered to children
    /// of the given path. Stops at boundary folders to avoid wasting
    /// resources on generated content.
    ///
    /// - Parameters:
    ///   - path: The path to drill down into
    ///   - trackedPath: The TrackedPath context
    /// - Returns: Array of GrowthItem sorted by growthBytes descending
    /// - Throws: BaselineError.noBaseline if no baseline exists, or ScanError if scanning fails
    func drillDown(path: String, trackedPath: TrackedPath) async throws -> [GrowthItem] {
        guard let baselineId = getCurrentBaselineId(), baselineId > 0 else {
            throw BaselineError.noBaseline
        }

        // Check if this is a boundary folder - stop drill-down
        let url = URL(fileURLWithPath: path)
        if boundaryConfig.shouldStopDrillDown(at: url) {
            print("[BaselineService] Stopping drill-down at boundary: \(path)")
            return []
        }

        // Create current snapshot
        let currentSnapshot = try await scanService.scan(
            path: trackedPath.url.path,
            trackedPathId: trackedPath.id,
            progress: nil
        )

        guard let currentId = currentSnapshot.id else {
            throw ScanError.unknown(NSError(
                domain: "BaselineService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create current snapshot"]
            ))
        }

        // Calculate deltas
        let deltas = try await db.calculateDeltas(beforeId: baselineId, afterId: currentId)

        // Filter to children of the given path
        let pathWithSlash = path.hasSuffix("/") ? path : path + "/"
        let childDeltas = deltas.filter { $0.path.hasPrefix(pathWithSlash) }

        // Build growth list for children
        let growthItems = buildGrowthList(from: childDeltas, parentPath: path)

        // Sort by growthBytes descending
        return growthItems.sorted { $0.growthBytes > $1.growthBytes }
    }

    // MARK: - Private Helpers

    /// Retrieves the current baseline ID from UserDefaults.
    ///
    /// - Returns: The baseline snapshot ID, or nil if not set
    private func getCurrentBaselineId() -> Int64? {
        let id = UserDefaults.standard.integer(forKey: baselineIdKey)
        return id > 0 ? Int64(id) : nil
    }

    /// Builds a growth list from deltas with 70% threshold filtering.
    ///
    /// For each delta that grew (changeBytes > 0):
    /// - Calculates what percent of the parent's total growth this represents
    /// - Includes in result if >= 70% threshold OR if it's a top-level item
    ///
    /// - Parameters:
    ///   - deltas: Array of Delta items to process
    ///   - parentPath: The parent path for calculating percentages
    /// - Returns: Array of GrowthItem values
    private func buildGrowthList(from deltas: [Delta], parentPath: String) -> [GrowthItem] {
        // Filter to only items that grew
        let growingDeltas = deltas.filter { $0.changeBytes > 0 }

        // Calculate total growth for the parent
        let totalGrowth = growingDeltas.reduce(Int64(0)) { $0 + $1.changeBytes }

        guard totalGrowth > 0 else {
            return []
        }

        // Build growth items with 70% threshold
        let threshold = 0.70 // 70%
        var items: [GrowthItem] = []

        for delta in growingDeltas {
            // Calculate what percent of parent growth this represents
            let percentOfParent = Double(delta.changeBytes) / Double(totalGrowth)

            // Include if >= 70% threshold or if it's a direct child of parent
            let isDirectChild = isDirectChild(delta.path, of: parentPath)
            let meetsThreshold = percentOfParent >= threshold

            if meetsThreshold || isDirectChild {
                let currentSize = delta.newSizeBytes ?? 0
                let item = GrowthItem(
                    path: delta.path,
                    growthBytes: delta.changeBytes,
                    currentSizeBytes: currentSize,
                    percentOfParent: percentOfParent
                )
                items.append(item)
            }
        }

        return items
    }

    /// Checks if a path is a direct child of the parent path.
    ///
    /// - Parameters:
    ///   - path: The path to check
    ///   - parent: The parent path
    /// - Returns: `true` if path is a direct child (not nested deeper)
    private func isDirectChild(_ path: String, of parent: String) -> Bool {
        let parentWithSlash = parent.hasSuffix("/") ? parent : parent + "/"

        // Check if path is under parent
        guard path.hasPrefix(parentWithSlash) else {
            return false
        }

        // Get the relative path after parent
        let relativePath = String(path.dropFirst(parentWithSlash.count))

        // Check if there are no additional path separators (direct child)
        return !relativePath.contains("/")
    }
}
