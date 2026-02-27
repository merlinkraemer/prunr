import Foundation

/// Represents a category's current inventory (size) with optional growth trend
struct CategoryInventoryItem: Identifiable, Sendable, Equatable {
    let id = UUID()
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
