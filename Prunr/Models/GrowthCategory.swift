import SwiftUI
import Foundation

/// Big file threshold: 100MB in bytes
let bigFileThreshold: Int64 = 100 * 1024 * 1024

/// An item in the growth list representing a path that grew since baseline
struct GrowthItem: Identifiable, Sendable, Equatable, Codable {
    let id = UUID()
    let path: String
    let growthBytes: Int64
    let currentSizeBytes: Int64
    let percentOfParent: Double
    var subcategory: GrowthSubcategory? = nil

    private enum CodingKeys: String, CodingKey {
        case path
        case growthBytes
        case currentSizeBytes
        case percentOfParent
        case subcategory
    }

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
enum GrowthCategory: String, CaseIterable, Codable, Identifiable {
    case developer
    case audioProduction
    case applications
    case mediaAndDocuments
    case downloads
    case cachesAndSystem
    case trash
    case other

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - Display Properties

    /// Human-readable name for UI display
    var displayName: String {
        switch self {
        case .developer: return "Developer"
        case .audioProduction: return "Audio Production"
        case .applications: return "Applications"
        case .mediaAndDocuments: return "Media & Documents"
        case .downloads: return "Downloads"
        case .cachesAndSystem: return "Caches & System"
        case .trash: return "Trash"
        case .other: return "Other"
        }
    }

