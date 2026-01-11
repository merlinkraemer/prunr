import Foundation

/// A user-configurable path to be scanned for delta tracking
struct TrackedPath: Codable, Identifiable, Equatable, Hashable {
    /// Unique identifier for this path entry
    let id: UUID

    /// The file system URL to track
    let url: URL

    /// Display name shown in the sidebar
    let displayName: String

    /// Whether this is a default path (cannot be removed)
    let isDefault: Bool

    init(id: UUID = UUID(), url: URL, displayName: String, isDefault: Bool = false) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.isDefault = isDefault
    }

    /// Security-scoped bookmark data for sandbox compatibility
    /// Use this when persisting paths to maintain access across app launches
    var bookmarkData: Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

// MARK: - Default Paths

extension TrackedPath {
    /// Standard default paths most users want to track
    static let defaultPaths: [TrackedPath] = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        var paths: [TrackedPath] = []

        // Test data directory (for development)
        // Hardcoded for this environment as requested
        let testDataPath = URL(fileURLWithPath: "/Users/merlinkramer/dev/projects/prunr/test_data")
        paths.append(TrackedPath(url: testDataPath, displayName: "Test Data", isDefault: true))

        return paths
    }()
}

