import Foundation
import SwiftUI
import ServiceManagement

/// Observable settings store managing user preferences via UserDefaults
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    static let defaultScanIgnoreNames: Set<String> = [
        ".DS_Store",
        ".localized",
        "Thumbs.db",
        "desktop.ini"
    ]

    // MARK: - Keys

    private enum Keys {
        static let trackedPaths = "trackedPaths"
        static let customBoundaries = "customBoundaries"
        static let customScanIgnores = "customScanIgnores"
        static let disabledPaths = "disabledPaths"
        static let disabledBoundaries = "disabledBoundaries"
        static let launchAtLogin = "launchAtLogin"
        static let mainBasePath = "mainBasePath"
        static let selectedCommonPathIDs = "selectedCommonPathIDs"
        static let hasPendingScopeChanges = "hasPendingScopeChanges"
        static let categoryHistoryRetentionDays = "categoryHistoryRetentionDays"
        static let automaticFullScanIntervalHours = "automaticFullScanIntervalHours"
        static let automaticFullScanIntervalUserTouched = "automaticFullScanIntervalUserTouched"
        static let adaptiveFullScanIntervalApplied = "adaptiveFullScanIntervalApplied"
        static let legacyTrackingStartedAt = "trackingStartedAt"
    }

    // MARK: - Constants

    static let defaultCategoryHistoryRetentionDays = 30
    static let defaultAutomaticFullScanIntervalHours = 24
    static let automaticFullScanIntervalPresetHours = [24, 48, 72, 168, 336]

    // MARK: - Properties

    /// User-configured tracked paths (additional to defaults)
    var customTrackedPaths: [TrackedPath] {
        didSet { saveTrackedPaths() }
    }

    private(set) var availableCommonPaths: [TrackedPath]

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

    /// User-added scan ignore names
    var customScanIgnores: [String] {
        didSet { saveCustomScanIgnores() }
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

    /// Scope changes pending apply/reset
    var hasPendingScopeChanges: Bool {
        didSet { UserDefaults.standard.set(hasPendingScopeChanges, forKey: Keys.hasPendingScopeChanges) }
    }

    /// Category history retention period in days (default 30)
    var categoryHistoryRetentionDays: Int {
        didSet { UserDefaults.standard.set(categoryHistoryRetentionDays, forKey: Keys.categoryHistoryRetentionDays) }
    }

    /// Maximum time between periodic full rescans.
    var automaticFullScanIntervalHours: Int {
        didSet { UserDefaults.standard.set(automaticFullScanIntervalHours, forKey: Keys.automaticFullScanIntervalHours) }
    }

    /// User changed the periodic rescan picker (stops one-shot adaptive updates).
    var automaticFullScanIntervalUserTouched: Bool {
        didSet {
            UserDefaults.standard.set(automaticFullScanIntervalUserTouched, forKey: Keys.automaticFullScanIntervalUserTouched)
        }
    }

    /// After the first successful full scan, we may set `automaticFullScanIntervalHours` once from duration.
    var adaptiveFullScanIntervalApplied: Bool {
        didSet {
            UserDefaults.standard.set(adaptiveFullScanIntervalApplied, forKey: Keys.adaptiveFullScanIntervalApplied)
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

    var selectedCommonPaths: [TrackedPath] {
        availableCommonPaths.filter { selectedCommonPathIDs.contains($0.id.uuidString) }
    }

    var recommendedCommonPaths: [TrackedPath] {
        availableCommonPaths.filter(\.isRecommendedExtra)
    }

    var optionalCommonPaths: [TrackedPath] {
        availableCommonPaths.filter { !$0.isRecommendedExtra }
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

    /// All ignored file/folder names used during scan
    var allScanIgnoreNames: Set<String> {
        Self.defaultScanIgnoreNames.union(Set(customScanIgnores))
    }

    /// Enabled boundaries only
    var enabledBoundaries: Set<String> {
        allBoundaries.filter { isBoundaryEnabled($0) }
    }

    var automaticFullScanInterval: TimeInterval {
        TimeInterval(automaticFullScanIntervalHours * 60 * 60)
    }

    // MARK: - Init

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultBasePath = home.path

        // Load tracked paths
        if let data = UserDefaults.standard.data(forKey: Keys.trackedPaths),
           let paths = try? JSONDecoder().decode([TrackedPath].self, from: data) {
            self.customTrackedPaths = paths
        } else {
            self.customTrackedPaths = []
        }

        let initialMainBasePath = UserDefaults.standard.string(forKey: Keys.mainBasePath) ?? defaultBasePath
        self.mainBasePath = initialMainBasePath

        self.selectedCommonPathIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.selectedCommonPathIDs) ?? [])

        // Load custom boundaries
        self.customBoundaries = UserDefaults.standard.stringArray(forKey: Keys.customBoundaries) ?? []

        // Load custom scan ignores
        self.customScanIgnores = UserDefaults.standard.stringArray(forKey: Keys.customScanIgnores) ?? []

        // Load disabled paths
        self.disabledPathIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.disabledPaths) ?? [])

        // Load disabled boundaries
        self.disabledBoundaryNames = Set(UserDefaults.standard.stringArray(forKey: Keys.disabledBoundaries) ?? [])

        // Load launch at login
        self.launchAtLogin = UserDefaults.standard.bool(forKey: Keys.launchAtLogin)

        self.hasPendingScopeChanges = UserDefaults.standard.bool(forKey: Keys.hasPendingScopeChanges)

        // Load category history retention days (default 30)
        let savedRetentionDays = UserDefaults.standard.integer(forKey: Keys.categoryHistoryRetentionDays)
        self.categoryHistoryRetentionDays = savedRetentionDays > 0 ? savedRetentionDays : Self.defaultCategoryHistoryRetentionDays

        let savedAutomaticFullScanHours = UserDefaults.standard.integer(forKey: Keys.automaticFullScanIntervalHours)
        if Self.automaticFullScanIntervalPresetHours.contains(savedAutomaticFullScanHours) {
            self.automaticFullScanIntervalHours = savedAutomaticFullScanHours
        } else {
            self.automaticFullScanIntervalHours = Self.defaultAutomaticFullScanIntervalHours
        }

        self.automaticFullScanIntervalUserTouched = UserDefaults.standard.bool(forKey: Keys.automaticFullScanIntervalUserTouched)
        self.adaptiveFullScanIntervalApplied = UserDefaults.standard.bool(forKey: Keys.adaptiveFullScanIntervalApplied)
        self.availableCommonPaths = Self.loadAvailableCommonPaths(
            for: URL(fileURLWithPath: initialMainBasePath, isDirectory: true)
        )
        self.selectedCommonPathIDs.formIntersection(Set(self.availableCommonPaths.map { $0.id.uuidString }))

        UserDefaults.standard.removeObject(forKey: Keys.legacyTrackingStartedAt)
    }

    /// Call when the user picks a preset in Settings (not for adaptive updates).
    func markAutomaticFullScanIntervalChosenByUser() {
        automaticFullScanIntervalUserTouched = true
    }

    /// After the first successful full scan, pick an interval from wall-clock duration unless the user already customized it.
    func applyAdaptiveFullScanIntervalIfNeeded(scanDuration: TimeInterval) {
        guard !automaticFullScanIntervalUserTouched else { return }
        guard !adaptiveFullScanIntervalApplied else { return }

        let hours = Self.recommendedFullScanIntervalHours(forScanDuration: scanDuration)
        adaptiveFullScanIntervalApplied = true
        automaticFullScanIntervalHours = hours
    }

    static func recommendedFullScanIntervalHours(forScanDuration seconds: TimeInterval) -> Int {
        switch seconds {
        case ..<300: 24
        case ..<1200: 48
        case ..<3600: 72
        default: 168
        }
    }

    // MARK: - Path Management

    func addTrackedPath(_ path: TrackedPath) {
        guard !allTrackedPaths.contains(where: { $0.url == path.url }) else { return }
        customTrackedPaths.append(path)
        markScopeChanged()
    }

    func removeTrackedPath(_ path: TrackedPath) {
        let beforeCount = customTrackedPaths.count
        customTrackedPaths.removeAll { $0.id == path.id }
        disabledPathIDs.remove(path.id.uuidString)
        if customTrackedPaths.count != beforeCount {
            markScopeChanged()
        }
    }

    func isPathEnabled(_ path: TrackedPath) -> Bool {
        !disabledPathIDs.contains(path.id.uuidString)
    }

    func setPathEnabled(_ path: TrackedPath, enabled: Bool) {
        let wasEnabled = isPathEnabled(path)
        guard wasEnabled != enabled else { return }

        if enabled {
            disabledPathIDs.remove(path.id.uuidString)
        } else {
            disabledPathIDs.insert(path.id.uuidString)
        }

        markScopeChanged()
    }

    func setMainBasePath(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard mainBasePath != standardizedURL.path else { return }
        mainBasePath = standardizedURL.path
        refreshAvailableCommonPaths(for: standardizedURL)

        let availableIDs = Set(availableCommonPaths.map { $0.id.uuidString })
        selectedCommonPathIDs = selectedCommonPathIDs.intersection(availableIDs)
        markScopeChanged()
    }

    func isCommonPathSelected(_ path: TrackedPath) -> Bool {
        selectedCommonPathIDs.contains(path.id.uuidString)
    }

    func setCommonPathSelected(_ path: TrackedPath, selected: Bool) {
        let currentlySelected = selectedCommonPathIDs.contains(path.id.uuidString)
        guard currentlySelected != selected else { return }

        if selected {
            selectedCommonPathIDs.insert(path.id.uuidString)
        } else {
            selectedCommonPathIDs.remove(path.id.uuidString)
            disabledPathIDs.remove(path.id.uuidString)
        }

        markScopeChanged()
    }

    func applyRecommendedExtras(for baseURL: URL) {
        let standardizedBase = baseURL.standardizedFileURL.path
        var updatedSelection = selectedCommonPathIDs

        for path in recommendedCommonPaths {
            let candidate = path.url.standardizedFileURL.path
            let isCovered = candidate == standardizedBase
                || candidate.hasPrefix(standardizedBase == "/" ? "/" : standardizedBase + "/")

            if isCovered {
                updatedSelection.remove(path.id.uuidString)
                disabledPathIDs.remove(path.id.uuidString)
            } else {
                updatedSelection.insert(path.id.uuidString)
            }
        }

        guard updatedSelection != selectedCommonPathIDs else { return }
        selectedCommonPathIDs = updatedSelection
        markScopeChanged()
    }

    func clearPendingScopeChanges() {
        hasPendingScopeChanges = false
    }

    func isCommonPath(_ path: TrackedPath) -> Bool {
        availableCommonPathIDStrings.contains(path.id.uuidString)
    }

    func addScanIgnore(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let lowered = trimmed.lowercased()
        let existing = allScanIgnoreNames.map { $0.lowercased() }
        guard !existing.contains(lowered) else { return }

        customScanIgnores.append(trimmed)
    }

    func removeScanIgnore(_ name: String) {
        customScanIgnores.removeAll { $0 == name }
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

    private func saveCustomScanIgnores() {
        UserDefaults.standard.set(customScanIgnores, forKey: Keys.customScanIgnores)
    }

    private func refreshAvailableCommonPaths(for baseURL: URL) {
        availableCommonPaths = Self.loadAvailableCommonPaths(for: baseURL)
    }

    private func markScopeChanged() {
        hasPendingScopeChanges = true
    }

    private static func loadAvailableCommonPaths(for baseURL: URL) -> [TrackedPath] {
        TrackedPath.commonPathPresets(baseDirectory: baseURL)
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