    /// SF Symbol icon for category display
    var icon: String {
        switch self {
        case .developer: return "hammer.fill"
        case .audioProduction: return "music.note"
        case .applications: return "app.fill"
        case .mediaAndDocuments: return "photo.on.rectangle"
        case .downloads: return "arrow.down.circle.fill"
        case .cachesAndSystem: return "gearshape.fill"
        case .trash: return "trash.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }

    /// Accent color for category
    var color: Color {
        switch self {
        case .developer: return .orange
        case .audioProduction: return .purple
        case .applications: return .indigo
        case .mediaAndDocuments: return .pink
        case .downloads: return .blue
        case .cachesAndSystem: return .teal
        case .trash: return .red
        case .other: return .brown
        }
    }

    var supportsSubcategories: Bool {
        switch self {
        case .downloads, .trash, .other:
            return false
        default:
            return true
        }
    }

    // MARK: - Pattern Matching

    /// Categorizes a file system path into a GrowthCategory
    /// - Parameter path: The file system path to classify
    /// - Returns: The matching GrowthCategory, or .other if no match
    /// Combined classify: single lowercasing pass for both category and subcategory.
    static func classify(path: String) -> (GrowthCategory, GrowthSubcategory?) {
        let lowerPath = normalizedLowercasedPath(path)
        let category = categorizeFromLowered(lowerPath)
        let subcategory = subcategorizeFromLowered(lowerPath, category: category)
        return (category, subcategory)
    }

    static func categorize(path: String) -> GrowthCategory {
        let lowerPath = normalizedLowercasedPath(path)
        return categorizeFromLowered(lowerPath)
    }

    private static func categorizeFromLowered(_ lowerPath: String) -> GrowthCategory {
        if isTrashPath(lowerPath) {
            return .trash
        }

        if isDownloadsPath(lowerPath) {
            return .downloads
        }

        // High-confidence developer patterns (docker, node_modules, git, build artifacts, etc.)
        if isSpecificDeveloperPath(lowerPath) {
            return .developer
        }

        if isAudioProductionPath(lowerPath) {
            return .audioProduction
        }

        if isApplicationsPath(lowerPath) {
            return .applications
        }

        if isMediaAndDocumentsPath(lowerPath) {
            return .mediaAndDocuments
        }

        if isCachesAndSystemPath(lowerPath) {
            return .cachesAndSystem
        }

        // Fallback: files under dev project roots (~/dev, ~/projects, etc.)
        // that didn't match any more specific category above.
        if isDevProjectPath(lowerPath) {
            return .developer
        }

        return .other
    }

    static func subcategorize(path: String) -> GrowthSubcategory? {
        let lowerPath = normalizedLowercasedPath(path)
        let category = categorizeFromLowered(lowerPath)
        return subcategorizeFromLowered(lowerPath, category: category)
    }

    private static func subcategorizeFromLowered(_ lowerPath: String, category: GrowthCategory) -> GrowthSubcategory? {
        switch category {
        case .developer:
            if isDockerPath(lowerPath) { return .docker }
            if isNodeModulesPath(lowerPath) { return .nodeModules }
            if isGitPath(lowerPath) { return .gitRepos }
            if isBuildArtifactsPath(lowerPath) { return .buildArtifacts }
            if isDatabasePath(lowerPath) { return .databases }
            if isPythonVenvPath(lowerPath) { return .pythonVenvs }
            if isDevProjectPath(lowerPath) { return .devProjects }
            return .devProjects

        case .audioProduction:
            if isAbletonPath(lowerPath) { return .abletonProjects }
            if isSampleLibraryPath(lowerPath) { return .sampleLibraries }
            if isAudioPluginPath(lowerPath) { return .audioPlugins }
            if isAudioFilePath(lowerPath) { return .audioFiles }
            return nil

        case .applications:
            if isHomebrewPath(lowerPath) { return .homebrew }
            if isGlobalPackagePath(lowerPath) { return .globalPackages }
            if isAppBundlePath(lowerPath) { return .appBundles }
            return nil

        case .mediaAndDocuments:
            if isPhotoPath(lowerPath) { return .photos }
            if isVideoPath(lowerPath) { return .videos }
            if isDesignFilePath(lowerPath) { return .designFiles }
            if isDocumentPath(lowerPath) { return .documents }
            return nil

        case .cachesAndSystem:
            if isBrowserCachePath(lowerPath) { return .browserCaches }
            if isSpotifyPath(lowerPath) { return .spotifyCache }
            if isMailPath(lowerPath) { return .mailAttachments }
            if isAppCachePath(lowerPath) { return .appCaches }
            if isSystemSupportPath(lowerPath) { return .systemSupport }
            return nil

        case .downloads, .trash, .other:
            return nil
        }
    }

    // MARK: - Path Detection Helpers

    private static let photoExtensions = [".jpg", ".jpeg", ".png", ".heic", ".raw"]
    private static let videoExtensions = [".mov", ".mp4", ".mkv", ".avi", ".m4v"]
    private static let designExtensions = [".psd", ".sketch", ".fig", ".ai", ".xd"]
    private static let documentExtensions = [".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".pages", ".numbers", ".key"]
    private static let audioExtensions = [".wav", ".aif", ".aiff", ".mp3", ".flac", ".ogg", ".m4a"]

    private static let homePathLowercased: String =
        FileManager.default.homeDirectoryForCurrentUser.path.lowercased()

    private static func normalizedLowercasedPath(_ path: String) -> String {
        let expandedPath = (path as NSString).expandingTildeInPath
        let withoutTrailingSlash = expandedPath.count > 1 && expandedPath.hasSuffix("/")
            ? String(expandedPath.dropLast())
            : expandedPath
        return withoutTrailingSlash.lowercased()
    }

    private static func isUnderDirectory(_ lowerPath: String, _ lowerDirectory: String) -> Bool {
        lowerPath == lowerDirectory || lowerPath.hasPrefix(lowerDirectory + "/")
    }

    private static func containsPathComponent(_ lowerPath: String, _ component: String) -> Bool {
        lowerPath.contains("/\(component)/") || lowerPath.hasSuffix("/\(component)")
    }

    private static func hasAnySuffix(_ lowerPath: String, suffixes: [String]) -> Bool {
        suffixes.contains { lowerPath.hasSuffix($0) }
    }

    private static func isTrashPath(_ lowerPath: String) -> Bool {
        let home = homePathLowercased
        return isUnderDirectory(lowerPath, home + "/.trash")
    }

    private static func isDownloadsPath(_ lowerPath: String) -> Bool {
        let home = homePathLowercased
        return isUnderDirectory(lowerPath, home + "/downloads")
    }

    /// Matches specific developer artifact patterns (docker, node_modules, git, build output, etc.)
    /// Does NOT include the broad dev-project-root fallback.
    private static func isSpecificDeveloperPath(_ lowerPath: String) -> Bool {
        isDockerPath(lowerPath)
            || isNodeModulesPath(lowerPath)
            || isGitPath(lowerPath)
            || isBuildArtifactsPath(lowerPath)
            || isDatabasePath(lowerPath)
            || isPythonVenvPath(lowerPath)
    }

    /// Legacy composite check — kept for subcategorization and context helpers.
    private static func isDeveloperPath(_ lowerPath: String) -> Bool {
        isSpecificDeveloperPath(lowerPath) || isDevProjectPath(lowerPath)
    }

    private static func isAudioProductionPath(_ lowerPath: String) -> Bool {
        isAbletonPath(lowerPath)
            || isSampleLibraryPath(lowerPath)
            || isAudioPluginPath(lowerPath)
            || isAudioFilePath(lowerPath)
    }

    private static func isApplicationsPath(_ lowerPath: String) -> Bool {
        isAppBundlePath(lowerPath)
            || isHomebrewPath(lowerPath)
            || isGlobalPackagePath(lowerPath)
    }

    private static func isMediaAndDocumentsPath(_ lowerPath: String) -> Bool {
        isPhotoPath(lowerPath)
            || isVideoPath(lowerPath)
            || isDesignFilePath(lowerPath)
            || isDocumentPath(lowerPath)
    }

    private static func isCachesAndSystemPath(_ lowerPath: String) -> Bool {
        isBrowserCachePath(lowerPath)
            || isSpotifyPath(lowerPath)
            || isMailPath(lowerPath)
            || isAppCachePath(lowerPath)
            || isSystemSupportPath(lowerPath)
    }

    // MARK: Developer

    private static func isDockerPath(_ lowerPath: String) -> Bool {
        lowerPath.contains("/docker.raw")
            || lowerPath.contains("/.colima/")
            || lowerPath.hasSuffix("/.colima")
            || containsPathComponent(lowerPath, "docker")
            || lowerPath.contains("com.docker")
            || lowerPath.contains("library/containers/com.docker")
    }

    private static func isNodeModulesPath(_ lowerPath: String) -> Bool {
        guard containsPathComponent(lowerPath, "node_modules") else {
            return false
        }

        return !isGlobalPackagePath(lowerPath)
    }

    private static func isGitPath(_ lowerPath: String) -> Bool {
        lowerPath.contains("/.git/") || lowerPath.hasSuffix("/.git")
    }

    private static func isBuildArtifactsPath(_ lowerPath: String) -> Bool {
        if lowerPath.contains("/deriveddata/")
            || lowerPath.contains("/target/release")
            || lowerPath.contains("/target/debug")
            || lowerPath.contains("/.build/")
            || lowerPath.hasSuffix("/.build") {
            return true
        }

        if lowerPath.contains("/dist/") || lowerPath.hasSuffix("/dist") {
            return isLikelyDeveloperContext(lowerPath)
        }

        if lowerPath.contains("/build/") || lowerPath.hasSuffix("/build") {
            return isLikelyDeveloperContext(lowerPath)
        }

        return false
    }

    private static func isDatabasePath(_ lowerPath: String) -> Bool {
        if lowerPath.contains("/var/lib/postgresql")
            || lowerPath.contains("/postgres")
            || lowerPath.contains("postgresql") {
            return true
        }

        if lowerPath.contains("/library/") {
            return lowerPath.hasSuffix(".sqlite")
                || lowerPath.hasSuffix(".sqlite3")
                || lowerPath.hasSuffix(".sqlite-wal")
                || lowerPath.hasSuffix(".sqlite-shm")
        }

        return false
    }

    private static func isPythonVenvPath(_ lowerPath: String) -> Bool {
        lowerPath.contains("/.venv/")
            || lowerPath.hasSuffix("/.venv")
            || containsPathComponent(lowerPath, "venv")
            || lowerPath.contains("/.virtualenvs/")
            || lowerPath.hasSuffix("/.virtualenvs")
            || lowerPath.contains("/.pyenv/")
            || lowerPath.hasSuffix("/.pyenv")
    }

    private static func isDevProjectPath(_ lowerPath: String) -> Bool {
        let home = homePathLowercased
        let devRoots = ["/dev", "/projects", "/code", "/repos", "/src"]
            .map { home + $0 }

        return devRoots.contains { isUnderDirectory(lowerPath, $0) }
    }

    private static func isLikelyDeveloperContext(_ lowerPath: String) -> Bool {
        isDevProjectPath(lowerPath)
            || lowerPath.contains("/xcode/")
            || lowerPath.contains("/android/")
            || lowerPath.contains("/workspace/")
            || containsPathComponent(lowerPath, "node_modules")
            || lowerPath.contains("/.git/")
    }

    // MARK: Audio Production

    private static func isAbletonPath(_ lowerPath: String) -> Bool {
        lowerPath.contains("/ableton/")
            || lowerPath.contains("ableton project info")
            || lowerPath.hasSuffix(".als")
    }

    private static func isSampleLibraryPath(_ lowerPath: String) -> Bool {
        lowerPath.contains("/splice/")
            || lowerPath.contains("/native instruments/")
            || lowerPath.contains("/kontakt/")
            || lowerPath.contains("library/application support/native instruments")
            || lowerPath.contains("/samples/")
            || lowerPath.contains("/music/samples")
    }

    private static func isAudioPluginPath(_ lowerPath: String) -> Bool {
        lowerPath.contains("/audio/plug-ins/")
            || lowerPath.contains("library/audio/")
            || lowerPath.contains("/components/")
            || lowerPath.hasSuffix(".vst")
            || lowerPath.hasSuffix(".vst3")
            || lowerPath.hasSuffix(".component")
    }

    private static func isAudioFilePath(_ lowerPath: String) -> Bool {
        guard hasAnySuffix(lowerPath, suffixes: audioExtensions) else {
            return false
        }

        if lowerPath.contains("photos library.photoslibrary")
            || lowerPath.contains("/music/music/media/") {
            return false
        }

        return true
    }

    // MARK: Applications

    private static func isAppBundlePath(_ lowerPath: String) -> Bool {
        lowerPath.contains("/applications/")
            || lowerPath.hasSuffix(".app")
            || lowerPath.contains(".app/")
    }

    private static func isHomebrewPath(_ lowerPath: String) -> Bool {
        lowerPath.hasPrefix("/opt/homebrew")
            || lowerPath.hasPrefix("/usr/local/cellar")
            || lowerPath.hasPrefix("/usr/local/caskroom")
            || lowerPath.contains("library/caches/homebrew")
    }

    private static func isGlobalPackagePath(_ lowerPath: String) -> Bool {
        lowerPath.contains("/.npm-global/")
            || lowerPath.hasSuffix("/.npm-global")
            || lowerPath.contains("/.bun/")
            || lowerPath.hasSuffix("/.bun")
            || lowerPath.hasPrefix("/usr/local/lib/node_modules")
            || lowerPath.contains("/.yarn/")
            || lowerPath.hasSuffix("/.yarn")
    }

    // MARK: Media & Documents

    private static func isPhotoPath(_ lowerPath: String) -> Bool {
        if lowerPath.contains("photos library.photoslibrary") {
            return true
        }

        guard hasAnySuffix(lowerPath, suffixes: photoExtensions) else {
            return false
        }

        return !lowerPath.contains("/library/caches/")
    }

    private static func isVideoPath(_ lowerPath: String) -> Bool {
        if lowerPath.contains("/movies/") {
            return true
        }

        guard hasAnySuffix(lowerPath, suffixes: videoExtensions) else {
            return false
        }

        return !lowerPath.contains("/library/caches/")
    }

    private static func isDesignFilePath(_ lowerPath: String) -> Bool {
        hasAnySuffix(lowerPath, suffixes: designExtensions)
    }

    private static func isDocumentPath(_ lowerPath: String) -> Bool {
        let home = homePathLowercased
        if isUnderDirectory(lowerPath, home + "/documents") {
            return true
        }
        return hasAnySuffix(lowerPath, suffixes: documentExtensions)
    }

    // MARK: Caches & System

    private static func isAppCachePath(_ lowerPath: String) -> Bool {
        let home = homePathLowercased
        let libraryCacheRoot = home + "/library/caches"
        return isUnderDirectory(lowerPath, libraryCacheRoot) && !isHomebrewPath(lowerPath)
    }

    private static func isBrowserCachePath(_ lowerPath: String) -> Bool {
        guard lowerPath.contains("cache") || lowerPath.contains("caches") else {
            return false
        }

        return lowerPath.contains("chrome")
            || lowerPath.contains("safari")
            || lowerPath.contains("firefox")
    }

    private static func isSpotifyPath(_ lowerPath: String) -> Bool {
        lowerPath.contains("com.spotify") || lowerPath.contains("/spotify/")
    }

    private static func isMailPath(_ lowerPath: String) -> Bool {
        lowerPath.contains("/mail/")
            || lowerPath.contains("com.apple.mail")
            || lowerPath.contains("mail download")
            || lowerPath.contains("attachments")
    }

    private static func isSystemSupportPath(_ lowerPath: String) -> Bool {
        let home = homePathLowercased
        let libraryRoot = home + "/library"

        guard isUnderDirectory(lowerPath, libraryRoot) else {
            return false
        }

        if isAppCachePath(lowerPath) || isHomebrewPath(lowerPath) {
            return false
        }

        return true
    }
}

enum GrowthSubcategory: String, CaseIterable, Codable {
    // Developer
    case docker
    case nodeModules
    case gitRepos
    case buildArtifacts
    case databases
    case pythonVenvs
    case devProjects

    // Audio Production
    case abletonProjects
    case sampleLibraries
    case audioPlugins
    case audioFiles

    // Applications
    case appBundles
    case homebrew
    case globalPackages

    // Media & Documents
    case photos
    case videos
    case designFiles
    case documents

    // Caches & System
    case appCaches
    case browserCaches
    case spotifyCache
    case mailAttachments
    case systemSupport

    var parent: GrowthCategory {
        switch self {
        case .docker, .nodeModules, .gitRepos, .buildArtifacts, .databases, .pythonVenvs, .devProjects:
            return .developer
        case .abletonProjects, .sampleLibraries, .audioPlugins, .audioFiles:
            return .audioProduction
        case .appBundles, .homebrew, .globalPackages:
            return .applications
        case .photos, .videos, .designFiles, .documents:
            return .mediaAndDocuments
        case .appCaches, .browserCaches, .spotifyCache, .mailAttachments, .systemSupport:
            return .cachesAndSystem
        }
    }

    var displayName: String {
        switch self {
        case .docker: return "Docker"
        case .nodeModules: return "node_modules"
        case .gitRepos: return "Git Repos (.git)"
        case .buildArtifacts: return "Build Artifacts"
        case .databases: return "Databases"
        case .pythonVenvs: return "Python Venvs"
        case .devProjects: return "Dev Projects"
        case .abletonProjects: return "Ableton Projects"
        case .sampleLibraries: return "Sample Libraries"
        case .audioPlugins: return "Audio Plugins"
        case .audioFiles: return "Audio Files"
        case .appBundles: return "App Bundles"
        case .homebrew: return "Homebrew"
        case .globalPackages: return "Global Packages"
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .designFiles: return "Design Files"
        case .documents: return "Documents"
        case .appCaches: return "App Caches"
        case .browserCaches: return "Browser Caches"
        case .spotifyCache: return "Spotify Cache"
        case .mailAttachments: return "Mail Attachments"
        case .systemSupport: return "System Support"
        }
    }

    var icon: String {
        switch self {
        case .docker: return "shippingbox.fill"
        case .nodeModules: return "square.grid.2x2.fill"
        case .gitRepos: return "point.topleft.down.curvedto.point.bottomright.up.fill"
        case .buildArtifacts: return "hammer.fill"
        case .databases: return "cylinder.fill"
        case .pythonVenvs: return "terminal.fill"
        case .devProjects: return "folder.fill"
        case .abletonProjects: return "music.quarternote.3"
        case .sampleLibraries: return "waveform.badge.plus"
        case .audioPlugins: return "puzzlepiece.extension.fill"
        case .audioFiles: return "waveform"
        case .appBundles: return "app.fill"
        case .homebrew: return "mug.fill"
        case .globalPackages: return "shippingbox.fill"
        case .photos: return "photo.fill"
        case .videos: return "video.fill"
        case .designFiles: return "paintpalette.fill"
        case .documents: return "doc.fill"
        case .appCaches: return "externaldrive.fill"
        case .browserCaches: return "globe"
        case .spotifyCache: return "music.note"
        case .mailAttachments: return "envelope.fill"
        case .systemSupport: return "gearshape.fill"
        }
    }

    static func subcategorize(path: String) -> GrowthSubcategory? {
        GrowthCategory.subcategorize(path: path)
    }
}
