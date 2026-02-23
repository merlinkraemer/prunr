import Foundation
import SwiftUI
import ServiceManagement

/// Observable settings store managing user preferences via UserDefaults
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()
    
    // MARK: - Keys
    
    private enum Keys {
        static let trackedPaths = "trackedPaths"
        static let customBoundaries = "customBoundaries"
        static let disabledPaths = "disabledPaths"
        static let disabledBoundaries = "disabledBoundaries"
        static let launchAtLogin = "launchAtLogin"
        static let mainBasePath = "mainBasePath"
        static let selectedCommonPathIDs = "selectedCommonPathIDs"
    }
    
    // MARK: - Properties
    
    /// User-configured tracked paths (additional to defaults)
    var customTrackedPaths: [TrackedPath] {
        didSet { saveTrackedPaths() }
    }

    /// Main base directory for scanning
    var mainBasePath: String {
        didSet { UserDefaults.standard.set(mainBasePath, forKey: Keys.mainBasePath) }
    }

    /// Selected common paths to include in scanning
    private var selectedCommonPathIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(selectedCommonPathIDs), forKey: Keys.selectedCommonPathIDs) }
    }
    
    /// User-added boundary folder names
    var customBoundaries: [String] {
        didSet { saveCustomBoundaries() }
    }
    
    /// Disabled path IDs (for checkboxes)
    private var disabledPathIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabledPathIDs), forKey: Keys.disabledPaths) }
    }
    
    /// Disabled boundary names
    private var disabledBoundaryNames: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabledBoundaryNames), forKey: Keys.disabledBoundaries) }
    }

    /// Launch app at system login
    var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLaunchAtLogin()
        }
    }

    // MARK: - Computed Properties
    
    /// All tracked paths (defaults + custom)
    var allTrackedPaths: [TrackedPath] {
        [mainTrackedPath] + selectedCommonPaths + customTrackedPaths
    }

    var mainTrackedPath: TrackedPath {
        TrackedPath.mainBasePath(url: mainBaseURL)
    }

    var availableCommonPaths: [TrackedPath] {
        TrackedPath.commonPathPresets(baseDirectory: mainBaseURL)
    }

    var selectedCommonPaths: [TrackedPath] {
        availableCommonPaths.filter { selectedCommonPathIDs.contains($0.id.uuidString) }
    }

    private var availableCommonPathIDStrings: Set<String> {
        Set(availableCommonPaths.map { $0.id.uuidString })
    }

    private var mainBaseURL: URL {
        URL(fileURLWithPath: mainBasePath, isDirectory: true)
    }
    
    /// Enabled tracked paths only
    var enabledTrackedPaths: [TrackedPath] {
        allTrackedPaths.filter { isPathEnabled($0) }
    }

    /// Enabled paths shown in overview path dropdown (exclude common paths)
    var enabledOverviewPaths: [TrackedPath] {
        enabledTrackedPaths.filter { !isCommonPath($0) }
    }
    
    /// All boundaries (standard + custom)
    var allBoundaries: Set<String> {
        BoundaryConfig.standardBoundaries.union(Set(customBoundaries))
    }
    
    /// Enabled boundaries only
    var enabledBoundaries: Set<String> {
        allBoundaries.filter { isBoundaryEnabled($0) }
    }
    
    // MARK: - Init
    
    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultBasePath = home.appendingPathComponent("dev", isDirectory: true).path

        // Load tracked paths
        if let data = UserDefaults.standard.data(forKey: Keys.trackedPaths),
           let paths = try? JSONDecoder().decode([TrackedPath].self, from: data) {
            self.customTrackedPaths = paths
        } else {
            self.customTrackedPaths = []
        }

        self.mainBasePath = UserDefaults.standard.string(forKey: Keys.mainBasePath) ?? defaultBasePath

        self.selectedCommonPathIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.selectedCommonPathIDs) ?? [])
        
        // Load custom boundaries
        self.customBoundaries = UserDefaults.standard.stringArray(forKey: Keys.customBoundaries) ?? []
        
        // Load disabled paths
        self.disabledPathIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.disabledPaths) ?? [])
        
        // Load disabled boundaries
        self.disabledBoundaryNames = Set(UserDefaults.standard.stringArray(forKey: Keys.disabledBoundaries) ?? [])

        // Load launch at login
        self.launchAtLogin = UserDefaults.standard.bool(forKey: Keys.launchAtLogin)
    }
    
    // MARK: - Path Management
    
    func addTrackedPath(_ path: TrackedPath) {
        guard !allTrackedPaths.contains(where: { $0.url == path.url }) else { return }
        customTrackedPaths.append(path)
    }
    
    func removeTrackedPath(_ path: TrackedPath) {
        customTrackedPaths.removeAll { $0.id == path.id }
        disabledPathIDs.remove(path.id.uuidString)
    }
    
    func isPathEnabled(_ path: TrackedPath) -> Bool {
        !disabledPathIDs.contains(path.id.uuidString)
    }
    
    func setPathEnabled(_ path: TrackedPath, enabled: Bool) {
        if enabled {
            disabledPathIDs.remove(path.id.uuidString)
        } else {
            disabledPathIDs.insert(path.id.uuidString)
        }
    }

    func setMainBasePath(_ url: URL) {
        mainBasePath = url.path

        let availableIDs = Set(availableCommonPaths.map { $0.id.uuidString })
        selectedCommonPathIDs = selectedCommonPathIDs.intersection(availableIDs)
    }

    func isCommonPathSelected(_ path: TrackedPath) -> Bool {
        selectedCommonPathIDs.contains(path.id.uuidString)
    }

    func setCommonPathSelected(_ path: TrackedPath, selected: Bool) {
        if selected {
            selectedCommonPathIDs.insert(path.id.uuidString)
        } else {
            selectedCommonPathIDs.remove(path.id.uuidString)
            disabledPathIDs.remove(path.id.uuidString)
        }
    }

    func isCommonPath(_ path: TrackedPath) -> Bool {
        availableCommonPathIDStrings.contains(path.id.uuidString)
    }
    
    // MARK: - Boundary Management
    
    func addBoundary(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !customBoundaries.contains(trimmed) else { return }
        customBoundaries.append(trimmed)
    }
    
    func removeBoundary(_ name: String) {
        customBoundaries.removeAll { $0 == name }
        disabledBoundaryNames.remove(name)
    }
    
    func isBoundaryEnabled(_ name: String) -> Bool {
        !disabledBoundaryNames.contains(name)
    }
    
    func setBoundaryEnabled(_ name: String, enabled: Bool) {
        if enabled {
            disabledBoundaryNames.remove(name)
        } else {
            disabledBoundaryNames.insert(name)
        }
    }
    
    // MARK: - Persistence
    
    private func saveTrackedPaths() {
        if let data = try? JSONEncoder().encode(customTrackedPaths) {
            UserDefaults.standard.set(data, forKey: Keys.trackedPaths)
        }
    }
    
    private func saveCustomBoundaries() {
        UserDefaults.standard.set(customBoundaries, forKey: Keys.customBoundaries)
    }
    
    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[SettingsStore] Failed to update launch at login: \(error)")
        }
    }
}
