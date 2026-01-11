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
        static let drillDownThreshold = "drillDownThreshold"
        static let launchAtLogin = "launchAtLogin"
    }
    
    // MARK: - Properties
    
    /// User-configured tracked paths (additional to defaults)
    var customTrackedPaths: [TrackedPath] {
        didSet { saveTrackedPaths() }
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
    
    /// Drill-down threshold percentage (0.0-1.0)
    var drillDownThreshold: Double {
        didSet { UserDefaults.standard.set(drillDownThreshold, forKey: Keys.drillDownThreshold) }
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
        TrackedPath.defaultPaths + customTrackedPaths
    }
    
    /// Enabled tracked paths only
    var enabledTrackedPaths: [TrackedPath] {
        allTrackedPaths.filter { isPathEnabled($0) }
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
        // Load tracked paths
        if let data = UserDefaults.standard.data(forKey: Keys.trackedPaths),
           let paths = try? JSONDecoder().decode([TrackedPath].self, from: data) {
            self.customTrackedPaths = paths
        } else {
            self.customTrackedPaths = []
        }
        
        // Load custom boundaries
        self.customBoundaries = UserDefaults.standard.stringArray(forKey: Keys.customBoundaries) ?? []
        
        // Load disabled paths
        self.disabledPathIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.disabledPaths) ?? [])
        
        // Load disabled boundaries
        self.disabledBoundaryNames = Set(UserDefaults.standard.stringArray(forKey: Keys.disabledBoundaries) ?? [])
        
        // Load threshold (default 70%)
        let threshold = UserDefaults.standard.double(forKey: Keys.drillDownThreshold)
        self.drillDownThreshold = threshold > 0 ? threshold : 0.7
        
        // Load launch at login
        self.launchAtLogin = UserDefaults.standard.bool(forKey: Keys.launchAtLogin)
    }
    
    // MARK: - Path Management
    
    func addTrackedPath(_ path: TrackedPath) {
        guard !customTrackedPaths.contains(where: { $0.url == path.url }) else { return }
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
