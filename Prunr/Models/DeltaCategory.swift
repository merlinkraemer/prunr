import Foundation

/// Classification of delta entries for sidebar organization
enum DeltaCategory: String, CaseIterable, Identifiable {
    case apps
    case packages
    case containers
    case caches
    case developer
    case homebrew
    case docker
    case npm
    case media
    case other

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - Display Properties

    /// Human-readable name for UI display
    var displayName: String {
        switch self {
        case .apps: return "Applications"
        case .packages: return "Packages"
        case .containers: return "Containers"
        case .caches: return "Caches"
        case .developer: return "Developer"
        case .homebrew: return "Homebrew"
        case .docker: return "Docker"
        case .npm: return "NPM"
        case .media: return "Media"
        case .other: return "Other"
        }
    }

    /// SF Symbol icon for sidebar display
    var icon: String {
        switch self {
        case .apps: return "app.fill"
        case .packages: return "archivebox.fill"
        case .containers: return "cube.box.fill"
        case .caches: return "folder.fill"
        case .developer: return "hammer.fill"
        case .homebrew: return "mug.fill"
        case .docker: return "shippingbox.fill"
        case .npm: return "circle.grid.2x2.fill"
        case .media: return "photo.fill"
        case .other: return "doc.fill"
        }
    }

    /// File path patterns that match this category
    var patterns: [String] {
        switch self {
        case .apps:
            return [".app"]
        case .packages:
            return [".pkg", ".mpkg"]
        case .containers:
            return ["Library/Containers"]
        case .caches:
            return ["Library/Caches"]
        case .developer:
            return ["DerivedData", ".build", "build"]
        case .homebrew:
            return ["/usr/local/Cellar", "/opt/homebrew", "/Library/Caches/Homebrew", "Caches/Homebrew"]
        case .docker:
            return ["/var/lib/docker", "Library/Containers/com.docker", ".docker"]
        case .npm:
            return ["node_modules"]
        case .media:
            return []
        case .other:
            return []
        }
    }

    /// File extensions (with dots) for this category
    var extensions: [String] {
        switch self {
        case .apps, .packages:
            return patterns
        case .media:
            return [".mp4", ".mov", ".avi", ".mkv", ".jpg", ".jpeg", ".png", ".psd", ".ai", ".tiff", ".heic"]
        case .containers, .caches, .developer, .homebrew, .docker, .npm, .other:
            return []
        }
    }

    /// Categorizes a file system path into a DeltaCategory
    /// - Parameter path: The file system path to classify
    /// - Returns: The matching DeltaCategory, or .other if no match
    static func categorize(path: String) -> DeltaCategory {
        // Check source-specific patterns first (most specific)
        if containsAny(of: path, substrings: homebrew.patterns) {
            return .homebrew
        }
        if containsAny(of: path, substrings: docker.patterns) {
            return .docker
        }
        if containsAny(of: path, substrings: npm.patterns) {
            return .npm
        }

        // Check developer patterns
        if containsAny(of: path, substrings: developer.patterns) {
            return .developer
        }

        // Check containers/caches (path-based)
        if containsAny(of: path, substrings: containers.patterns) {
            return .containers
        }
        if containsAny(of: path, substrings: caches.patterns) {
            return .caches
        }

        // Check file extensions for media
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        let extWithDot = fileExtension.isEmpty ? "" : ".\(fileExtension)"

        if media.extensions.contains(extWithDot) {
            return .media
        }
        if apps.extensions.contains(extWithDot) {
            return .apps
        }
        if packages.extensions.contains(extWithDot) {
            return .packages
        }

        return .other
    }

    /// Helper to check if path contains any of the substrings
    private static func containsAny(of path: String, substrings: [String]) -> Bool {
        substrings.contains { path.contains($0) }
    }
}
