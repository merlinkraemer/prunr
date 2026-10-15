import Foundation
import GRDB

/// A category's current size plus its signed net change over the display window.
struct CategoryInventoryItem: Identifiable, Sendable, Equatable {
    var id: GrowthCategory { category }
    let category: GrowthCategory
    var currentSizeBytes: Int64
    var recentGrowthStory: RecentGrowthStory?

    /// Signed net change over the display window.
    var growthDeltaBytes: Int64 {
        recentGrowthStory?.deltaBytes ?? 0
    }

    /// The delta a row should draw, or `nil` when it falls under the
    /// presentation floor. Sub-floor movement stays in every sum — the floor
    /// only decides whether the line is worth the pixels.
    var renderableGrowthDeltaBytes: Int64? {
        let delta = growthDeltaBytes
        guard abs(delta) >= GrowthJournalService.presentationFloorBytes else { return nil }
        return delta
    }
}

struct RecentGrowthStory: Sendable, Equatable, Hashable {
    let category: GrowthCategory
    let subcategory: GrowthSubcategory?
    let deltaBytes: Int64
    let startedAt: Date
    let endedAt: Date
}

struct GrowthJournalBucket: Codable, Identifiable, Sendable, Equatable, Hashable, FetchableRecord {
    static let databaseTableName = "growthJournalBucket"

    var id: Int64?
    let trackedPathId: String
    let bucketStart: Date
    let category: String
    let subcategory: String
    let deltaBytes: Int64
    /// Which writer recorded the bucket.
    let source: Source
    /// For `scan` buckets: start of the window the scan reconciled. The change
    /// happened somewhere in `(observedSince, bucketStart]`.
    let observedSince: Date?
    /// `UnitResolver` key of the place this change belongs to.
    let unitKey: String

    enum Source: String, Codable, Sendable {
        /// Recorded by the realtime watcher at the time the change happened.
        case watch
        /// Residual a full scan found that the watcher missed.
        case scan
        /// History before the first scan, rebuilt from the birth dates of
        /// files written once (`FileDateHistory`).
        case files
    }
}

struct WorkingSetEntry: Codable, Identifiable, Sendable, Equatable, Hashable, FetchableRecord {
    static let databaseTableName = "workingSetEntry"

    var id: Int64?
    let trackedPathId: String
    let pathId: Int64
    let sizeBytes: Int64
    let updatedAt: Date
}

/// Supplemental inventory entry used for storage shown in the drive bar
/// that does not map to a drill-down category.
struct SupplementalInventoryItem: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let icon: String
    let currentSizeBytes: Int64
    let badgeText: String
}

struct SubcategoryGroup: Identifiable, Sendable, Equatable {
    let id: String
    let subcategory: GrowthSubcategory?
    /// Set for an owner group in Apps & System: the resolved owner's key.
    let ownerKey: String?
    /// The owner's icon; nil shows the subcategory symbol.
    let ownerIcon: UnitIconSource?
    /// The drilldown index group (`DrilldownGroupKey`).
    let groupKey: String
    /// Every index group the row shows: one, or the owner groups merged into
    /// one app or into "Other apps".
    let groupKeys: [String]
    let displayName: String
    let totalBytes: Int64
    let fileCount: Int
    var growthBytes: Int64?
    var topFiles: [GrowthItem]

    init(
        subcategory: GrowthSubcategory?,
        displayName: String,
        totalBytes: Int64,
        fileCount: Int,
        growthBytes: Int64? = nil,
        topFiles: [GrowthItem],
        groupKey: String? = nil,
        ownerKey: String? = nil,
        ownerIcon: UnitIconSource? = nil,
        groupKeys: [String]? = nil
    ) {
        self.id = ownerKey.map { "owner:\($0)" }
            ?? subcategory?.rawValue
            ?? "__uncategorized__:\(displayName)"
        self.subcategory = subcategory
        self.ownerKey = ownerKey
        self.ownerIcon = ownerIcon
        let groupKey = groupKey ?? subcategory?.rawValue ?? ""
        self.groupKey = groupKey
        self.groupKeys = groupKeys ?? [groupKey]
        self.displayName = displayName
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.growthBytes = growthBytes
        self.topFiles = topFiles
    }

    /// Whether there are more files to load beyond what's in topFiles
    var hasMoreFiles: Bool {
        topFiles.count < fileCount
    }

    /// Number of files currently loaded
    var loadedFileCount: Int {
        topFiles.count
    }

    static let otherOwnersKey = "other-apps"

    /// "Other apps (N)": the owners too small for their own row.
    var isRemainder: Bool { ownerKey == Self.otherOwnersKey }

    var icon: String {
        guard let ownerKey else { return subcategory?.icon ?? "folder.fill" }
        if ownerKey == UnitOwner.system.key { return GrowthCategory.cachesAndSystem.icon }
        if ownerKey.hasPrefix(UnitOwner.categoryKeyPrefix),
           let category = GrowthCategory(rawValue: String(ownerKey.dropFirst(UnitOwner.categoryKeyPrefix.count))) {
            return category.icon
        }
        return "app.fill"
    }

    // MARK: - Pagination Constants

    /// Initial number of files to load per subcategory
    static let initialLoadLimit = 50

    /// Number of additional files to load when "Load More" is clicked
    static let loadMoreBatchSize = 50

    /// Maximum files that can be loaded (safeguard against memory issues)
    static let maxLoadableFiles = 500
}
