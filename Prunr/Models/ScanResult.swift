import Foundation

/// Result of a single file scan operation
struct ScanResult: Sendable {
    /// The file system path (relative or absolute)
    var path: String

    /// Size in bytes as reported by totalFileAllocatedSizeKey
    /// This represents actual disk usage on APFS, not logical file size
    var sizeBytes: Int64

    /// Precomputed classification so scan pipelines don't have to re-parse the path.
    var category: GrowthCategory
    var subcategory: GrowthSubcategory?

    init(
        path: String,
        sizeBytes: Int64,
        category: GrowthCategory? = nil,
        subcategory: GrowthSubcategory? = nil
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        let resolvedCategory = category ?? GrowthCategory.categorize(path: path)
        self.category = resolvedCategory
        self.subcategory = subcategory ?? GrowthCategory.subcategorize(path: path)
    }
}
