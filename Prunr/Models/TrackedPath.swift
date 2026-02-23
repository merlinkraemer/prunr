import Foundation

enum ScanPathPreset {
    static let mainBasePathID = UUID(uuidString: "B9E2C9D6-7A6C-4A8C-9A73-9DBA3DE27B57")!

    private struct CommonPreset {
        let id: UUID
        let pathBuilder: (URL, URL) -> URL
        let name: String
    }

    private static let commonPresets: [CommonPreset] = [
        CommonPreset(
            id: UUID(uuidString: "5F2D56A8-1A8F-4A65-A8B4-2D6E9C5F3AC1")!,
            pathBuilder: { _, home in home.appendingPathComponent("Library/Caches", isDirectory: true) },
            name: "Library Caches"
        ),
        CommonPreset(
            id: UUID(uuidString: "3A126B18-C3D7-4E6E-B0D2-9C47F4D4B42D")!,
            pathBuilder: { _, home in home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true) },
            name: "Xcode DerivedData"
        ),
        CommonPreset(
            id: UUID(uuidString: "D0AA4EDB-1D2A-4E5D-9D47-8A313E53E75A")!,
            pathBuilder: { _, home in home.appendingPathComponent("Library/Developer/CoreSimulator", isDirectory: true) },
            name: "CoreSimulator"
        ),
        CommonPreset(
            id: UUID(uuidString: "2E405418-217A-4A3B-95D4-4E1049B6A4A0")!,
            pathBuilder: { _, home in home.appendingPathComponent(".docker", isDirectory: true) },
            name: "Docker Home"
        ),
        CommonPreset(
            id: UUID(uuidString: "A7D56F58-7B7D-4E92-9D4A-2D5292C182D5")!,
            pathBuilder: { _, home in home.appendingPathComponent("Library/Containers/com.docker.docker", isDirectory: true) },
            name: "Docker Container Data"
        ),
        CommonPreset(
            id: UUID(uuidString: "198E6B80-B3A9-4C09-9866-8A27C67D6D66")!,
            pathBuilder: { base, _ in base.appendingPathComponent(".cache", isDirectory: true) },
            name: "Base .cache"
        )
    ]

    static func mainBasePath(url: URL) -> TrackedPath {
        TrackedPath(id: mainBasePathID, url: url, displayName: "Base Directory", isDefault: true)
    }

    static func commonPathPresets(baseDirectory: URL) -> [TrackedPath] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        return commonPresets.compactMap { preset in
            let url = preset.pathBuilder(baseDirectory, home)
            guard fm.fileExists(atPath: url.path) else { return nil }

            return TrackedPath(
                id: preset.id,
                url: url,
                displayName: preset.name,
                isDefault: true
            )
        }
    }
}

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
    static func mainBasePath(url: URL) -> TrackedPath {
        ScanPathPreset.mainBasePath(url: url)
    }

    static func commonPathPresets(baseDirectory: URL) -> [TrackedPath] {
        ScanPathPreset.commonPathPresets(baseDirectory: baseDirectory)
    }

    /// Standard default paths most users want to track
    static let defaultPaths: [TrackedPath] = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        var paths: [TrackedPath] = []

        let devPath = home.appendingPathComponent("dev", isDirectory: true)
        paths.append(mainBasePath(url: devPath))

        return paths
    }()
}
