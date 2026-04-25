import Foundation
import GRDB

/// Represents a category's current inventory (size) with optional growth trend
struct CategoryInventoryItem: Identifiable, Sendable, Equatable {
    var id: GrowthCategory { category }
    let category: GrowthCategory
    var currentSizeBytes: Int64
    var growthTrend: CategoryGrowthTrend?
    var recentGrowthStory: RecentGrowthStory?
}

/// Represents a detected growth trend for a category
struct CategoryGrowthTrend: Sendable, Equatable, Hashable {
    /// Total growth in bytes since the trend started
    let growthBytes: Int64

    /// When the growth trend started
    let growthStartedAt: Date

    /// Number of days between trend start and now
    let growthSpanDays: Int
}

struct RecentGrowthStory: Sendable, Equatable, Hashable {
    let category: GrowthCategory
    let subcategory: GrowthSubcategory?
    let deltaBytes: Int64
    let startedAt: Date
    let endedAt: Date
    let duration: TimeInterval
    let displayLabel: String
}

struct GrowthJournalBucket: Codable, Identifiable, Sendable, Equatable, Hashable, FetchableRecord {
    static let databaseTableName = "growthJournalBucket"

    var id: Int64?
    let trackedPathId: String
    let bucketStart: Date
    let category: String
    let subcategory: String
    let deltaBytes: Int64
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
        topFiles: [GrowthItem]
    ) {
        self.id = subcategory?.rawValue ?? "__uncategorized__:\(displayName)"
        self.subcategory = subcategory
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

    // MARK: - Pagination Constants

    /// Initial number of files to load per subcategory
    static let initialLoadLimit = 50

    /// Number of additional files to load when "Load More" is clicked
    static let loadMoreBatchSize = 50

    /// Maximum files that can be loaded (safeguard against memory issues)
    static let maxLoadableFiles = 500
}
