import Foundation

/// Actor that manages snapshots and growth list calculations.
///
/// BaselineService provides a rolling comparison design. It compares
/// the latest snapshot with the previous snapshot for a given path.
actor BaselineService {

    // MARK: - Types

    /// Errors specific to baseline operations
    enum BaselineError: Error, LocalizedError {
        case noBaseline
        case insufficientSnapshots

        var errorDescription: String? {
            switch self {
            case .noBaseline:
                return "No snapshots have been created yet"
            case .insufficientSnapshots:
                return "Need at least two snapshots to compare growth"
            }
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

    /// MainActor-isolated property for UI state
    @MainActor var isCreatingBaseline = false

    private init() {}

    // MARK: - Snapshot Lifecycle

    /// Takes a new snapshot for the given tracked path.
    ///
    /// - Parameters:
    ///   - trackedPath: The TrackedPath to scan
    ///   - progress: Optional callback for scan progress updates
    /// - Returns: The created Snapshot
    /// - Throws: ScanError if scanning fails
    func createBaseline(
        trackedPath: TrackedPath,
        progress: ((ScanService.ScanProgress) -> Void)? = nil
    ) async throws -> Snapshot {
        print("[BaselineService] Starting scan for path: \(trackedPath.url.path)")

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
        print("[BaselineService] Starting scan...")
        let snapshot = try await scanService.scan(
            path: trackedPath.url.path,
            trackedPathId: trackedPath.id,
            progress: progress
        )

        guard let snapshotId = snapshot.id else {
            print("[BaselineService] ERROR: Failed to create snapshot with ID")
            throw ScanError.unknown(NSError(
                domain: "BaselineService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create snapshot with ID"]
            ))
        }

        print("[BaselineService] Created snapshot ID: \(snapshotId)")
        
        // Run cleanup in background so UI does not stall at 99%.
        Task.detached(priority: .utility) {
            await DatabaseCleanupService.shared.performAutoCleanup()
        }

        return snapshot
    }

    /// Checks whether at least one snapshot exists.
    ///
    /// - Returns: `true` if a snapshot exists
    func hasBaseline() async -> Bool {
        do {
            let snapshots = try await db.fetchAllSnapshots()
            return !snapshots.isEmpty
        } catch {
            return false
        }
    }

    /// Resets the baseline by deleting all snapshots.
    ///
    /// - Throws: DatabaseError if database operation fails
    func resetBaseline() async throws {
        let snapshots = try await db.fetchAllSnapshots()
        for snapshot in snapshots {
            if let id = snapshot.id {
                try await db.deleteSnapshot(id: id)
            }
        }
        print("[BaselineService] Reset baseline: deleted all snapshots")
    }

    // MARK: - Growth List

    /// Calculates the growth list by comparing the latest two snapshots.
    ///
    /// - Parameters:
    ///   - trackedPath: The TrackedPath to compare
    /// - Returns: Array of GrowthItem sorted by growthBytes descending
    /// - Throws: BaselineError if insufficient snapshots exist
    func getGrowthList(trackedPath: TrackedPath) async throws -> [GrowthItem] {
        let snapshots = try await db.fetchAllSnapshots(trackedPathId: trackedPath.id)
        
        guard snapshots.count >= 2 else {
            throw BaselineError.insufficientSnapshots
        }
        
        guard let currentId = snapshots[0].id,
              let previousId = snapshots[1].id else {
            throw BaselineError.noBaseline
        }

        // Calculate deltas
        let deltas = try await db.calculateDeltas(beforeId: previousId, afterId: currentId)

        // Build growth list
        let growthItems = buildGrowthList(from: deltas, parentPath: trackedPath.url.path)

        // Sort by growthBytes descending
        return growthItems.sorted { $0.growthBytes > $1.growthBytes }
    }

    /// Drills down into a specific path to find growth contributors.
    ///
    /// - Parameters:
    ///   - path: The path to drill down into
    ///   - trackedPath: The TrackedPath context
    /// - Returns: Array of GrowthItem sorted by growthBytes descending
    /// - Throws: BaselineError if insufficient snapshots exist
    func drillDown(path: String, trackedPath: TrackedPath) async throws -> [GrowthItem] {
        let snapshots = try await db.fetchAllSnapshots(trackedPathId: trackedPath.id)
        
        guard snapshots.count >= 2 else {
            throw BaselineError.insufficientSnapshots
        }
        
        guard let currentId = snapshots[0].id,
              let previousId = snapshots[1].id else {
            throw BaselineError.noBaseline
        }

        // Check if this is a boundary folder - stop drill-down
        let url = URL(fileURLWithPath: path)
        if boundaryConfig.shouldStopDrillDown(at: url) {
            print("[BaselineService] Stopping drill-down at boundary: \(path)")
            return []
        }

        // Calculate deltas
        let deltas = try await db.calculateDeltas(beforeId: previousId, afterId: currentId)

        // Filter to children of the given path
        let pathWithSlash = path.hasSuffix("/") ? path : path + "/"
        let childDeltas = deltas.filter { $0.path.hasPrefix(pathWithSlash) }

        // Build growth list for children
        let growthItems = buildGrowthList(from: childDeltas, parentPath: path)

        // Sort by growthBytes descending
        return growthItems.sorted { $0.growthBytes > $1.growthBytes }
    }

    // MARK: - Private Helpers

    /// Builds a growth list from deltas.
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
        
        var items: [GrowthItem] = []
        
        for (path, data) in aggregatedGrowth {
            let percentOfParent = Double(data.growth) / Double(totalGrowth)
            
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

    // MARK: - Category Growth List

    /// Calculates the growth list aggregated by category by comparing the latest two snapshots.
    ///
    /// - Parameters:
    ///   - trackedPath: The TrackedPath to compare
    /// - Returns: Array of CategoryGrowthItem sorted by totalGrowthBytes descending
    /// - Throws: BaselineError if insufficient snapshots exist
    func getCategoryGrowthList(trackedPath: TrackedPath) async throws -> [CategoryGrowthItem] {
        let start = Date()
        let snapshots = try await db.fetchAllSnapshots(trackedPathId: trackedPath.id)
        
        guard snapshots.count >= 2 else {
            throw BaselineError.insufficientSnapshots
        }
        
        guard let currentId = snapshots[0].id,
              let previousId = snapshots[1].id else {
            throw BaselineError.noBaseline
        }

        // Calculate deltas
        let deltas = try await db.calculateDeltas(beforeId: previousId, afterId: currentId)
        try Task.checkCancellation()

        // Filter to only items that grew
        let growingDeltas = deltas.filter { $0.changeBytes > 0 }

        guard !growingDeltas.isEmpty else {
            print("[BaselineService] No growth detected since previous scan")
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
        try Task.checkCancellation()

        // Calculate total growth across all categories for percentage calculation
        let totalGrowth = growthItems.reduce(Int64(0)) { $0 + $1.growthBytes }

        // Build CategoryGrowthItem array
        var categoryItems: [CategoryGrowthItem] = []

        for (category, items) in categorizedDeltas {
            try Task.checkCancellation()

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

        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        print("[BaselineService] getCategoryGrowthList completed in \(elapsedMs)ms")

        // Sort by total growth bytes descending
        return categoryItems.sorted { $0.totalGrowthBytes > $1.totalGrowthBytes }
    }
}
