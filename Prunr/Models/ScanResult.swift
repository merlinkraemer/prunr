import Foundation

/// Result of a single file scan operation
struct ScanResult: Sendable {
    /// The file system path (relative or absolute)
    var path: String

    /// Size in bytes as reported by totalFileAllocatedSizeKey
    /// This represents actual disk usage on APFS, not logical file size
    var sizeBytes: Int64

    init(path: String, sizeBytes: Int64) {
        self.path = path
        self.sizeBytes = sizeBytes
    }
}
