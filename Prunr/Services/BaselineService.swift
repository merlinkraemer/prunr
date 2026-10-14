import Foundation
import OSLog

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
        /// Paths whose inventory could not be read. Callers must retain their
        /// current UI rather than treating an incomplete result as empty data.
        let unavailableTrackedPathIDs: Set<UUID>
        let latestSnapshotDate: Date?
        /// Earliest baseline-snapshot date across enabled paths — the "since"
        /// anchor for accumulated growth. Resets to ~now after Accept/Reset.
        let baselineSnapshotDate: Date?
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
    private let logger = Logger(subsystem: "com.prunr.app", category: "Baseline")

    /// Boundary configuration for stopping drill-down
    private let boundaryConfig = BoundaryConfig.default

    /// MainActor-isolated property for UI state
    @MainActor var isCreatingBaseline = false

    private init() {}

    // MARK: - Accept Growth

    /// Resets the baseline to the current working set sizes, clearing all growth indicators.
    /// Pure DB operation — no filesystem I/O.
    func acceptGrowth(for trackedPath: TrackedPath) async throws {
        let newSnapshotId = try await db.createSnapshotFromWorkingSet(
            trackedPathId: trackedPath.id,
            freeBytes: nil
        )
        try await DatabaseCleanupService.shared.aggregateCategoryTotals(for: newSnapshotId)
        try await db.deleteGrowthJournalBuckets(trackedPathId: trackedPath.id)
    }

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
        skipLog: ScanSkipLog? = nil,
        progress: ((ScanService.ScanProgress) -> Void)? = nil
    ) async throws -> Snapshot {
        // Get previous snapshot for delta calculation
        let previousSnapshots = try await db.fetchRecentSnapshots(trackedPathId: trackedPath.id, limit: 1)
        let previousSnapshotId = previousSnapshots.first?.id

        // Do not update the live working set until the scan completes successfully.
        // This keeps cancelled/failed full scans from leaving hybrid old+new inventory data.

        // Set UI state
        await MainActor.run {
            isCreatingBaseline = true
        }

        defer {
            Task { @MainActor in
                isCreatingBaseline = false
            }
        }

        // Run full scan into an isolated snapshot first. The working set is rebuilt
        // from that completed snapshot only after the scan succeeds.
        let outcome = try await scanService.scanWithDrilldownIndex(
            path: trackedPath.url.path,
            trackedPathId: trackedPath.id,
            ignoredNames: ignoredNames,
            alsoWriteWorkingSet: false,
            reconstructsFileHistory: previousSnapshotId == nil,
            skipLog: skipLog,
            progress: progress
        )
        let snapshot = outcome.snapshot

        guard let snapshotId = snapshot.id else {
            logger.error("Failed to create snapshot with ID")
            throw ScanError.unknown(NSError(
                domain: "BaselineService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create snapshot with ID"]
            ))
        }

        try await db.rebuildWorkingSet(
            from: snapshotId,
            trackedPathId: trackedPath.id,
            updatedAt: snapshot.createdAt,
            drilldownIndex: outcome.drilldownIndex
        )

        if previousSnapshotId == nil {
            // A first successful baseline must clear stale realtime growth left behind from pre-baseline runs.
            try await db.deleteGrowthJournalBuckets(trackedPathId: trackedPath.id)
            if let fileHistory = outcome.fileHistory {
                try await recordFileHistory(fileHistory, trackedPath: trackedPath)
            }
        }

        // Record deltas to growth journal only when a previous snapshot exists.
        // On first scan (previousSnapshotId == nil) this block is skipped entirely —
        // no calculateDeltas call and no journal recording, so first-scan cost is
        // scan + insert only, with no expensive diff computation.
        if let previous = previousSnapshots.first, let previousSnapshotId,
           HistoryStart.scanWindowKeepsResidual(windowStart: previous.createdAt) {
            // The realtime watcher already recorded most of this window's changes
            // at the time they happened. Keep those timestamps and add only the
            // residual the watcher missed (or over-counted), so the window total
            // still equals the authoritative snapshot delta without double-counting.
            // The window is (previous scan start, this scan start]; watcher refreshes
            // wait while a full scan runs, so later changes belong to the next window.
            let deltas = try await db.calculateDeltas(beforeId: previousSnapshotId, afterId: snapshotId)
            var authoritativeByKey: [DatabaseManager.JournalDeltaKey: Int64] = [:]
            for delta in deltas {
                let category = GrowthCategory.categorize(path: delta.path)
                let subcategory = GrowthCategory.subcategorize(path: delta.path)
                let key = DatabaseManager.JournalDeltaKey(
                    category: category,
                    subcategory: subcategory,
                    unitKey: UnitResolver.resolve(path: delta.path)
                )
                authoritativeByKey[key, default: 0] += delta.changeBytes
            }

            let recordedByKey = try await db.fetchGrowthJournalTotalsByKey(
                trackedPathId: trackedPath.id,
                from: previous.createdAt,
                to: snapshot.createdAt
            )

            var residualByKey: [DatabaseManager.JournalDeltaKey: Int64] = [:]
            for key in Set(authoritativeByKey.keys).union(recordedByKey.keys) {
                let residual = (authoritativeByKey[key] ?? 0) - (recordedByKey[key] ?? 0)
                if residual != 0 {
                    residualByKey[key] = residual
                }
            }

            if !residualByKey.isEmpty {
                try await growthJournalService.recordDeltas(
                    trackedPath: trackedPath,
                    deltas: residualByKey,
                    at: snapshot.createdAt,
                    source: .scan,
                    observedSince: previous.createdAt
                )
            }
        }

        return snapshot
    }

    /// Writes the history rebuilt from file dates. Every bucket lies before
    /// the first snapshot, so no later scan window reconciles it again.
    private func recordFileHistory(_ history: FileDateHistory, trackedPath: TrackedPath) async throws {
        let start = Date()
        try await db.upsertGrowthJournalBuckets(
            trackedPathId: trackedPath.id,
            deltasByBucketStart: history.deltasByBucketStart,
            source: .files
        )
        let milliseconds = Int(Date().timeIntervalSince(start) * 1000)
        logger.info("File-date history: \(history.fileCount) files, \(history.totalBytes) bytes in \(history.bucketCount) slots, written in \(milliseconds) ms")
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

    func clearHistory() async throws {
        HistoryStart.clear(at: Date())
        try await db.deleteAllGrowthJournalBuckets()
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
        HistoryStart.reset()
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
            return try await loadCategoryInventory(trackedPath: trackedPath)
        } catch {
            logger.error("Error getting category inventory: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func loadCategoryInventory(trackedPath: TrackedPath) async throws -> [CategoryInventoryItem] {
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
        return categoryTotals.map { (category, totalBytes) -> CategoryInventoryItem in
            CategoryInventoryItem(
                category: category,
                currentSizeBytes: totalBytes,
                recentGrowthStory: nil
            )
        }.sorted { $0.currentSizeBytes > $1.currentSizeBytes }
    }

    /// Gets inventory with recent growth stories merged.
    /// - Parameter trackedPath: The tracked path to analyze
    /// - Returns: Array of CategoryInventoryItem with recent growth attached where applicable
    func getInventoryWithTrends(trackedPath: TrackedPath) async -> [CategoryInventoryItem] {
        do {
            return try await loadInventoryWithTrends(trackedPath: trackedPath)
        } catch {
            logger.error("Error getting inventory with trends: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func loadInventoryWithTrends(trackedPath: TrackedPath) async throws -> [CategoryInventoryItem] {
        var inventory = try await loadCategoryInventory(trackedPath: trackedPath)
        guard let comparisonSnapshots = try await resolveGrowthComparisonSnapshots(trackedPathId: trackedPath.id) else {
            return inventory
        }

        if comparisonSnapshots.baselineSnapshotId == nil {
            let snapshots = try await db.fetchRecentSnapshots(trackedPathId: trackedPath.id, limit: 2)
            let hasSingleSnapshotOnly = snapshots.count == 1
            guard hasSingleSnapshotOnly else {
                return inventory
            }
        }

        let recentStories = await growthJournalService.recentGrowthStories(
            trackedPath: trackedPath
        )

        for index in inventory.indices {
            // Assign every signed story. The 1 MB floor is applied at render
            // time only — sub-floor categories must stay in the header sum.
            if let story = recentStories[inventory[index].category] {
                inventory[index].recentGrowthStory = story
            }
        }

        return inventory
    }

    func getInventoryWithTrends(trackedPaths: [TrackedPath]) async -> InventoryAggregationResult {
        var itemsByCategory: [GrowthCategory: CategoryInventoryItem] = [:]
        var latestSnapshotIdsByPath: [UUID: Int64] = [:]
        var baselineSnapshotIdsByPath: [UUID: Int64] = [:]
        var unavailableTrackedPathIDs: Set<UUID> = []
        var latestSnapshotDate: Date?
        var baselineSnapshotDate: Date?

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
                    // Use separate baseline when available, otherwise fall back to
                    // the current snapshot so that working-set changes (files added
                    // or grown since the initial scan) are detected as growth even
                    // before a second snapshot is taken.
                    let baselineId = comparison.baselineSnapshotId ?? comparison.currentSnapshotId
                    baselineSnapshotIdsByPath[trackedPath.id] = baselineId

                    // Track the earliest baseline date across paths — the "since"
                    // anchor for accumulated growth.
                    if let baselineDate = try await db.fetchSnapshotCreatedAt(snapshotId: baselineId) {
                        if baselineSnapshotDate == nil || baselineDate < baselineSnapshotDate! {
                            baselineSnapshotDate = baselineDate
                        }
                    }
                }
            } catch {
                logger.error("Error resolving snapshots for \(trackedPath.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                unavailableTrackedPathIDs.insert(trackedPath.id)
                continue
            }

            let inventory: [CategoryInventoryItem]
            do {
                inventory = try await loadInventoryWithTrends(trackedPath: trackedPath)
            } catch {
                logger.error("Error getting inventory for \(trackedPath.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                unavailableTrackedPathIDs.insert(trackedPath.id)
                continue
            }
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
            unavailableTrackedPathIDs: unavailableTrackedPathIDs,
            latestSnapshotDate: latestSnapshotDate,
            baselineSnapshotDate: baselineSnapshotDate
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

    private func mergeInventoryItem(
        _ existing: CategoryInventoryItem,
        with incoming: CategoryInventoryItem
    ) -> CategoryInventoryItem {
        CategoryInventoryItem(
            category: existing.category,
            currentSizeBytes: existing.currentSizeBytes + incoming.currentSizeBytes,
            recentGrowthStory: mergeRecentGrowthStory(existing.recentGrowthStory, incoming.recentGrowthStory)
        )
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
            return RecentGrowthStory(
                category: lhs.category,
                subcategory: lhs.subcategory,
                deltaBytes: lhs.deltaBytes + rhs.deltaBytes,
                startedAt: min(lhs.startedAt, rhs.startedAt),
                endedAt: max(lhs.endedAt, rhs.endedAt)
            )
        }
    }
}
