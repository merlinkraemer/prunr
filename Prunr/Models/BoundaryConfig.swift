import Foundation

/// Configuration for identifying boundary folders that should stop recursive scanning.
///
/// Boundary folders are typically auto-generated or contain dependencies that don't need
/// to be scanned for delta tracking. This prevents wasting resources on node_modules,
/// build artifacts, caches, etc.
struct BoundaryConfig {

    /// Standard folder patterns that should stop drill-down scanning.
    ///
    /// These are well-known directories across development ecosystems that contain
    /// generated content, dependencies, or cached data that rarely changes in ways
    /// meaningful for delta tracking.
    static let standardBoundaries: Set<String> = [
        // JavaScript/Node.js
        "node_modules",

        // Git
        ".git",

        // Python virtual environments
        ".venv",
        "venv",
        "env",
        ".conda",

        // Rust
        ".cargo",
        "target",

        // Build artifacts
        "build",
        "Build",
        ".build",
        "DerivedData",
        ".xcode-build",

        // Caches
        ".cache",
        "Cache",

        // Third-party dependencies
        "vendor",
        "Vendor",
        "third_party",
        "3rdparty",

        // Swift Package Manager
        ".swiftpm",

        // CocoaPods
        "Pods",

        // Carthage
        "Carthage",

        // Gradle
        ".gradle",

        // Maven
        // "target" // Already included for Rust, shared with Java

        // Fastlane
        "fastlane",

        // Docker
        ".docker"
    ]

    /// Tests whether any component of the given path matches a boundary pattern.
    ///
    /// - Parameter path: The file system path to check
    /// - Returns: `true` if any path component matches a known boundary
    func matchesBoundary(_ path: String) -> Bool {
        // Extract path components and check each one
        let components = (path as NSString).pathComponents
        return components.contains { component in
            Self.standardBoundaries.contains(component)
        }
    }

    /// Determines whether scanning should stop at the given URL.
    ///
    /// This is a convenience method that checks only the last path component,
    /// suitable for directory traversal decisions.
    ///
    /// - Parameter url: The URL to check
    /// - Returns: `true` if the URL's last path component matches a boundary
    func shouldStopDrillDown(at url: URL) -> Bool {
        let lastComponent = url.lastPathComponent
        return Self.standardBoundaries.contains(lastComponent)
    }
}

// MARK: - Default Configuration

extension BoundaryConfig {
    /// The default boundary configuration used throughout the app.
    static let `default` = BoundaryConfig()
}
