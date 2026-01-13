import Foundation
import SwiftUI

/// Service for categorizing file growth deltas into categories
actor CategoryDetectionService {

    // MARK: - Singleton

    /// Shared singleton instance
    static let shared = CategoryDetectionService()

    private init() {}

    // MARK: - Categorization

    /// Categorizes deltas by their source category
    /// - Parameter deltas: Array of GrowthItem to categorize
    /// - Returns: Dictionary mapping category to its deltas
    func categorizeDeltas(_ deltas: [GrowthItem]) -> [GrowthCategory: [GrowthItem]] {
        var categorized: [GrowthCategory: [GrowthItem]] = [:]

        for delta in deltas {
            let category = GrowthCategory.categorize(path: delta.path)

            if categorized[category] == nil {
                categorized[category] = []
            }
            categorized[category]?.append(delta)

            // Log category assignment for debugging
            print("[CategoryDetectionService] Categorized '\(delta.path)' -> \(category.displayName)")
        }

        return categorized
    }

    // MARK: - Helpers

    /// Filters items above the big file threshold (100MB)
    /// - Parameter deltas: Array of GrowthItem to filter
    /// - Returns: Array of items >= 100MB
    func filterBigItems(_ deltas: [GrowthItem]) -> [GrowthItem] {
        deltas.filter { $0.growthBytes >= bigFileThreshold }
    }

    /// Filters items below the big file threshold (100MB)
    /// - Parameter deltas: Array of GrowthItem to filter
    /// - Returns: Array of items < 100MB
    func filterSmallItems(_ deltas: [GrowthItem]) -> [GrowthItem] {
        deltas.filter { $0.growthBytes < bigFileThreshold }
    }

    /// Calculates total growth from an array of deltas
    /// - Parameter deltas: Array of GrowthItem to sum
    /// - Returns: Total growth in bytes
    func calculateTotalGrowth(_ deltas: [GrowthItem]) -> Int64 {
        deltas.reduce(Int64(0)) { $0 + $1.growthBytes }
    }

    /// Calculates current size from an array of deltas
    /// - Parameter deltas: Array of GrowthItem to sum
    /// - Returns: Total current size in bytes
    func calculateCurrentSize(_ deltas: [GrowthItem]) -> Int64 {
        deltas.reduce(Int64(0)) { $0 + $1.currentSizeBytes }
    }
}
