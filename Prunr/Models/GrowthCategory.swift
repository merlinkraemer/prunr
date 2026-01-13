import SwiftUI

/// Big file threshold: 100MB in bytes
let bigFileThreshold: Int64 = 100 * 1024 * 1024

/// An item in the growth list representing a path that grew since baseline
struct GrowthItem: Identifiable, Sendable, Equatable {
    let id = UUID()
    let path: String
    let growthBytes: Int64
    let currentSizeBytes: Int64
    let percentOfParent: Double

    // MARK: - Computed Properties

    /// Whether this item is considered a "big file" (>=100MB)
    var isBigFile: Bool {
        growthBytes >= bigFileThreshold
    }

    /// The category this item belongs to
    var category: GrowthCategory {
        GrowthCategory.categorize(path: path)
    }

    /// Extract just the file/folder name
    private var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// Growth text (e.g., "+1.2 GB")
    private var growthText: String {
        formattedBytes(growthBytes, prefix: "+")
    }

    /// Formats bytes for display
    private func formattedBytes(_ bytes: Int64, prefix: String = "") -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000

        if abs(gb) >= 1 {
            return "\(prefix)\(String(format: "%.1f", gb)) GB"
        } else if abs(mb) >= 1 {
            return "\(prefix)\(String(format: "%.0f", mb)) MB"
        } else if abs(kb) >= 1 {
            return "\(prefix)\(String(format: "%.0f", kb)) KB"
        } else {
            return "\(prefix)\(bytes) B"
        }
    }
}

/// Categories for grouping file growth by source/type
enum GrowthCategory: String, CaseIterable, Identifiable {
    case homebrew
    case nodeModules
    case libraryCaches
    case downloads
    case docker
    case spotifyCache
    case browserCache
    case mailAttachments
    case trash
    case other

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - Display Properties

    /// Human-readable name for UI display
    var displayName: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .nodeModules: return "node_modules"
        case .libraryCaches: return "Library/Caches"
        case .downloads: return "Downloads"
        case .docker: return "Docker"
        case .spotifyCache: return "Spotify"
        case .browserCache: return "Browser Cache"
        case .mailAttachments: return "Mail Attachments"
        case .trash: return "Trash"
        case .other: return "Other"
        }
    }

    /// SF Symbol icon for category display
    var icon: String {
        switch self {
        case .homebrew: return "mug.fill"
        case .nodeModules: return "circle.grid.2x2.fill"
        case .libraryCaches: return "folder.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .docker: return "shippingbox.fill"
        case .spotifyCache: return "music.note"
        case .browserCache: return "globe"
        case .mailAttachments: return "envelope.fill"
        case .trash: return "trash.fill"
        case .other: return "doc.fill"
        }
    }

    /// Accent color for category (optional)
    var color: Color? {
        switch self {
        case .homebrew: return .orange
        case .nodeModules: return .green
        case .libraryCaches: return .blue
        case .downloads: return .blue
        case .docker: return .blue
        case .spotifyCache: return .green
        case .browserCache: return .blue
        case .mailAttachments: return .blue
        case .trash: return .gray
        case .other: return .gray
        }
    }

    // MARK: - Pattern Matching

    /// Path substrings that match this category
    var patterns: [String] {
        switch self {
        case .homebrew:
            return ["/usr/local/Cellar", "/opt/homebrew", "/Library/Caches/Homebrew", "Caches/Homebrew"]
        case .nodeModules:
            return ["node_modules"]
        case .libraryCaches:
            return ["Library/Caches", "/Library/Caches", ".cache"]
        case .downloads:
            return ["/Downloads", "/downloads"]
        case .docker:
            return ["/var/lib/docker", "Library/Containers/com.docker", ".docker"]
        case .spotifyCache:
            return ["Library/Application Support/Spotify", ".spotify"]
        case .browserCache:
            return ["Library/Caches/Google/Chrome", "Library/Caches/Mozilla/Firefox", "Library/Safari"]
        case .mailAttachments:
            return ["Library/Mail"]
        case .trash:
            return [".Trash"]
        case .other:
            return []
        }
    }

    /// Categorizes a file system path into a GrowthCategory
    /// - Parameter path: The file system path to classify
    /// - Returns: The matching GrowthCategory, or .other if no match
    static func categorize(path: String) -> GrowthCategory {
        // Normalize path: expand tilde to full home directory path
        let normalizedPath = (path as NSString).expandingTildeInPath

        // Check specific categories in priority order

        // Homebrew
        if containsAny(of: normalizedPath, substrings: homebrew.patterns) {
            return .homebrew
        }

        // node_modules
        if containsAny(of: normalizedPath, substrings: nodeModules.patterns) {
            return .nodeModules
        }

        // Docker
        if containsAny(of: normalizedPath, substrings: docker.patterns) {
            return .docker
        }

        // Spotify
        if containsAny(of: normalizedPath, substrings: spotifyCache.patterns) {
            return .spotifyCache
        }

        // Browser cache
        if containsAny(of: normalizedPath, substrings: browserCache.patterns) {
            return .browserCache
        }

        // Mail attachments
        if containsAny(of: normalizedPath, substrings: mailAttachments.patterns) {
            return .mailAttachments
        }

        // Trash
        if containsAny(of: normalizedPath, substrings: trash.patterns) {
            return .trash
        }

        // Library/Caches (check after specific caches)
        if containsAny(of: normalizedPath, substrings: libraryCaches.patterns) {
            return .libraryCaches
        }

        // Downloads
        if containsAny(of: normalizedPath, substrings: downloads.patterns) {
            return .downloads
        }

        return .other
    }

    /// Helper to check if path contains any of the substrings
    private static func containsAny(of path: String, substrings: [String]) -> Bool {
        substrings.contains { path.contains($0) }
    }
}
