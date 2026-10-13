import Foundation
import Observation
import OSLog

/// In-memory view of the drilldown index: every category's groups (loaded
/// with each inventory load) and, per category, the groups' largest files
/// (loaded when the category is opened). All reads are index lookups.
@MainActor
@Observable
final class DrilldownStore {
    private(set) var groupsByCategory: [GrowthCategory: [SubcategoryGroup]] = [:]
    /// True while the index of an enabled tracked path is still being built.
    private(set) var isBuilding = false
    private(set) var loadingFileCategories: Set<GrowthCategory> = []
    private(set) var loadedFileCategories: Set<GrowthCategory> = []

    @ObservationIgnored private var storedFilesByGroupID: [String: [GrowthItem]] = [:]
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let db = DatabaseManager.shared
    @ObservationIgnored private let logger = Logger(subsystem: "com.prunr.app", category: "Drilldown")

    nonisolated init() {}

    func clear() {
        generation &+= 1
        groupsByCategory = [:]
        isBuilding = false
        loadingFileCategories = []
        loadedFileCategories = []
        storedFilesByGroupID = [:]
    }

    /// Re-reads every group. Categories whose files were loaded are re-read too,
    /// keeping as many files per group as were shown.
    func reload(trackedPathIds: [UUID]) async {
        generation &+= 1
        let requestGeneration = generation
        let snapshot: DrilldownGroupsSnapshot
        do {
            snapshot = try await db.fetchDrilldownGroups(trackedPathIds: trackedPathIds)
        } catch {
            logger.error("Drilldown groups read failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard requestGeneration == generation else { return }

        let shownCounts = groupsByCategory.values.joined().reduce(into: [String: Int]()) {
            $0[$1.id] = $1.topFiles.count
        }
        var groups: [GrowthCategory: [SubcategoryGroup]] = [:]
        for row in snapshot.rows where row.totalBytes > 0 {
            groups[row.category, default: []].append(Self.makeGroup(row, files: []))
        }
        groupsByCategory = groups.mapValues(Self.sorted)
        isBuilding = !snapshot.buildingTrackedPathIds.isEmpty

        let reloadCategories = loadedFileCategories
        loadedFileCategories = []
        storedFilesByGroupID = [:]
        for category in reloadCategories where groupsByCategory[category] != nil {
            await loadFiles(for: category, trackedPathIds: trackedPathIds, shownCounts: shownCounts)
        }
    }

    func isFilesLoaded(for category: GrowthCategory) -> Bool {
        loadedFileCategories.contains(category)
    }

    /// Loads the stored largest files of every group of a category, one read.
    func loadFiles(
        for category: GrowthCategory,
        trackedPathIds: [UUID],
        shownCounts: [String: Int] = [:]
    ) async {
        guard !loadedFileCategories.contains(category) else { return }
        let requestGeneration = generation
        loadingFileCategories.insert(category)
        defer { loadingFileCategories.remove(category) }

        let rows: [DrilldownFileRow]
        do {
            rows = try await db.fetchDrilldownTopFiles(trackedPathIds: trackedPathIds, category: category)
        } catch {
            logger.error("Drilldown files read failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard requestGeneration == generation, var groups = groupsByCategory[category] else { return }

        let rowsByGroupKey = Dictionary(grouping: rows, by: \.groupKey)
        for index in groups.indices {
            let group = groups[index]
            let files = (rowsByGroupKey[group.groupKey] ?? []).map { Self.makeItem($0, group: group) }
            storedFilesByGroupID[group.id] = files
            let shown = max(SubcategoryGroup.initialLoadLimit, shownCounts[group.id] ?? 0)
            groups[index].topFiles = Array(files.prefix(shown))
        }
        groupsByCategory[category] = groups
        loadedFileCategories.insert(category)
    }

    /// The group with the next page of files appended: from the stored top
    /// files while they last, then straight from the working set.
    func loadMoreFiles(for group: SubcategoryGroup, category: GrowthCategory, trackedPathIds: [UUID]) async -> SubcategoryGroup? {
        guard group.hasMoreFiles, group.loadedFileCount < SubcategoryGroup.maxLoadableFiles else { return nil }
        let requestGeneration = generation
        let offset = group.topFiles.count
        let limit = min(SubcategoryGroup.loadMoreBatchSize, SubcategoryGroup.maxLoadableFiles - offset)

        var next = Array((storedFilesByGroupID[group.id] ?? []).dropFirst(offset).prefix(limit))
        if next.count < limit {
            do {
                let rows = try await db.fetchDrilldownFiles(
                    trackedPathIds: trackedPathIds,
                    category: category,
                    groupKey: group.groupKey,
                    offset: offset + next.count,
                    limit: limit - next.count
                )
                next += rows.map { Self.makeItem($0, group: group) }
            } catch {
                logger.error("Drilldown more files read failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard requestGeneration == generation, !next.isEmpty else { return nil }

        var updated = group
        var seenPaths = Set(updated.topFiles.map(\.path))
        for file in next where seenPaths.insert(file.path).inserted {
            updated.topFiles.append(file)
        }
        if var groups = groupsByCategory[category], let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = updated
            groupsByCategory[category] = groups
        }
        return updated
    }

    func placeContents(unitRoot: String, trackedPathIds: [UUID], offset: Int = 0) async throws -> PlaceContentsPage {
        try await db.fetchPlaceContents(unitRoot: unitRoot, trackedPathIds: trackedPathIds, offset: offset)
    }

    nonisolated static func makeGroup(_ row: DrilldownGroupRow, files: [GrowthItem]) -> SubcategoryGroup {
        if DrilldownGroupKey.isCacheGroupKey(row.groupKey) {
            let application = DrilldownGroupKey.cacheApplication(of: row.groupKey)
            return SubcategoryGroup(
                subcategory: .appCaches,
                displayName: application.map(GrowthCategory.cacheApplicationDisplayName(for:)) ?? "Other Caches",
                totalBytes: row.totalBytes,
                fileCount: row.fileCount,
                topFiles: files,
                cacheApplicationKey: application,
                groupKey: row.groupKey
            )
        }

        let subcategory = GrowthSubcategory(rawValue: row.groupKey)
        return SubcategoryGroup(
            subcategory: subcategory,
            displayName: subcategory?.displayName
                ?? (row.category.supportsSubcategories ? "Uncategorized" : "Files"),
            totalBytes: row.totalBytes,
            fileCount: row.fileCount,
            topFiles: files,
            groupKey: row.groupKey
        )
    }

    private nonisolated static func makeItem(_ row: DrilldownFileRow, group: SubcategoryGroup) -> GrowthItem {
        GrowthItem(
            path: row.path,
            growthBytes: row.sizeBytes,
            currentSizeBytes: row.sizeBytes,
            percentOfParent: group.totalBytes > 0 ? Double(row.sizeBytes) / Double(group.totalBytes) : 0,
            subcategory: group.subcategory
        )
    }

    private nonisolated static func sorted(_ groups: [SubcategoryGroup]) -> [SubcategoryGroup] {
        groups.sorted {
            if $0.totalBytes == $1.totalBytes {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return $0.totalBytes > $1.totalBytes
        }
    }
}
