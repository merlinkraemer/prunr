import Foundation

/// Represents a category with its aggregated growth data
struct CategoryGrowthItem: Identifiable, Sendable {
    /// The category this item represents
    let category: GrowthCategory

    /// Sum of all growth in this category (bytes)
    let totalGrowthBytes: Int64

    /// Current total size of this category (bytes)
    let currentSizeBytes: Int64

    /// All items in this category (for drill-down view)
    let allItems: [BaselineService.GrowthItem]

    /// Individual items >100MB threshold
    let bigItems: [BaselineService.GrowthItem]

    /// Number of items <=100MB threshold
    let smallItemCount: Int

    /// Total size of small items (bytes)
    let smallItemTotalBytes: Int64

    /// Percentage of total growth across all categories
    let percentOfTotal: Double

    // MARK: - Identifiable

    var id: String { category.displayName }

    // MARK: - Constants

    /// Threshold for "big file" designation (100MB)
    static let bigFileThreshold: Int64 = 100 * 1024 * 1024

    // MARK: - Computed Properties

    /// Human-readable growth string (e.g., "+4.1 GB")
    var formattedGrowth: String {
        ByteCountFormatter.string(fromByteCount: totalGrowthBytes, countStyle: .file)
    }

    /// Total number of items in this category
    var itemCount: Int {
        bigItems.count + smallItemCount
    }

    /// Whether there are small items to collapse
    var hasSmallItems: Bool {
        smallItemCount > 0
    }
}
