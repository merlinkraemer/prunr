import Foundation
import GRDB

/// Represents a size change between two snapshots for a given path
struct Delta: Codable, Identifiable, Hashable {
    /// Stable ID using path (not UUID or hashValue)
    var id: String { path }

    /// The file system path
    let path: String

    /// Size in previous snapshot (nil if new file)
    let oldSizeBytes: Int64?

    /// Size in current snapshot (nil if deleted)
    let newSizeBytes: Int64?

    /// Change in bytes: (newSize ?? 0) - (oldSize ?? 0)
    let changeBytes: Int64

    init(path: String, oldSizeBytes: Int64?, newSizeBytes: Int64?, changeBytes: Int64) {
        self.path = path
        self.oldSizeBytes = oldSizeBytes
        self.newSizeBytes = newSizeBytes
        self.changeBytes = changeBytes
    }

    /// Convenience initializer that calculates changeBytes
    init(path: String, oldSizeBytes: Int64?, newSizeBytes: Int64?) {
        self.path = path
        self.oldSizeBytes = oldSizeBytes
        self.newSizeBytes = newSizeBytes
        self.changeBytes = (newSizeBytes ?? 0) - (oldSizeBytes ?? 0)
    }
}

// MARK: - Computed Properties

extension Delta {
    /// Percentage change relative to old size (nil if old size was 0 or nil)
    var percentChange: Double? {
        guard let old = oldSizeBytes, old > 0 else { return nil }
        return Double(changeBytes) / Double(old) * 100.0
    }

    /// True if this path grew in size
    var isGrowth: Bool { changeBytes > 0 }

    /// True if this path shrank in size
    var isShrinkage: Bool { changeBytes < 0 }
}

// MARK: - GRDB FetchableRecord Conformance

extension Delta: FetchableRecord {
    /// Initialize from a database row (for SQL fetching)
    init(row: Row) {
        self.path = row["path"]
        self.oldSizeBytes = row["oldSizeBytes"]
        self.newSizeBytes = row["newSizeBytes"]
        self.changeBytes = row["changeBytes"]
    }
}
