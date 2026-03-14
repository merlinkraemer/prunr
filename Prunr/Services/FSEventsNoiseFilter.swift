import Foundation

/// Filters out known-noisy FSEvents paths that don't represent meaningful user-visible storage changes.
/// This runs on every FSEvent so all checks use fast prefix/suffix matching.
enum FSEventsNoiseFilter {

    // MARK: - Directory prefix patterns (must end with /)

    private static let ignoredDirectoryPrefixes: [String] = [
        "Library/Saved Application State/",
        "Library/Caches/com.apple.Safari/",
        "Library/Caches/CloudKit/",
        "Library/Caches/com.apple.nsurlsessiond/",
        "Library/WebKit/",
        "Library/Metadata/",
        ".Spotlight-V100/",
        ".fseventsd/",
        ".Trashes/",
    ]

    // MARK: - File name patterns

    private static let ignoredFileNames: Set<String> = [
        ".DS_Store",
        ".localized",
        "Thumbs.db",
        "desktop.ini",
    ]

    private static let ignoredFileSuffixes: [String] = [
        ".swp",
        ".swo",
        ".tmp",
        "~",
    ]

    /// Returns `true` if the path should be ignored (it represents noise, not meaningful storage changes).
    static func shouldIgnore(_ path: String) -> Bool {
        // Fast: check file name
        let lastComponent = (path as NSString).lastPathComponent
        if ignoredFileNames.contains(lastComponent) {
            return true
        }

        // Check temp file suffixes
        for suffix in ignoredFileSuffixes {
            if lastComponent.hasSuffix(suffix) {
                return true
            }
        }

        // Check directory prefixes (relative to any tracked root)
        for prefix in ignoredDirectoryPrefixes {
            if path.contains("/\(prefix)") {
                return true
            }
        }

        // Check user-configured scan ignores
        let customIgnores = _cachedCustomIgnores
        if !customIgnores.isEmpty && customIgnores.contains(lastComponent) {
            return true
        }

        return false
    }

    // MARK: - Cached custom ignores (refreshed lazily)

    /// Cached copy of user-configured ignore names, refreshed on main actor access.
    /// This avoids hitting MainActor-isolated SettingsStore on every event.
    private static var _cachedCustomIgnores: Set<String> = []
    private static var _lastCacheRefresh: Date = .distantPast

    /// Call from the main actor periodically to refresh the cached custom ignores.
    @MainActor
    static func refreshCustomIgnoresCache() {
        _cachedCustomIgnores = SettingsStore.shared.allScanIgnoreNames
        _lastCacheRefresh = Date()
    }
}
