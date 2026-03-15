import Foundation

/// Actor that manages snapshots and growth list calculations.
///
/// BaselineService provides a rolling comparison design. It compares
/// the latest snapshot with the previous snapshot for a given path.
actor BaselineService {

    struct GrowthComparisonSnapshots: Sendable, Equatable {
        let currentSnapshotId: Int64
        let baselineSnapshotId: Int64?
    }

    struct InventoryAggregationResult: Sendable, Equatable {
        let inventory: [CategoryInventoryItem]
        let latestSnapshotIdsByPath: [UUID: Int64]
        let baselineSnapshotIdsByPath: [UUID: Int64]
        let latestSnapshotDate: Date?
    }

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
    private let growthJournalService = GrowthJournalService.shared

    /// Boundary configuration for stopping drill-down
    private let boundaryConfig = BoundaryConfig.default

    private let maxCategoryDrilldownItems = 3000
    private let maxCategoryBigItems = 500
    // Initial files loaded per subcategory (user can load more)
    private let initialSubcategoryFileLimit = SubcategoryGroup.initialLoadLimit

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
        ignoredNames: Set<String>? = nil,
        progress: ((ScanService.ScanProgress) -> Void)? = nil
    ) async throws -> Snapshot {
        // Get previous snapshot for delta calculation
        let previousSnapshots = try await db.fetchRecentSnapshots(trackedPathId: trackedPath.id, limit: 1)
        let previousSnapshotId = previousSnapshots.first?.id

        if previousSnapshotId == nil {
            try await db.clearRealtimeData(trackedPathId: trackedPath.id)
        } else {
            // Pre-clear working-set entries so the inline upserts during the scan
            // don't accumulate stale rows from the previous scan's working set.
            try await db.clearWorkingSetEntries(trackedPathId: trackedPath.id)
        }

        // Set UI state
        await MainActor.run {
            isCreatingBaseline = true
        }

        defer {
            Task { @MainActor in
                isCreatingBaseline = false
            }
        }

        // Run full scan.
        // Pass alsoWriteWorkingSet=true so working-set rows are written inline during
        // the scan transaction — this eliminates the separate rebuildWorkingSet pass
        // that previously copied 2.2M rows after the scan completed.
        let snapshot = try await scanService.scan(
            path: trackedPath.url.path,
            trackedPathId: trackedPath.id,
            ignoredNames: ignoredNames,
            alsoWriteWorkingSet: true,
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

        // Record deltas to growth journal only when a previous snapshot exists.
        // On first scan (previousSnapshotId == nil) this block is skipped entirely —
        // no calculateDeltas call and no journal recording, so first-scan cost is
        // scan + insert only, with no expensive diff computation.
        if let previousSnapshotId {
            let deltas = try await db.calculateDeltas(beforeId: previousSnapshotId, afterId: snapshotId)
            if !deltas.isEmpty {
                var deltasByKey: [DatabaseManager.JournalDeltaKey: Int64] = [:]
                for delta in deltas {
                    let category = GrowthCategory.categorize(path: delta.path)
                    let subcategory = GrowthCategory.subcategorize(path: delta.path)
                    let key = DatabaseManager.JournalDeltaKey(category: category, subcategory: subcategory)
                    deltasByKey[key, default: 0] += delta.changeBytes
                }
                try await growthJournalService.recordDeltas(
                    trackedPath: trackedPath,
                    deltas: deltasByKey,
                    at: snapshot.createdAt
                )
            }
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
        try await db.clearRealtimeData()
    }

    // MARK: - Growth List

    /// Calculates the growth list by comparing the latest two snapshots.
    ///
    /// - Parameters:
    ///   - trackedPath: The TrackedPath to compare
    /// - Returns: Array of GrowthItem sorted by growthBytes descending
    /// - Throws: BaselineError if insufficient snapshots exist
    func getGrowthList(trackedPath: TrackedPath) async throws -> [GrowthItem] {
        let snapshots = try await db.fetchRecentSnapshots(trackedPathId: trackedPath.id, limit: 2)

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

    func resolveGrowthComparisonSnapshots(
        trackedPathId: UUID,
        limit: Int = 12
    ) async throws -> GrowthComparisonSnapshots? {
        let snapshots = try await db.fetchRecentSnapshots(trackedPathId: trackedPathId, limit: limit)

        guard let latestSnapshot = snapshots.first,
              let latestSnapshotId = latestSnapshot.id else {
            return nil
        }

        let latestEntryCount = try await db.fetchEntryCount(for: latestSnapshotId)
        let baselineSnapshotId = try await comparableBaselineSnapshotId(
            from: snapshots,
            latestSnapshotId: latestSnapshotId,
            latestEntryCount: latestEntryCount
        )

        return GrowthComparisonSnapshots(
            currentSnapshotId: latestSnapshotId,
            baselineSnapshotId: baselineSnapshotId
        )
    }

    /// Drills down into a specific path to find growth contributors.
    ///
    /// - Parameters:
    ///   - path: The path to drill down into
    ///   - trackedPath: The TrackedPath context
    /// - Returns: Array of GrowthItem sorted by growthBytes descending
    /// - Throws: BaselineError if insufficient snapshots exist
    func drillDown(path: String, trackedPath: TrackedPath) async throws -> [GrowthItem] {
        let snapshots = try await db.fetchRecentSnapshots(trackedPathId: trackedPath.id, limit: 2)

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

    private func comparableBaselineSnapshotId(
        from snapshots: [Snapshot],
        latestSnapshotId: Int64,
        latestEntryCount: Int
    ) async throws -> Int64? {
        guard latestEntryCount > 0 else { return nil }

        let minimumComparableEntryCount = latestEntryCount / 2

        for snapshot in snapshots.dropFirst() {
            guard let candidateSnapshotId = snapshot.id else { continue }
            guard candidateSnapshotId != latestSnapshotId else { continue }

            let candidateEntryCount = try await db.fetchEntryCount(for: candidateSnapshotId)
            if candidateEntryCount <= 100 {
                continue
            }

            if candidateEntryCount < minimumComparableEntryCount {
                continue
            }

            return candidateSnapshotId
        }

        return nil
    }

    // MARK: - Category Growth List

    /// Calculates the growth list aggregated by category by comparing the latest two snapshots.
    ///
    /// - Parameters:
    ///   - trackedPath: The TrackedPath to compare
    /// - Returns: Array of CategoryGrowthItem sorted by totalGrowthBytes descending
    /// - Throws: BaselineError if insufficient snapshots exist
    func getCategoryGrowthList(trackedPath: TrackedPath) async throws -> [CategoryGrowthItem] {
        let snapshots = try await db.fetchRecentSnapshots(trackedPathId: trackedPath.id, limit: 2)

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

        guard previousEntryCount > 100 else {
            throw BaselineError.insufficientSnapshots
        }

        // If current has way more entries than previous, previous was likely incomplete
        // Allow up to 50% growth as reasonable, otherwise treat as first scan
        let minExpectedPrevious = currentEntryCount / 2
        if previousEntryCount < minExpectedPrevious {
            throw BaselineError.insufficientSnapshots
        }

        // Calculate deltas
        let deltas = try await db.calculateDeltas(beforeId: previousId, afterId: currentId)
        try Task.checkCancellation()

        // Filter to only items that grew
        let growingDeltas = deltas.filter { $0.changeBytes > 0 }

        guard !growingDeltas.isEmpty else {
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

        }

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
        } else {
            // Legacy snapshots without freeBytes - graceful degradation
            freeSpaceDelta = nil
            unexplainedDelta = nil
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
            let workingSetTotals = try await db.fetchWorkingSetCategoryTotals(for: trackedPath.id)
            if !workingSetTotals.isEmpty {
                return workingSetTotals
            }

            // Get the latest snapshot for this trackedPath
            let snapshots = try await db.fetchRecentSnapshots(trackedPathId: trackedPath.id, limit: 1)
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
            let items = categoryTotals.map { (category, totalBytes) -> CategoryInventoryItem in
                return CategoryInventoryItem(
                    category: category,
                    currentSizeBytes: totalBytes,
                    growthTrend: nil,
                    recentGrowthStory: nil
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
                struct TopEntryHeap {
                    private(set) var entries: [SnapshotEntryWithPath] = []
                    let limit: Int

                    mutating func insert(_ entry: SnapshotEntryWithPath) {
                        guard limit > 0 else { return }

                        if entries.count < limit {
                            entries.append(entry)
                            siftUp(from: entries.count - 1)
                            return
                        }

                        guard let smallest = entries.first, isBetter(entry, than: smallest) else {
                            return
                        }

                        entries[0] = entry
                        siftDown(from: 0)
                    }

                    private func comesBefore(_ lhs: SnapshotEntryWithPath, _ rhs: SnapshotEntryWithPath) -> Bool {
                        if lhs.sizeBytes != rhs.sizeBytes {
                            return lhs.sizeBytes < rhs.sizeBytes
                        }
                        return lhs.path.localizedStandardCompare(rhs.path) == .orderedDescending
                    }

                    private func isBetter(_ lhs: SnapshotEntryWithPath, than rhs: SnapshotEntryWithPath) -> Bool {
                        if lhs.sizeBytes != rhs.sizeBytes {
                            return lhs.sizeBytes > rhs.sizeBytes
                        }
                        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                    }

                    private mutating func siftUp(from index: Int) {
                        var child = index
                        while child > 0 {
                            let parent = (child - 1) / 2
                            guard comesBefore(entries[child], entries[parent]) else { break }
                            entries.swapAt(child, parent)
                            child = parent
                        }
                    }

                    private mutating func siftDown(from index: Int) {
                        var parent = index

                        while true {
                            let left = parent * 2 + 1
                            let right = left + 1
                            var candidate = parent

                            if left < entries.count && comesBefore(entries[left], entries[candidate]) {
                                candidate = left
                            }

                            if right < entries.count && comesBefore(entries[right], entries[candidate]) {
                                candidate = right
                            }

                            guard candidate != parent else { break }
                            entries.swapAt(parent, candidate)
                            parent = candidate
                        }
                    }
                }

                var totalBytes: Int64 = 0
                var fileCount: Int = 0
                var topEntries: TopEntryHeap

                init(limit: Int) {
                    topEntries = TopEntryHeap(limit: limit)
                }

                mutating func add(_ entry: SnapshotEntryWithPath) {
                    totalBytes += entry.sizeBytes
                    fileCount += 1
                    topEntries.insert(entry)
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
                    let subcategory = GrowthCategory.subcategorize(path: entry.path)

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
                let sortedTopEntries = accumulator.topEntries.entries.sorted {
                    if $0.sizeBytes == $1.sizeBytes {
                        return $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    }
                    return $0.sizeBytes > $1.sizeBytes
                }
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
                    growthBytes: nil,
                    topFiles: topFiles
                )
            }

            return groups.sorted { $0.totalBytes > $1.totalBytes }
        } catch {
            print("[BaselineService] Error getting subcategory breakdown for \(category.rawValue): \(error)")
            return []
        }
    }

    /// Builds subcategory breakdown from working set entries (used in deltas-only mode).
    func getSubcategoryBreakdownFromWorkingSet(for category: GrowthCategory, trackedPathId: UUID) async -> [SubcategoryGroup] {
        do {
            struct SubcategoryAccumulator {
                struct TopEntryHeap {
                    private(set) var entries: [SnapshotEntryWithPath] = []
                    let limit: Int

                    mutating func insert(_ entry: SnapshotEntryWithPath) {
                        guard limit > 0 else { return }
                        if entries.count < limit {
                            entries.append(entry)
                            siftUp(from: entries.count - 1)
                            return
                        }
                        guard let smallest = entries.first, entry.sizeBytes > smallest.sizeBytes else { return }
                        entries[0] = entry
                        siftDown(from: 0)
                    }

                    private mutating func siftUp(from index: Int) {
                        var child = index
                        while child > 0 {
                            let parent = (child - 1) / 2
                            guard entries[child].sizeBytes < entries[parent].sizeBytes else { break }
                            entries.swapAt(child, parent)
                            child = parent
                        }
                    }

                    private mutating func siftDown(from index: Int) {
                        var parent = index
                        while true {
                            let left = parent * 2 + 1
                            let right = left + 1
                            var candidate = parent
                            if left < entries.count && entries[left].sizeBytes < entries[candidate].sizeBytes {
                                candidate = left
                            }
                            if right < entries.count && entries[right].sizeBytes < entries[candidate].sizeBytes {
                                candidate = right
                            }
                            guard candidate != parent else { break }
                            entries.swapAt(parent, candidate)
                            parent = candidate
                        }
                    }
                }

                var totalBytes: Int64 = 0
                var fileCount: Int = 0
                var topEntries: TopEntryHeap

                init(limit: Int) {
                    topEntries = TopEntryHeap(limit: limit)
                }

                mutating func add(_ entry: SnapshotEntryWithPath) {
                    totalBytes += entry.sizeBytes
                    fileCount += 1
                    topEntries.insert(entry)
                }
            }

            var grouped: [GrowthSubcategory?: SubcategoryAccumulator] = [:]
            let pageSize = 5_000
            var offset = 0

            while true {
                if Task.isCancelled { return [] }

                let entries = try await db.fetchWorkingSetEntriesPaginated(
                    trackedPathId: trackedPathId, offset: offset, limit: pageSize
                )
                guard !entries.isEmpty else { break }

                for entry in entries {
                    if Task.isCancelled { return [] }
                    guard GrowthCategory.categorize(path: entry.path) == category else { continue }
                    let subcategory = GrowthCategory.subcategorize(path: entry.path)
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
                let sortedTopEntries = accumulator.topEntries.entries.sorted { $0.sizeBytes > $1.sizeBytes }
                let topFiles = sortedTopEntries.map { entry in
                    let percent = totalBytes > 0 ? Double(entry.sizeBytes) / Double(totalBytes) : 0
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
                    growthBytes: nil,
                    topFiles: topFiles
                )
            }

            return groups.sorted { $0.totalBytes > $1.totalBytes }
        } catch {
            print("[BaselineService] Error getting working set subcategory breakdown for \(category.rawValue): \(error)")
            return []
        }
    }

    /// Finds files that contributed to growth since the last snapshot for a specific category/subcategory.
    func getGrowthContributors(
        trackedPathId: UUID,
        snapshotId: Int64,
        category: GrowthCategory,
        subcategory: GrowthSubcategory?,
        limit: Int = 50
    ) async -> [GrowthContributor] {
        do {
            return try await db.fetchGrowthContributors(
                trackedPathId: trackedPathId,
                snapshotId: snapshotId,
                category: category,
                subcategory: subcategory,
                limit: limit
            )
        } catch {
            print("[BaselineService] Error fetching growth contributors: \(error)")
            return []
        }
    }

    func getGrowthContributors(
        baselineSnapshotIdsByPath: [UUID: Int64],
        category: GrowthCategory,
        subcategory: GrowthSubcategory?,
        limit: Int = 50
    ) async -> [GrowthContributor] {
        var contributorsByPath: [String: GrowthContributor] = [:]

        for (trackedPathId, snapshotId) in baselineSnapshotIdsByPath {
            let contributors = await getGrowthContributors(
                trackedPathId: trackedPathId,
                snapshotId: snapshotId,
                category: category,
                subcategory: subcategory,
                limit: limit
            )

            for contributor in contributors {
                if let existing = contributorsByPath[contributor.path] {
                    contributorsByPath[contributor.path] = GrowthContributor(
                        path: contributor.path,
                        currentSizeBytes: max(existing.currentSizeBytes, contributor.currentSizeBytes),
                        growthBytes: existing.growthBytes + contributor.growthBytes
                    )
                } else {
                    contributorsByPath[contributor.path] = contributor
                }
            }
        }

        return contributorsByPath.values.sorted {
            if $0.growthBytes == $1.growthBytes {
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            return $0.growthBytes > $1.growthBytes
        }
        .prefix(limit)
        .map { $0 }
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
            let entries = try await collectSnapshotEntries(
                for: snapshotId,
                category: category,
                subcategory: subcategory
            )

            guard offset < entries.count else { return [] }

            let page = entries
                .sorted { lhs, rhs in
                    if lhs.sizeBytes == rhs.sizeBytes {
                        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                    }
                    return lhs.sizeBytes > rhs.sizeBytes
                }
                .dropFirst(offset)
                .prefix(limit)

            return page.map { entry in
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
        } catch {
            print("[BaselineService] Error loading more files for subcategory: \(error)")
            return []
        }
    }

    func loadMoreSubcategoryFiles(
        for category: GrowthCategory,
        subcategory: GrowthSubcategory?,
        snapshotIdsByPath: [UUID: Int64],
        totalBytes: Int64,
        offset: Int,
        limit: Int = SubcategoryGroup.loadMoreBatchSize
    ) async -> [GrowthItem] {
        do {
            let entries = try await collectSnapshotEntries(
                for: Array(snapshotIdsByPath.values),
                category: category,
                subcategory: subcategory
            )

            guard offset < entries.count else { return [] }

            let page = entries
                .sorted { lhs, rhs in
                    if lhs.sizeBytes == rhs.sizeBytes {
                        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                    }
                    return lhs.sizeBytes > rhs.sizeBytes
                }
                .dropFirst(offset)
                .prefix(limit)

            return page.map { entry in
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
        } catch {
            print("[BaselineService] Error loading aggregated files for subcategory: \(error)")
            return []
        }
    }

    /// Loads more files from the working set for a category/subcategory (deltas-only mode pagination).
    func loadMoreSubcategoryFilesFromWorkingSet(
        for category: GrowthCategory,
        subcategory: GrowthSubcategory?,
        trackedPathId: UUID,
        totalBytes: Int64,
        offset: Int,
        limit: Int = SubcategoryGroup.loadMoreBatchSize
    ) async -> [GrowthItem] {
        do {
            var allEntries: [SnapshotEntryWithPath] = []
            let pageSize = 5_000
            var dbOffset = 0
            while true {
                let entries = try await db.fetchWorkingSetEntriesPaginated(
                    trackedPathId: trackedPathId, offset: dbOffset, limit: pageSize
                )
                guard !entries.isEmpty else { break }
                for entry in entries {
                    guard GrowthCategory.categorize(path: entry.path) == category else { continue }
                    let sub = GrowthCategory.subcategorize(path: entry.path)
                    guard sub == subcategory else { continue }
                    allEntries.append(entry)
                }
                dbOffset += entries.count
            }

            guard offset < allEntries.count else { return [] }

            let page = allEntries
                .sorted { $0.sizeBytes > $1.sizeBytes }
                .dropFirst(offset)
                .prefix(limit)

            return page.map { entry in
                let percent = totalBytes > 0 ? Double(entry.sizeBytes) / Double(totalBytes) : 0
                return GrowthItem(
                    path: entry.path,
                    growthBytes: entry.sizeBytes,
                    currentSizeBytes: entry.sizeBytes,
                    percentOfParent: percent,
                    subcategory: subcategory
                )
            }
        } catch {
            print("[BaselineService] Error loading working set files for subcategory: \(error)")
            return []
        }
    }

    func getSubcategoryGrowthTotals(
        trackedPathId: UUID,
        snapshotId: Int64,
        category: GrowthCategory
    ) async -> [GrowthSubcategory?: Int64] {
        do {
            return try await db.fetchGrowthTotalsBySubcategory(
                trackedPathId: trackedPathId,
                snapshotId: snapshotId,
                category: category
            )
        } catch {
            print("[BaselineService] Error fetching subcategory growth totals for \(category.rawValue): \(error)")
            return [:]
        }
    }

    func getSubcategoryBreakdown(
        for category: GrowthCategory,
        trackedPathsById: [UUID: TrackedPath],
        latestSnapshotIdsByPath: [UUID: Int64],
        baselineSnapshotIdsByPath: [UUID: Int64]
    ) async -> [SubcategoryGroup] {
        var aggregated: [GrowthSubcategory?: SubcategoryGroup] = [:]

        for (trackedPathId, snapshotId) in latestSnapshotIdsByPath {
            let groups = await getSubcategoryBreakdown(for: category, snapshotId: snapshotId)

            var growthTotals: [GrowthSubcategory?: Int64] = [:]
            if let baselineSnapshotId = baselineSnapshotIdsByPath[trackedPathId] {
                growthTotals = await getSubcategoryGrowthTotals(
                    trackedPathId: trackedPathId,
                    snapshotId: baselineSnapshotId,
                    category: category
                )
            }

            if growthTotals.isEmpty,
               baselineSnapshotIdsByPath[trackedPathId] != nil,
               let trackedPath = trackedPathsById[trackedPathId] {
                let journalTotals = await growthJournalService.subcategoryGrowthTotals(
                    trackedPath: trackedPath,
                    category: category,
                    retentionDays: SettingsStore.shared.categoryHistoryRetentionDays
                )
                if !journalTotals.isEmpty {
                    growthTotals = journalTotals
                }
            }

            for group in groups {
                let groupGrowthBytes = growthTotals[group.subcategory]

                if var existing = aggregated[group.subcategory] {
                    existing = SubcategoryGroup(
                        subcategory: existing.subcategory,
                        displayName: existing.displayName,
                        totalBytes: existing.totalBytes + group.totalBytes,
                        fileCount: existing.fileCount + group.fileCount,
                        growthBytes: mergeOptionalBytes(existing.growthBytes, groupGrowthBytes),
                        topFiles: mergedTopFiles(
                            existing.topFiles,
                            group.topFiles,
                            limit: SubcategoryGroup.initialLoadLimit
                        )
                    )
                    aggregated[group.subcategory] = existing
                } else {
                    aggregated[group.subcategory] = SubcategoryGroup(
                        subcategory: group.subcategory,
                        displayName: group.displayName,
                        totalBytes: group.totalBytes,
                        fileCount: group.fileCount,
                        growthBytes: groupGrowthBytes,
                        topFiles: group.topFiles
                    )
                }
            }
        }

        return aggregated.values.sorted {
            if $0.totalBytes == $1.totalBytes {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return $0.totalBytes > $1.totalBytes
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

    private func collectSnapshotEntries(
        for snapshotId: Int64,
        category: GrowthCategory,
        subcategory: GrowthSubcategory?
    ) async throws -> [SnapshotEntryWithPath] {
        let pageSize = 5_000
        var offset = 0
        var matches: [SnapshotEntryWithPath] = []

        while true {
            try Task.checkCancellation()

            let entries = try await db.fetchEntriesPaginatedUnordered(
                for: snapshotId,
                offset: offset,
                limit: pageSize
            )
            guard !entries.isEmpty else { break }

            for entry in entries {
                guard GrowthCategory.categorize(path: entry.path) == category else { continue }
                guard GrowthCategory.subcategorize(path: entry.path) == subcategory else { continue }
                matches.append(entry)
            }

            offset += entries.count
        }

        return matches
    }

    private func collectSnapshotEntries(
        for snapshotIds: [Int64],
        category: GrowthCategory,
        subcategory: GrowthSubcategory?
    ) async throws -> [SnapshotEntryWithPath] {
        var matches: [SnapshotEntryWithPath] = []

        for snapshotId in snapshotIds {
            let snapshotMatches = try await collectSnapshotEntries(
                for: snapshotId,
                category: category,
                subcategory: subcategory
            )
            matches.append(contentsOf: snapshotMatches)
        }

        return matches
    }

    /// Gets inventory with recent growth stories merged.
    /// - Parameter trackedPath: The tracked path to analyze
    /// - Returns: Array of CategoryInventoryItem with recent growth attached where applicable
    func getInventoryWithTrends(trackedPath: TrackedPath) async -> [CategoryInventoryItem] {
        var inventory = await getCategoryInventory(trackedPath: trackedPath)
        let comparisonSnapshots = try? await resolveGrowthComparisonSnapshots(trackedPathId: trackedPath.id)
        guard comparisonSnapshots?.baselineSnapshotId != nil else {
            return inventory
        }

        let recentStories = await growthJournalService.recentGrowthStories(
            trackedPath: trackedPath,
            retentionDays: SettingsStore.shared.categoryHistoryRetentionDays
        )

        for index in inventory.indices {
            inventory[index].recentGrowthStory = recentStories[inventory[index].category]
        }

        return inventory
    }

    func getInventoryWithTrends(trackedPaths: [TrackedPath]) async -> InventoryAggregationResult {
        var itemsByCategory: [GrowthCategory: CategoryInventoryItem] = [:]
        var latestSnapshotIdsByPath: [UUID: Int64] = [:]
        var baselineSnapshotIdsByPath: [UUID: Int64] = [:]
        var latestSnapshotDate: Date?

        for trackedPath in trackedPaths {
            do {
                let snapshots = try await db.fetchRecentSnapshots(trackedPathId: trackedPath.id, limit: 1)
                if let latestSnapshot = snapshots.first, let latestSnapshotId = latestSnapshot.id {
                    latestSnapshotIdsByPath[trackedPath.id] = latestSnapshotId
                    if latestSnapshotDate == nil || latestSnapshot.createdAt > latestSnapshotDate! {
                        latestSnapshotDate = latestSnapshot.createdAt
                    }
                }

                if let comparison = try await resolveGrowthComparisonSnapshots(trackedPathId: trackedPath.id) {
                    latestSnapshotIdsByPath[trackedPath.id] = comparison.currentSnapshotId
                    if let baselineSnapshotId = comparison.baselineSnapshotId {
                        baselineSnapshotIdsByPath[trackedPath.id] = baselineSnapshotId
                    }
                }
            } catch {
                print("[BaselineService] Error resolving snapshots for \(trackedPath.displayName): \(error)")
            }

            let inventory = await getInventoryWithTrends(trackedPath: trackedPath)
            for item in inventory {
                if let existing = itemsByCategory[item.category] {
                    itemsByCategory[item.category] = mergeInventoryItem(existing, with: item)
                } else {
                    itemsByCategory[item.category] = item
                }
            }
        }

        let inventory = itemsByCategory.values.sorted {
            if $0.currentSizeBytes == $1.currentSizeBytes {
                return $0.category.displayName.localizedStandardCompare($1.category.displayName) == .orderedAscending
            }
            return $0.currentSizeBytes > $1.currentSizeBytes
        }

        return InventoryAggregationResult(
            inventory: inventory,
            latestSnapshotIdsByPath: latestSnapshotIdsByPath,
            baselineSnapshotIdsByPath: baselineSnapshotIdsByPath,
            latestSnapshotDate: latestSnapshotDate
        )
    }

    func getDiskAccounting(
        trackedPaths: [TrackedPath],
        primaryTrackedPath: TrackedPath?
    ) async -> DiskAccountingResult? {
        let orderedPaths: [TrackedPath]
        if let primaryTrackedPath {
            orderedPaths = [primaryTrackedPath] + trackedPaths.filter { $0.id != primaryTrackedPath.id }
        } else {
            orderedPaths = trackedPaths
        }

        var representativeResult: DiskAccountingResult?
        var explainedDelta: Int64 = 0

        for trackedPath in orderedPaths {
            do {
                let result = try await getDiskAccounting(trackedPath: trackedPath)
                if representativeResult == nil {
                    representativeResult = result
                }
                explainedDelta += result.explainedDelta
            } catch {
                continue
            }
        }

        guard let representativeResult else { return nil }

        let unexplainedDelta = representativeResult.freeSpaceDelta.map { abs($0 + explainedDelta) }
        return DiskAccountingResult(
            freeSpaceDelta: representativeResult.freeSpaceDelta,
            previousFreeSpace: representativeResult.previousFreeSpace,
            currentFreeSpace: representativeResult.currentFreeSpace,
            explainedDelta: explainedDelta,
            unexplainedDelta: unexplainedDelta
        )
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

    private func mergeInventoryItem(
        _ existing: CategoryInventoryItem,
        with incoming: CategoryInventoryItem
    ) -> CategoryInventoryItem {
        CategoryInventoryItem(
            category: existing.category,
            currentSizeBytes: existing.currentSizeBytes + incoming.currentSizeBytes,
            growthTrend: mergeGrowthTrend(existing.growthTrend, incoming.growthTrend),
            recentGrowthStory: mergeRecentGrowthStory(existing.recentGrowthStory, incoming.recentGrowthStory)
        )
    }

    private func mergeGrowthTrend(
        _ lhs: CategoryGrowthTrend?,
        _ rhs: CategoryGrowthTrend?
    ) -> CategoryGrowthTrend? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case let (trend?, nil), let (nil, trend?):
            return trend
        case let (lhs?, rhs?):
            let startedAt = min(lhs.growthStartedAt, rhs.growthStartedAt)
            let growthBytes = lhs.growthBytes + rhs.growthBytes
            let growthSpanDays = Calendar.current.dateComponents(
                [.day],
                from: startedAt,
                to: Date()
            ).day ?? max(lhs.growthSpanDays, rhs.growthSpanDays)

            return CategoryGrowthTrend(
                growthBytes: growthBytes,
                growthStartedAt: startedAt,
                growthSpanDays: max(1, growthSpanDays)
            )
        }
    }

    private func mergeRecentGrowthStory(
        _ lhs: RecentGrowthStory?,
        _ rhs: RecentGrowthStory?
    ) -> RecentGrowthStory? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case let (story?, nil), let (nil, story?):
            return story
        case let (lhs?, rhs?):
            let startedAt = min(lhs.startedAt, rhs.startedAt)
            let endedAt = max(lhs.endedAt, rhs.endedAt)
            let duration = max(60, endedAt.timeIntervalSince(startedAt) + 60)

            return RecentGrowthStory(
                category: lhs.category,
                subcategory: lhs.subcategory,
                deltaBytes: lhs.deltaBytes + rhs.deltaBytes,
                startedAt: startedAt,
                endedAt: endedAt,
                duration: duration,
                displayLabel: formattedDuration(duration)
            )
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minute: TimeInterval = 60
        let hour: TimeInterval = 60 * minute
        let day: TimeInterval = 24 * hour

        if duration >= day {
            return "\(max(1, Int(round(duration / day))))d"
        }

        if duration >= hour {
            return "\(max(1, Int(round(duration / hour))))h"
        }

        return "\(max(1, Int(round(duration / minute))))m"
    }

    private func mergeOptionalBytes(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case let (value?, nil), let (nil, value?):
            return value
        case let (lhs?, rhs?):
            return lhs + rhs
        }
    }

    private func mergedTopFiles(
        _ lhs: [GrowthItem],
        _ rhs: [GrowthItem],
        limit: Int
    ) -> [GrowthItem] {
        var mergedByPath: [String: GrowthItem] = [:]

        for item in lhs + rhs {
            if let existing = mergedByPath[item.path] {
                mergedByPath[item.path] = GrowthItem(
                    path: item.path,
                    growthBytes: max(existing.growthBytes, item.growthBytes),
                    currentSizeBytes: max(existing.currentSizeBytes, item.currentSizeBytes),
                    percentOfParent: max(existing.percentOfParent, item.percentOfParent),
                    subcategory: item.subcategory ?? existing.subcategory
                )
            } else {
                mergedByPath[item.path] = item
            }
        }

        return mergedByPath.values.sorted {
            if $0.currentSizeBytes == $1.currentSizeBytes {
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            return $0.currentSizeBytes > $1.currentSizeBytes
        }
        .prefix(limit)
        .map { $0 }
    }
}
