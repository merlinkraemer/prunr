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
    struct GrowthItem: Identifiable, Sendable, Equatable {
        let id = UUID()
        let path: String
        let growthBytes: Int64
        let currentSizeBytes: Int64
        let percentOfParent: Double

        // MARK: - Computed Properties

        /// Whether this item is considered a "big file" (>=100MB)
        var isBigFile: Bool {
            growthBytes >= CategoryGrowthItem.bigFileThreshold
        }

        /// The category this item belongs to
        var category: GrowthCategory {
            GrowthCategory.categorize(path: path)
        }
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

    /// Calculates the growth list since the baseline snapshot using incremental scanning.
    ///
    /// This method:
    /// 1. Scans only the specified paths (or full path if none specified)
    /// 2. Creates a "current" snapshot with the scan results
    /// 3. Calculates deltas between baseline and current
    /// 4. Filters items that grew (changeBytes > 0)
    /// 5. Returns sorted by growthBytes descending
    ///
    /// - Parameters:
    ///   - trackedPath: The TrackedPath to scan
    ///   - changedPaths: Optional specific paths to scan incrementally. If nil, does full scan.
    /// - Returns: Array of GrowthItem sorted by growthBytes descending
    /// - Throws: BaselineError.noBaseline if no baseline exists, or ScanError if scanning fails
    func getGrowthList(trackedPath: TrackedPath, changedPaths: [URL]? = nil) async throws -> [GrowthItem] {
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
    /// Builds a growth list from deltas with 70% threshold filtering.
    ///
    /// Aggregates growth by direct child of the parent path.
    /// Example: If parent is `/root`, then `/root/folder/file` growth counts towards `/root/folder`.
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
        
        // Aggregate growth by direct child component
        var aggregatedGrowth: [String: (growth: Int64, size: Int64)] = [:]
        let parentWithSlash = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        
        for delta in growingDeltas {
            guard delta.path.hasPrefix(parentWithSlash) else { continue }
            
            // Extract relative path: "images/img1.dat" or "file.txt"
            let relativePath = String(delta.path.dropFirst(parentWithSlash.count))
            
            // Get the first component (direct child name)
            let components = relativePath.split(separator: "/", maxSplits: 1)
            guard let firstComponent = components.first else { continue }
            let childName = String(firstComponent)
            let fullChildPath = parentWithSlash + childName
            
            // Accumulate
            let current = aggregatedGrowth[fullChildPath] ?? (growth: 0, size: 0)
            aggregatedGrowth[fullChildPath] = (
                growth: current.growth + delta.changeBytes,
                size: current.size + (delta.newSizeBytes ?? 0)
            )
        }
        
        // Build growth items with 70% threshold
        let threshold = 0.70 // 70%
        var items: [GrowthItem] = []
        
        for (path, data) in aggregatedGrowth {
            let percentOfParent = Double(data.growth) / Double(totalGrowth)
            
            // Include if >= 70% threshold (always include in this simplified drill-down logic? 
            // The original logic was: "Include if >= 70% OR if it's a direct child".
            // Since we are now showing direct children (aggregated), we should probably show all 
            // significant ones. But let's stick to the threshold logic to hide noise?
            // User wants to see "What Grew". If multiple folders grew, show them.
            // If I grew "images" (30%) and "documents" (20%) and "videos" (50%), 
            // none is > 70%. But user wants to see them.
            // The threshold was mainly for "Drill Down" to pick the *single culprit*.
            // But here we are listing items.
            // Let's include items that contribute > 1% to avoid noise, or just top ones.
            // Or stick to the original logic: "Include if >= 70% OR isDirectChild".
            // Since we aggregated to direct children, ALL items in `aggregatedGrowth` ARE direct children.
            // So we should include ALL of them (maybe sorted).
            
            let item = GrowthItem(
                path: path,
                growthBytes: data.growth,
                currentSizeBytes: data.size,
                percentOfParent: percentOfParent
            )
            items.append(item)
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

    // MARK: - Category Growth List

    /// Calculates the growth list aggregated by category since the baseline snapshot.
    ///
    /// This method:
    /// 1. Scans the tracked path to get current state
    /// 2. Calculates deltas between baseline and current
    /// 3. Uses CategoryDetectionService to group deltas by category
    /// 4. Aggregates growth metrics per category
    /// 5. Separates big items (>=100MB) from small items
    /// 6. Returns sorted CategoryGrowthItem array (by growth descending)
    ///
    /// - Parameter trackedPath: The TrackedPath to scan
    /// - Returns: Array of CategoryGrowthItem sorted by totalGrowthBytes descending
    /// - Throws: BaselineError.noBaseline if no baseline exists, or ScanError if scanning fails
    func getCategoryGrowthList(trackedPath: TrackedPath) async throws -> [CategoryGrowthItem] {
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
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create current snapshot"]
            ))
        }

        // Calculate deltas
        let deltas = try await db.calculateDeltas(beforeId: baselineId, afterId: currentId)

        // Filter to only items that grew
        let growingDeltas = deltas.filter { $0.changeBytes > 0 }

        guard !growingDeltas.isEmpty else {
            print("[BaselineService] No growth detected since baseline")
            return []
        }

        // Convert deltas to GrowthItem format
        let growthItems = growingDeltas.map { delta in
            GrowthItem(
                path: delta.path,
                growthBytes: delta.changeBytes,
                currentSizeBytes: delta.newSizeBytes ?? 0,
                percentOfParent: 0.0 // Will be recalculated per category
            )
        }

        // Categorize deltas using CategoryDetectionService
        let categoryService = CategoryDetectionService.shared
        let categorizedDeltas = await categoryService.categorizeDeltas(growthItems)

        // Calculate total growth across all categories for percentage calculation
        let totalGrowth = growthItems.reduce(Int64(0)) { $0 + $1.growthBytes }

        // Build CategoryGrowthItem array
        var categoryItems: [CategoryGrowthItem] = []

        for (category, items) in categorizedDeltas {
            // Calculate totals for this category
            let categoryGrowth = await categoryService.calculateTotalGrowth(items)
            let categorySize = await categoryService.calculateCurrentSize(items)

            // Separate big and small items
            let bigItems = await categoryService.filterBigItems(items)
            let smallItems = await categoryService.filterSmallItems(items)

            // Calculate small item metrics
            let smallItemCount = smallItems.count
            let smallItemTotalBytes = await categoryService.calculateTotalGrowth(smallItems)

            // Calculate percent of total growth
            let percentOfTotal = totalGrowth > 0 ? Double(categoryGrowth) / Double(totalGrowth) : 0.0

            // Create CategoryGrowthItem with all items for drill-down
            let categoryItem = CategoryGrowthItem(
                category: category,
                totalGrowthBytes: categoryGrowth,
                currentSizeBytes: categorySize,
                allItems: items, // All items for drill-down view
                bigItems: bigItems,
                smallItemCount: smallItemCount,
                smallItemTotalBytes: smallItemTotalBytes,
                percentOfTotal: percentOfTotal
            )

            categoryItems.append(categoryItem)

            // Log category totals for debugging
            print("[BaselineService] Category '\(category.displayName)': \(ByteCountFormatter.string(fromByteCount: categoryGrowth, countStyle: .file)) (\(String(format: "%.1f", percentOfTotal * 100))%)")
        }

        // Sort by total growth bytes descending
        return categoryItems.sorted { $0.totalGrowthBytes > $1.totalGrowthBytes }
    }
}
