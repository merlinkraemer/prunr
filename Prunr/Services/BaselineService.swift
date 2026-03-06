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

    private let maxCategoryDrilldownItems = 3000
    private let maxCategoryBigItems = 500
    // Initial files loaded per subcategory (user can load more)
    private let initialSubcategoryFileLimit = SubcategoryGroup.initialLoadLimit
    // Maximum files per subcategory to prevent memory issues
    private let maxSubcategoryFiles = SubcategoryGroup.maxLoadableFiles

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

        // Validate previous snapshot has entries (avoid comparing to empty/incomplete snapshot)
        let previousEntryCount = try await db.fetchEntryCount(for: previousId)
        let currentEntryCount = try await db.fetchEntryCount(for: currentId)

        print("[BaselineService] Snapshot entry counts: previous=\(previousEntryCount), current=\(currentEntryCount)")

        guard previousEntryCount > 100 else {
            print("[BaselineService] Previous snapshot has only \(previousEntryCount) entries - treating as first scan")
            throw BaselineError.insufficientSnapshots
        }

        // If current has way more entries than previous, previous was likely incomplete
        // Allow up to 50% growth as reasonable, otherwise treat as first scan
        let minExpectedPrevious = currentEntryCount / 2
        if previousEntryCount < minExpectedPrevious {
            print("[BaselineService] Previous snapshot (\(previousEntryCount) entries) too small compared to current (\(currentEntryCount)) - treating as first scan")
            throw BaselineError.insufficientSnapshots
        }

        // Calculate deltas
        let deltas = try await db.calculateDeltas(beforeId: previousId, afterId: currentId)
        try Task.checkCancellation()

        print("[BaselineService] Calculated \(deltas.count) deltas")

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

            // Keep drill-down payload bounded to avoid UI memory blowups on huge categories
            let sortedByGrowth = items.sorted { $0.growthBytes > $1.growthBytes }
            let drilldownItems = Array(sortedByGrowth.prefix(maxCategoryDrilldownItems))
            let cappedBigItems = Array(bigItems.sorted { $0.growthBytes > $1.growthBytes }.prefix(maxCategoryBigItems))

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
                allItems: drilldownItems,
                bigItems: cappedBigItems,
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

    // MARK: - Reconciliation

    /// Calculates disk accounting data that ties together free-space tracking with scan coverage.
    ///
    /// - Parameter trackedPath: The TrackedPath to analyze
    /// - Returns: DiskAccountingResult with free-space tracking data
    /// - Throws: BaselineError if insufficient snapshots exist
    func getDiskAccounting(trackedPath: TrackedPath) async throws -> DiskAccountingResult {
        let snapshots = try await db.fetchAllSnapshots(trackedPathId: trackedPath.id)

        guard snapshots.count >= 2 else {
            throw BaselineError.insufficientSnapshots
        }

        let currentSnapshot = snapshots[0]
        let previousSnapshot = snapshots[1]

        guard let currentId = currentSnapshot.id,
              let previousId = previousSnapshot.id else {
            throw BaselineError.noBaseline
        }

        let previousTotals = try await db.fetchCategoryTotals(for: previousId)
        let currentTotals = try await db.fetchCategoryTotals(for: currentId)

        let previousBytesByCategory = Dictionary(
            uniqueKeysWithValues: previousTotals.map { ($0.category, $0.currentSizeBytes) }
        )
        let currentBytesByCategory = Dictionary(
            uniqueKeysWithValues: currentTotals.map { ($0.category, $0.currentSizeBytes) }
        )

        let netFileChange = GrowthCategory.allCases.reduce(Int64(0)) { partial, category in
            let previousBytes = previousBytesByCategory[category] ?? 0
            let currentBytes = currentBytesByCategory[category] ?? 0
            return partial + (currentBytes - previousBytes)
        }

        // Calculate free space delta
        let previousFreeSpace = previousSnapshot.freeBytes
        let currentFreeSpace = currentSnapshot.freeBytes

        let freeSpaceDelta: Int64?
        let unexplainedDelta: Int64?

        if let prev = previousFreeSpace, let curr = currentFreeSpace {
            // Both snapshots have freeBytes - compute delta
            let delta = curr - prev  // Positive = space freed, negative = space consumed
            freeSpaceDelta = delta

            // Calculate unexplained delta
            // If scanning is perfect: freeSpaceDelta ≈ -netFileChange
            // (files growing = free space shrinking)
            // Discrepancy = abs(freeSpaceDelta + netFileChange)
            unexplainedDelta = abs(delta + netFileChange)
            print("[BaselineService] Reconciliation: prevFree=\(prev), currFree=\(curr), freeSpaceDelta=\(delta), netFileChange=\(netFileChange), unexplained=\(unexplainedDelta ?? 0)")
        } else {
            // Legacy snapshots without freeBytes - graceful degradation
            freeSpaceDelta = nil
            unexplainedDelta = nil
            print("[BaselineService] Reconciliation: missing freeBytes (prev=\(previousFreeSpace ?? -1), curr=\(currentFreeSpace ?? -1))")
        }

        // Note: explainedDelta is now the net file change (can be negative for net shrinkage)
        return DiskAccountingResult(
            freeSpaceDelta: freeSpaceDelta,
            previousFreeSpace: previousFreeSpace,
            currentFreeSpace: currentFreeSpace,
            explainedDelta: netFileChange,
            unexplainedDelta: unexplainedDelta
        )
    }

    // MARK: - Category Inventory & Growth Trend Detection

    /// Gets the current category inventory for a tracked path
    /// - Parameter trackedPath: The tracked path to get inventory for
    /// - Returns: Array of CategoryInventoryItem sorted by currentSizeBytes descending
    func getCategoryInventory(trackedPath: TrackedPath) async -> [CategoryInventoryItem] {
        do {
            // Get the latest snapshot for this trackedPath
            let snapshots = try await db.fetchAllSnapshots(trackedPathId: trackedPath.id)
            guard let latestSnapshot = snapshots.first,
                  let snapshotId = latestSnapshot.id else {
                return []
            }

            let precomputedTotals = try await db.fetchCategoryTotals(for: snapshotId)
            if !precomputedTotals.isEmpty {
                return precomputedTotals
            }

            // Query snapshotEntry for that snapshot, JOIN paths to get path strings
            let entries = try await db.fetchEntries(for: snapshotId)

            // Aggregate into Dictionary<GrowthCategory, Int64>
            var categoryTotals: [GrowthCategory: Int64] = [:]

            for entry in entries {
                let category = GrowthCategory.categorize(path: entry.path)
                categoryTotals[category, default: 0] += entry.sizeBytes
            }

            // Return as [CategoryInventoryItem] sorted by totalBytes descending
            let items = categoryTotals.map { category, totalBytes in
                CategoryInventoryItem(
                    category: category,
                    currentSizeBytes: totalBytes,
                    growthTrend: nil
                )
            }.sorted { $0.currentSizeBytes > $1.currentSizeBytes }

            return items
        } catch {
            print("[BaselineService] Error getting category inventory: \(error)")
            return []
        }
    }

    func getSubcategoryBreakdown(for category: GrowthCategory, snapshotId: Int64) async -> [SubcategoryGroup] {
        do {
            let precomputedGroups = try await db.fetchSubcategoryGroups(for: snapshotId, category: category)
            if !precomputedGroups.isEmpty {
                return precomputedGroups
            }

            struct SubcategoryAccumulator {
                var totalBytes: Int64 = 0
                var fileCount: Int = 0
                var topEntries: [SnapshotEntryWithPath] = []
                let limit: Int

                mutating func add(_ entry: SnapshotEntryWithPath) {
                    totalBytes += entry.sizeBytes
                    fileCount += 1

                    guard limit > 0 else { return }

                    if topEntries.count < limit {
                        topEntries.append(entry)
                        return
                    }

                    guard let smallestIndex = topEntries.indices.min(by: {
                        topEntries[$0].sizeBytes < topEntries[$1].sizeBytes
                    }) else { return }
                    guard entry.sizeBytes > topEntries[smallestIndex].sizeBytes else { return }
                    topEntries[smallestIndex] = entry
                }
            }

            var grouped: [GrowthSubcategory?: SubcategoryAccumulator] = [:]
            let pageSize = 5_000
            var offset = 0

            while true {
                if Task.isCancelled {
                    return []
                }

                let entries = try await db.fetchEntriesPaginatedUnordered(for: snapshotId, offset: offset, limit: pageSize)
                guard !entries.isEmpty else { break }

                for entry in entries {
                    if Task.isCancelled {
                        return []
                    }

                    guard GrowthCategory.categorize(path: entry.path) == category else { continue }
                    let subcategory = GrowthSubcategory.subcategorize(path: entry.path)

                    grouped[subcategory, default: SubcategoryAccumulator(limit: initialSubcategoryFileLimit)].add(entry)
                }

                offset += entries.count
            }

            let groups = grouped.map { subcategory, accumulator -> SubcategoryGroup in
                let displayName: String
                if let subcategory {
                    displayName = subcategory.displayName
                } else {
                    displayName = category.supportsSubcategories ? "Uncategorized" : "Files"
                }

                let totalBytes = accumulator.totalBytes
                let sortedTopEntries = accumulator.topEntries.sorted { $0.sizeBytes > $1.sizeBytes }
                let topFiles = sortedTopEntries.map { entry in
                    let percent = totalBytes > 0
                        ? Double(entry.sizeBytes) / Double(totalBytes)
                        : 0

                    return GrowthItem(
                        path: entry.path,
                        growthBytes: entry.sizeBytes,
                        currentSizeBytes: entry.sizeBytes,
                        percentOfParent: percent,
                        subcategory: subcategory
                    )
                }

                return SubcategoryGroup(
                    subcategory: subcategory,
                    displayName: displayName,
                    totalBytes: totalBytes,
                    fileCount: accumulator.fileCount,
                    topFiles: topFiles
                )
            }

            return groups.sorted { $0.totalBytes > $1.totalBytes }
        } catch {
            print("[BaselineService] Error getting subcategory breakdown for \(category.rawValue): \(error)")
            return []
        }
    }

    /// Loads additional files for a specific subcategory with pagination.
    /// Used for "Load More" functionality to avoid loading all files at once.
    ///
    /// - Parameters:
    ///   - category: The parent category
    ///   - subcategory: The subcategory to load files for (nil for uncategorized)
    ///   - snapshotId: The snapshot ID
    ///   - totalBytes: Total bytes for the subcategory (used for percent calculation)
    ///   - offset: Number of files to skip (already loaded)
    ///   - limit: Maximum files to load
    /// - Returns: Array of GrowthItem for the additional files
    func loadMoreSubcategoryFiles(
        for category: GrowthCategory,
        subcategory: GrowthSubcategory?,
        snapshotId: Int64,
        totalBytes: Int64,
        offset: Int,
        limit: Int = SubcategoryGroup.loadMoreBatchSize
    ) async -> [GrowthItem] {
        do {
            var results: [GrowthItem] = []
            var skipped = 0
            var globalOffset = 0
            let pageSize = 5_000

            while results.count < limit {
                if Task.isCancelled {
                    return []
                }

                let entries = try await db.fetchEntriesPaginated(for: snapshotId, offset: globalOffset, limit: pageSize)
                guard !entries.isEmpty else { break }

                for entry in entries {
                    if Task.isCancelled {
                        return []
                    }

                    guard GrowthCategory.categorize(path: entry.path) == category else { continue }
                    guard GrowthSubcategory.subcategorize(path: entry.path) == subcategory else { continue }

                    if skipped < offset {
                        skipped += 1
                        continue
                    }

                    let percent = totalBytes > 0
                        ? Double(entry.sizeBytes) / Double(totalBytes)
                        : 0

                    results.append(GrowthItem(
                        path: entry.path,
                        growthBytes: entry.sizeBytes,
                        currentSizeBytes: entry.sizeBytes,
                        percentOfParent: percent,
                        subcategory: subcategory
                    ))

                    if results.count >= limit {
                        break
                    }
                }

                globalOffset += entries.count
            }

            return results
        } catch {
            print("[BaselineService] Error loading more files for subcategory: \(error)")
            return []
        }
    }

    /// Detects growth trends by comparing current totals with historical data
    /// - Parameter trackedPath: The tracked path to analyze
    /// - Returns: Array of CategoryGrowthTrend with growth information
    func detectGrowthTrends(trackedPath: TrackedPath) async -> [CategoryGrowthTrend: GrowthCategory] {
        let trackedPathIdString = trackedPath.id.uuidString

        // Fetch categorySnapshot history
        let history = db.fetchCategorySnapshots(trackedPathId: trackedPathIdString, limit: 90)

        guard history.count >= 2 else {
            // Not enough data for trend detection
            return [:]
        }

        // Group by category
        var categoryHistory: [GrowthCategory: [(snapshotId: Int64, createdAt: Date, totalBytes: Int64)]] = [:]

        for row in history {
            if let category = GrowthCategory(rawValue: row.category) {
                categoryHistory[category, default: []].append((
                    snapshotId: row.snapshotId,
                    createdAt: row.createdAt,
                    totalBytes: row.totalBytes
                ))
            }
        }

        var trends: [CategoryGrowthTrend: GrowthCategory] = [:]
        let significanceThreshold: Int64 = 50 * 1024 * 1024 // 50MB threshold

        for (category, timeSeries) in categoryHistory {
            // Sort by date ascending for trend analysis
            let sorted = timeSeries.sorted { $0.createdAt < $1.createdAt }

            guard sorted.count >= 2 else { continue }

            let mostRecent = sorted.last!
            let oldest = sorted.first!

            // Calculate growth from oldest to most recent
            let totalGrowth = mostRecent.totalBytes - oldest.totalBytes

            // Only consider significant growth (> 50MB)
            guard totalGrowth > significanceThreshold else { continue }

            // Find growth start: walk backwards through the time series
            // to find when the sustained increase began
            // Simple heuristic: find the minimum totalBytes in the window,
            // then find the first snapshot after that minimum
            let minBytes = sorted.map { $0.totalBytes }.min() ?? oldest.totalBytes

            // Find the first snapshot after the minimum that starts the growth trend
            var growthStartedAt = oldest.createdAt
            var foundMin = false

            for point in sorted {
                if !foundMin {
                    if point.totalBytes <= minBytes + (significanceThreshold / 10) {
                        foundMin = true
                    }
                } else {
                    // After finding min, look for first significant increase
                    if point.totalBytes > minBytes + (significanceThreshold / 10) {
                        growthStartedAt = point.createdAt
                        break
                    }
                }
            }

            // Calculate growth span in days
            let growthSpanDays = Calendar.current.dateComponents(
                [.day],
                from: growthStartedAt,
                to: mostRecent.createdAt
            ).day ?? 0

            // Create trend
            let trend = CategoryGrowthTrend(
                growthBytes: mostRecent.totalBytes - minBytes,
                growthStartedAt: growthStartedAt,
                growthSpanDays: max(1, growthSpanDays) // At least 1 day
            )

            // We need a different structure - let's use a simple approach
            // Since we can't easily return a dictionary with complex keys,
            // we'll return this in a different format in getInventoryWithTrends
        }

        return trends
    }

    /// Gets inventory with growth trends merged
    /// - Parameter trackedPath: The tracked path to analyze
    /// - Returns: Array of CategoryInventoryItem with growth trends attached where applicable
    func getInventoryWithTrends(trackedPath: TrackedPath) async -> [CategoryInventoryItem] {
        // 1. Get current inventory
        var inventory = await getCategoryInventory(trackedPath: trackedPath)

        // 2. Detect growth trends
        let trackedPathIdString = trackedPath.id.uuidString
        let history = db.fetchCategorySnapshots(trackedPathId: trackedPathIdString, limit: 90)

        guard history.count >= 2 else {
            // Not enough history data, return inventory without trends
            return inventory
        }

        // Group by category for trend analysis
        var categoryHistory: [GrowthCategory: [(snapshotId: Int64, createdAt: Date, totalBytes: Int64)]] = [:]

        for row in history {
            if let category = GrowthCategory(rawValue: row.category) {
                categoryHistory[category, default: []].append((
                    snapshotId: row.snapshotId,
                    createdAt: row.createdAt,
                    totalBytes: row.totalBytes
                ))
            }
        }

        let significanceThreshold: Int64 = 50 * 1024 * 1024 // 50MB threshold

        // 3. Merge trends into inventory
        for i in 0..<inventory.count {
            let category = inventory[i].category

            guard let sorted = categoryHistory[category]?.sorted(by: { $0.createdAt < $1.createdAt }),
                  sorted.count >= 2 else { continue }

            if let trend = buildInventoryTrend(from: sorted, significanceThreshold: significanceThreshold) {
                inventory[i].growthTrend = trend
            }
        }

        return inventory
    }

    private func buildInventoryTrend(
        from history: [(snapshotId: Int64, createdAt: Date, totalBytes: Int64)],
        significanceThreshold: Int64
    ) -> CategoryGrowthTrend? {
        guard history.count >= 2 else { return nil }

        // Ignore the initial jump from "missing/zero" to the first real snapshot.
        // That reads like "grew from 0" in the UI even when nothing recently changed.
        let appearanceThreshold = significanceThreshold / 2
        let trimmedHistory: ArraySlice<(snapshotId: Int64, createdAt: Date, totalBytes: Int64)>
        if let firstMeaningfulIndex = history.firstIndex(where: { $0.totalBytes > appearanceThreshold }) {
            trimmedHistory = history[firstMeaningfulIndex...]
        } else {
            trimmedHistory = history[history.startIndex...]
        }

        guard trimmedHistory.count >= 2,
              let oldest = trimmedHistory.first,
              let mostRecent = trimmedHistory.last else {
            return nil
        }

        let totalGrowth = mostRecent.totalBytes - oldest.totalBytes
        guard totalGrowth > significanceThreshold else {
            return nil
        }

        let minBytes = trimmedHistory.map(\.totalBytes).min() ?? oldest.totalBytes
        let tolerance = significanceThreshold / 10

        var growthStartedAt = oldest.createdAt
        var foundMinimum = false

        for point in trimmedHistory {
            if !foundMinimum {
                if point.totalBytes <= minBytes + tolerance {
                    foundMinimum = true
                }
            } else if point.totalBytes > minBytes + tolerance {
                growthStartedAt = point.createdAt
                break
            }
        }

        let growthSpanDays = Calendar.current.dateComponents(
            [.day],
            from: growthStartedAt,
            to: mostRecent.createdAt
        ).day ?? 0

        return CategoryGrowthTrend(
            growthBytes: mostRecent.totalBytes - minBytes,
            growthStartedAt: growthStartedAt,
            growthSpanDays: max(1, growthSpanDays)
        )
    }
}
