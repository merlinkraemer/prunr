import Foundation

/// Represents a category's current inventory (size) with optional growth trend
struct CategoryInventoryItem: Identifiable, Sendable, Equatable {
    var id: GrowthCategory { category }
    let category: GrowthCategory
    let currentSizeBytes: Int64
    var growthTrend: CategoryGrowthTrend?
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

struct SubcategoryGroup: Identifiable, Sendable, Equatable {
    let id = UUID()
    let subcategory: GrowthSubcategory?
    let displayName: String
    let totalBytes: Int64
    let fileCount: Int
    var topFiles: [GrowthItem]
    
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
    static let initialLoadLimit = 20
    
    /// Number of additional files to load when "Load More" is clicked
    static let loadMoreBatchSize = 50
    
    /// Maximum files that can be loaded (safeguard against memory issues)
    static let maxLoadableFiles = 500
}
