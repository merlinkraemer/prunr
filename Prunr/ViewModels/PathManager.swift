import Foundation
import SwiftUI

/// Manages user-configurable tracked paths with persistent storage
@Observable
@MainActor
final class PathManager {

    // MARK: - Constants

    private static let pathsKey = "trackedPaths"

    // MARK: - Stored Properties

    /// The current list of tracked paths
    /// This is the source of truth that @Observable tracks
    private(set) var paths: [TrackedPath] = []

    // MARK: - Computed Properties

    /// Custom paths (user-added, excluding defaults)
    var customPaths: [TrackedPath] {
        paths.filter { !$0.isDefault }
    }

    /// Default paths that are currently tracked
    var activeDefaults: [TrackedPath] {
        paths.filter { $0.isDefault }
    }

    /// All default paths available
    static var defaultPaths: [TrackedPath] {
        TrackedPath.defaultPaths
    }

    // MARK: - Initialization

    init() {
        // Load persisted paths or use defaults
        if let savedPaths = Self.loadPaths() {
            paths = savedPaths
        } else {
            paths = TrackedPath.defaultPaths
            savePaths()
        }
    }

    // MARK: - Public Methods

    /// Adds a new path to track
    /// - Parameter url: The file system URL to add
    /// - Returns: The newly created TrackedPath, or nil if the URL is already tracked
    @discardableResult
    func addPath(url: URL) -> TrackedPath? {
        // Check if already tracked
        guard !paths.contains(where: { $0.url == url }) else { return nil }

        // Use lastPathComponent as display name, or "Custom Path" if empty
        let displayName = url.lastPathComponent.isEmpty ? "Custom Path" : url.lastPathComponent

        let newPath = TrackedPath(url: url, displayName: displayName, isDefault: false)
        paths.append(newPath)
        savePaths()
        return newPath
    }

    /// Removes a custom path from tracking
    /// - Parameter path: The TrackedPath to remove
    /// - Note: Default paths cannot be removed
    func removePath(_ path: TrackedPath) {
        guard !path.isDefault else { return }
        paths.removeAll { $0.id == path.id }
        savePaths()
    }

    /// Removes all custom paths, keeping only defaults
    func removeCustomPaths() {
        paths = paths.filter { $0.isDefault }
        savePaths()
    }

    /// Resets paths to the default set
    func resetToDefaults() {
        paths = TrackedPath.defaultPaths
        savePaths()
    }

    /// Checks if a URL is currently being tracked
    /// - Parameter url: The URL to check
    /// - Returns: True if the URL is in the tracked paths
    func contains(url: URL) -> Bool {
        paths.contains { $0.url == url }
    }

    // MARK: - Private Methods

    /// Saves the current paths to UserDefaults
    private func savePaths() {
        if let encoded = try? JSONEncoder().encode(paths) {
            UserDefaults.standard.set(encoded, forKey: Self.pathsKey)
        }
    }

    /// Loads paths from UserDefaults
    /// - Returns: The saved paths, or nil if no saved data exists
    private static func loadPaths() -> [TrackedPath]? {
        guard let data = UserDefaults.standard.data(forKey: pathsKey),
              !data.isEmpty else {
            return nil
        }
        return try? JSONDecoder().decode([TrackedPath].self, from: data)
    }
}
