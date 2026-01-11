import Foundation

/// Classification of delta entries for sidebar organization
enum DeltaCategory: String, CaseIterable, Identifiable {
    case apps
    case packages
    case containers
    case caches
    case developer
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
            return ["node_modules", "DerivedData", ".build", "build"]
        case .other:
            return []
        }
    }

    /// File extensions (with dots) for this category
    var extensions: [String] {
        switch self {
        case .apps, .packages:
            return patterns
        case .containers, .caches, .developer, .other:
            return []
        }
    }

    /// Categorizes a file system path into a DeltaCategory
    /// - Parameter path: The file system path to classify
    /// - Returns: The matching DeltaCategory, or .other if no match
    static func categorize(path: String) -> DeltaCategory {
        // Check developer patterns first (more specific)
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

        // Check file extensions
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        let extWithDot = fileExtension.isEmpty ? "" : ".\(fileExtension)"

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
