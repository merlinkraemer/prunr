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

        // Home directory
        paths.append(TrackedPath(url: home, displayName: "Home", isDefault: true))

        // Desktop
        if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            paths.append(TrackedPath(url: desktop, displayName: "Desktop", isDefault: true))
        }

        // Documents
        if let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            paths.append(TrackedPath(url: documents, displayName: "Documents", isDefault: true))
        }

        // Downloads
        if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            paths.append(TrackedPath(url: downloads, displayName: "Downloads", isDefault: true))
        }

        // Developer directory (if it exists)
        let developerPath = home.appendingPathComponent("Developer")
        if fm.fileExists(atPath: developerPath.path) {
            paths.append(TrackedPath(url: developerPath, displayName: "Developer", isDefault: true))
        }

        return paths
    }()
}
