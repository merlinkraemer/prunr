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
            id: UUID(uuidString: "7F39C716-6D31-4A7A-BD44-2CA1B5809F95")!,
            pathBuilder: { _, home in home.appendingPathComponent("Library/Group Containers/group.com.docker", isDirectory: true) },
            name: "Docker Group Container"
        ),
        CommonPreset(
            id: UUID(uuidString: "198E6B80-B3A9-4C09-9866-8A27C67D6D66")!,
            pathBuilder: { base, _ in base.appendingPathComponent(".cache", isDirectory: true) },
            name: "Base .cache"
        ),
        CommonPreset(
            id: UUID(uuidString: "9E2CD56B-B549-4DDE-A8B2-68CD6F13E5F4")!,
            pathBuilder: { _, home in home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true) },
            name: "Xcode Archives"
        ),
        CommonPreset(
            id: UUID(uuidString: "2D5A2556-F359-4CE2-B45C-A7A26B390A84")!,
            pathBuilder: { _, home in home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true) },
            name: "Xcode DeviceSupport"
        ),
        CommonPreset(
            id: UUID(uuidString: "2A1BA40B-0F7A-4E1F-A4A6-3DF86E188D25")!,
            pathBuilder: { _, home in home.appendingPathComponent(".npm", isDirectory: true) },
            name: "npm Cache"
        ),
        CommonPreset(
            id: UUID(uuidString: "4A2B3374-7AE4-424E-B632-7BB4B6811D78")!,
            pathBuilder: { _, home in home.appendingPathComponent(".pnpm-store", isDirectory: true) },
            name: "pnpm Store"
        ),
        CommonPreset(
            id: UUID(uuidString: "7AC5096A-B8A6-4A4C-BD76-9E5AD6A00A42")!,
            pathBuilder: { _, home in home.appendingPathComponent(".yarn", isDirectory: true) },
            name: "Yarn Cache"
        ),
        CommonPreset(
            id: UUID(uuidString: "AF2714DE-B2E2-48EC-9F2E-6A4A4AE01361")!,
            pathBuilder: { _, home in home.appendingPathComponent(".bun/install/cache", isDirectory: true) },
            name: "Bun Cache"
        ),
        CommonPreset(
            id: UUID(uuidString: "3F3A9012-6838-49C8-900E-713E4D2FD993")!,
            pathBuilder: { _, home in home.appendingPathComponent(".gradle/caches", isDirectory: true) },
            name: "Gradle Cache"
        ),
        CommonPreset(
            id: UUID(uuidString: "0A368D0F-EEA5-4AF9-A9CF-CE3A812D8F0B")!,
            pathBuilder: { _, home in home.appendingPathComponent(".m2/repository", isDirectory: true) },
            name: "Maven Repo"
        ),
        CommonPreset(
            id: UUID(uuidString: "A0D7E6DA-4A20-4AA7-8C1C-D095F4D410C5")!,
            pathBuilder: { _, home in home.appendingPathComponent(".cargo/registry", isDirectory: true) },
            name: "Cargo Registry"
        ),
        CommonPreset(
            id: UUID(uuidString: "7347C287-8A74-4540-8A51-35F8A1092D3F")!,
            pathBuilder: { _, home in home.appendingPathComponent(".cargo/git", isDirectory: true) },
            name: "Cargo Git Cache"
        ),
        CommonPreset(
            id: UUID(uuidString: "0F43E7F0-706F-4666-BF0B-4CEB37295DFB")!,
            pathBuilder: { _, home in home.appendingPathComponent("go/pkg/mod", isDirectory: true) },
            name: "Go Module Cache"
        ),
        CommonPreset(
            id: UUID(uuidString: "68BC01E1-0311-42C5-996E-C20A332F8562")!,
            pathBuilder: { _, home in home.appendingPathComponent(".cache/pip", isDirectory: true) },
            name: "pip Cache"
        ),
        CommonPreset(
            id: UUID(uuidString: "64A3F89F-3D06-4EC9-8E77-8B4A69C91E5A")!,
            pathBuilder: { _, _ in URL(fileURLWithPath: "/Library/Caches", isDirectory: true) },
            name: "System Library Caches"
        ),
        CommonPreset(
            id: UUID(uuidString: "8A4A7A9F-B1DD-4689-AF09-18E2B3AEBF97")!,
            pathBuilder: { _, _ in URL(fileURLWithPath: "/private/var/folders", isDirectory: true) },
            name: "System Temp Folders"
        ),
        CommonPreset(
            id: UUID(uuidString: "2A53A90E-3E4B-4F77-9A2E-91CB7A97D6AA")!,
            pathBuilder: { _, _ in URL(fileURLWithPath: "/private/var/tmp", isDirectory: true) },
            name: "System Temp"
        ),
        CommonPreset(
            id: UUID(uuidString: "6E4D6C4D-19CC-4A01-A5E8-4B78A4A1F8EE")!,
            pathBuilder: { _, _ in URL(fileURLWithPath: "/private/var/log", isDirectory: true) },
            name: "System Logs"
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
