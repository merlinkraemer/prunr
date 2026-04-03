import AppKit
import OSLog
import SwiftUI

// MARK: - Custom Panel for Arrow-less Dropdown

/// A custom panel that looks like native macOS menu bar dropdowns (no arrow)
final class DropdownPanel: NSPanel {
    var closesOnResignKey = true
    private var onClose: (() -> Void)?

    init(contentView: NSView, onClose: @escaping () -> Void) {
        self.onClose = onClose

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
            backing: .buffered,
            defer: false
        )

        // Create visual effect view for glass background
        let visualEffectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.material = .popover
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 14
        visualEffectView.layer?.masksToBounds = true

        // Add content as subview
        contentView.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        visualEffectView.addSubview(contentView)

        self.contentView = visualEffectView
        self.isFloatingPanel = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.backgroundColor = .clear
        self.hasShadow = true

        // Observe when window loses key status
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        // Close panel when it loses key status (user clicked outside)
        if closesOnResignKey, isVisible {
            orderOut(nil)
            onClose?()
        }
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        guard closesOnResignKey, isVisible else { return }
        orderOut(nil)
        onClose?()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class MenuBarManager: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    var popover: NSPopover?
    var panel: DropdownPanel?
    var isPopoverShown = false
    var usePanel = true // Use panel instead of popover for native dropdown look

    // For debugging menubar click reliability (ISS-013)
    private var lastClickTimestamp: Date?
    private let clickDebounceInterval: TimeInterval = 0.1 // 100ms

    private static let logger = Logger(subsystem: "com.prunr.MenuBarManager", category: "Reconciliation")


    /// Baseline service for growth tracking
    private let baselineService = BaselineService.shared
    private let recentChangeService = RecentChangeService.shared
    private let growthJournalService = GrowthJournalService.shared

    /// Right-click menu
    private var contextMenu: NSMenu?
    private var panelAutoCloseSuspensionCount = 0

    // MARK: - Scan & Growth Logic (Moved from ViewModel)

    // Published state for UI
    var categoryItems: [CategoryGrowthItem] = []  // Kept for legacy drill-down compatibility
    var growingCategories: [CategoryInventoryItem] = []  // Categories with active growth trends
    var stableCategories: [CategoryInventoryItem] = []   // Categories without growth trends
    var stableTotalBytes: Int64 = 0  // Sum of stable category sizes
    var reconciliationResult: DiskAccountingResult? = nil // Free-space accounting data
    var isDrilledDown: Bool = false // Tracks if user is in category detail view (ISS-037)
    var selectedInventoryCategory: CategoryInventoryItem? = nil // New inventory-based drill-down selection
    var selectedSubcategory: SubcategoryGroup? = nil
    var isSubcategoryDrillDown: Bool = false
    var subcategoryGroupsByCategory: [GrowthCategory: [SubcategoryGroup]] = [:]
    var hasCompletedInitialSubcategoryWarmup = false
    private var subcategoryBreakdownCacheGenerationByCategory: [GrowthCategory: UInt64] = [:]
    var subcategoryBreakdownLoadingCategories: Set<GrowthCategory> = []
    var growthContributorsBySubcategory: [String: [GrowthContributor]] = [:]
    var growthContributorCacheGeneration: UInt64 = 0
    private var currentInventorySnapshotIDsByPath: [UUID: Int64] = [:]
    private var currentGrowthBaselineSnapshotIDsByPath: [UUID: Int64] = [:]
    @ObservationIgnored
    private var subcategoryBreakdownLoadTasks: [GrowthCategory: Task<SubcategoryBreakdownLoadResult, Never>] = [:]
    var monitoredPathName: String = ""
    var enabledPathCount: Int {
        SettingsStore.shared.enabledTrackedPaths.count
    }

    private enum SubcategoryBreakdownLoadResult {
        case loaded([SubcategoryGroup])
        case skipped
    }

    private struct GrowthPresentationState {
        let growingCategories: [CategoryInventoryItem]
        let stableCategories: [CategoryInventoryItem]
        let stableTotalBytes: Int64
        let subcategoryGroupsByCategory: [GrowthCategory: [SubcategoryGroup]]
    }

    /// Extract folder name from path for tag display
    private func folderName(from path: URL) -> String {
        let lastComponent = path.lastPathComponent
        return lastComponent.isEmpty ? "Root" : lastComponent
    }

    /// Get folder names for all enabled paths
    var folderNames: [String] {
        SettingsStore.shared.enabledTrackedPaths.map { folderName(from: $0.url) }
    }
    private var scanTrackedPathOrderByID: [UUID: Int] = [:]
    private var scanTrackedPathCount = 0
    private var scanFilesScannedByPathID: [UUID: Int] = [:]

    var monitoredPathDisplay: String {
        // Full path for header display with tilde notation (e.g., "~/dev" instead of "/Users/username/dev")
        if let path = primaryTrackedPath() {
            let fullPath = path.url.path
            let homePath = FileManager.default.homeDirectoryForCurrentUser.path

            // Convert to tilde path if in home directory
            if fullPath.hasPrefix(homePath) {
                let relativePath = String(fullPath.dropFirst(homePath.count))
                let cleanRelativePath = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
                return "~/" + cleanRelativePath
            }

            return fullPath
        }
        return "No path configured"
    }

    private func primaryTrackedPath(from paths: [TrackedPath]? = nil) -> TrackedPath? {
        let candidates = effectiveTrackedPaths(from: paths ?? SettingsStore.shared.enabledTrackedPaths)
        guard !candidates.isEmpty else { return nil }

        if let mainPath = candidates.first(where: { $0.id == ScanPathPreset.mainBasePathID }) {
            return mainPath
        }

        let overviewPaths = candidates.filter { !SettingsStore.shared.isCommonPath($0) }
        if let overviewPath = overviewPaths.max(by: { trackedPathPriority($0) < trackedPathPriority($1) }) {
            return overviewPath
        }

        return preferredTrackedPath(from: candidates)
    }

    private func prepareAggregateScanProgress(for trackedPaths: [TrackedPath]) {
        scanTrackedPathOrderByID = Dictionary(
            uniqueKeysWithValues: trackedPaths.enumerated().map { index, trackedPath in
                (trackedPath.id, index)
            }
        )
        scanTrackedPathCount = trackedPaths.count
        scanFilesScannedByPathID = [:]
    }

    private func resetAggregateScanProgress() {
        scanTrackedPathOrderByID = [:]
        scanTrackedPathCount = 0
        scanFilesScannedByPathID = [:]
    }

    private func applyAggregateScanProgress(for trackedPath: TrackedPath, progress: ScanService.ScanProgress) {
        let clamped = max(0.0, min(1.0, progress.percentage))
        let pathIndex = scanTrackedPathOrderByID[trackedPath.id] ?? 0

        scanFilesScannedByPathID[trackedPath.id] = progress.foldersScanned

        let completedFileCount = scanFilesScannedByPathID.reduce(into: 0) { total, entry in
            guard let otherPathIndex = scanTrackedPathOrderByID[entry.key], otherPathIndex < pathIndex else { return }
            total += entry.value
        }

        filesScanned = completedFileCount + progress.foldersScanned

        if scanTrackedPathCount > 1 {
            let aggregateProgress = (Double(pathIndex) + clamped) / Double(scanTrackedPathCount)
            scanProgressPercentage = aggregateProgress >= 1.0 ? 0.99 : aggregateProgress
            scanEstimatedTotalFiles = max(
                filesScanned,
                completedFileCount + max(progress.totalFiles, progress.foldersScanned)
            )
            hasReliableScanProgressEstimate = true
        } else {
            scanProgressPercentage = clamped >= 1.0 ? 0.99 : clamped
            scanEstimatedTotalFiles = max(progress.totalFiles, progress.foldersScanned)
            hasReliableScanProgressEstimate = progress.hasReliableEstimate
        }

        scanCurrentPath = progress.currentPath

        let rootPath = trackedPath.url.path
        let displayPath = displayPath(for: progress.currentPath, rootPath: rootPath)
        scanCurrentPathDisplay = displayPath
        scanProgress = "Scanning \(displayPath)"

        // Live category fill-in: merge partial totals from this path into the aggregate.
        // Only applies when the progress update includes a category snapshot (~every 2s).
        if let partialTotals = progress.categoryTotals, !partialTotals.isEmpty {
            applyPartialCategoryTotals(from: trackedPath, totals: partialTotals)
        }
    }

    /// Merges partial category totals arriving from an in-progress scan into `stableCategories`
    /// so the user sees categories appearing and growing live during the scan.
    ///
    /// - Parameters:
    ///   - trackedPath: The path whose scan produced these partial totals.
    ///   - totals: Partial `[GrowthCategory: Int64]` accumulated so far by ScanService.
    private func applyPartialCategoryTotals(from trackedPath: TrackedPath, totals: [GrowthCategory: Int64]) {
        // Merge the new totals into the aggregate (replace any existing entry from this path
        // since these totals are cumulative within the scan, not incremental per callback).
        // For multi-path parallel scans we keep a running merge across all paths;
        // the simplest correct approach is to just overwrite the values for each received key
        // since the totals from a single path are always monotonically increasing.
        for (category, bytes) in totals {
            partialScanCategoryTotals[category, default: 0] = max(
                partialScanCategoryTotals[category, default: 0],
                bytes
            )
        }

        // Convert partial totals to CategoryInventoryItem (no growth trend during scan)
        // and push to stableCategories so views see them live.
        let liveCategories = partialScanCategoryTotals
            .filter { $0.value > 0 }
            .map { category, bytes in
                CategoryInventoryItem(
                    category: category,
                    currentSizeBytes: bytes,
                    growthTrend: nil,
                    recentGrowthStory: nil
                )
            }
            .sorted { $0.currentSizeBytes > $1.currentSizeBytes }

        // Only update if there's actual data — avoids a flash of empty categories.
        guard !liveCategories.isEmpty else { return }

        // During scan, show partial data in stableCategories (growing categories are unknown yet)
        stableCategories = liveCategories
        stableTotalBytes = liveCategories.reduce(0) { $0 + $1.currentSizeBytes }
    }

    private func preferredTrackedPath(from paths: [TrackedPath]? = nil) -> TrackedPath? {
        let candidates = effectiveTrackedPaths(from: paths ?? SettingsStore.shared.enabledTrackedPaths)
        guard !candidates.isEmpty else { return nil }

        return candidates.max { lhs, rhs in
            trackedPathPriority(lhs) < trackedPathPriority(rhs)
        }
    }

    private func trackedPathPriority(_ path: TrackedPath) -> Int {
        let pathDepth = path.url.standardizedFileURL.pathComponents.count
        let isMainBasePath = path.id == ScanPathPreset.mainBasePathID

        if isMainBasePath {
            return pathDepth
        }

        return 10_000 + pathDepth
    }

    private func effectiveTrackedPaths(from paths: [TrackedPath]) -> [TrackedPath] {
        let sorted = paths.sorted {
            let lhs = $0.url.standardizedFileURL.path
            let rhs = $1.url.standardizedFileURL.path
            if lhs.count == rhs.count {
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            return lhs.count < rhs.count
        }

        var effective: [TrackedPath] = []
        for path in sorted {
            let candidate = path.url.standardizedFileURL.path
            let isCovered = effective.contains { existing in
                let root = existing.url.standardizedFileURL.path
                return candidate == root || candidate.hasPrefix(root == "/" ? "/" : root + "/")
            }

            if !isCovered {
                effective.append(path)
            }
        }

        return effective
    }

    private func shouldAutoWatchTrackedPath(_ path: TrackedPath) -> Bool {
        let standardized = path.url.standardizedFileURL
        // Don't watch root — too noisy and not a realistic use case
        if standardized.path == "/" {
            return false
        }
        return true
    }

    var isLoading = false {
        didSet { updateMenuBarActivityEffect() }
    }
    var isAutoScanning = false { // Visual feedback for background scans
        didSet { updateMenuBarActivityEffect() }
    }
    var errorMessage: String?
    var noBaseline = false

    /// True when FSEvents is active and tracking changes but no full baseline snapshot exists yet.
    /// In this mode, category sizes represent accumulated deltas since tracking started,
    /// not absolute disk usage.
    var isDeltasOnlyMode: Bool {
        guard noBaseline else { return false }
        let settings = SettingsStore.shared
        return !settings.enabledTrackedPaths.isEmpty && settings.trackingStartedAt != nil
    }

    var scanProgress: String = ""
    var scanCurrentPath: String = ""
    var scanCurrentPathDisplay: String = ""
    var filesScanned: Int = 0
    var scanEstimatedTotalFiles: Int = 0
    var hasReliableScanProgressEstimate = false

    /// Partial category totals accumulated across all currently-scanning paths.
    /// Updated live every ~2 seconds during scan so the UI can show categories filling in.
    /// Reset to empty when a scan starts or finishes.
    private var partialScanCategoryTotals: [GrowthCategory: Int64] = [:]

    var isAnalyzingChanges: Bool = false {
        didSet { updateMenuBarActivityEffect() }
    }
    var isCleaningUp: Bool = false {
        didSet { updateMenuBarActivityEffect() }
    }
    // Percentage progress (0.0-1.0) for progress bar (ISS-033)
    var scanProgressPercentage: Double = 0.0

    // Scan timing for minimum display duration
    private var scanStartTime: Date?
    private let minimumDisplayDuration: TimeInterval = 0.8 // 800ms

    // Disk space state
    var totalBytes: Int64 = 0
    var usedBytes: Int64 = 0
    var freeBytes: Int64 = 0
    var monitoredPathSizeBytes: Int64 = 0
    var pathSizeBytesByID: [UUID: Int64] = [:]
    var isCalculatingPathSize = false

    // Cache for disk space updates (avoid excessive disk checks)
    private var lastFreeSpaceUpdate: Date?

    // Continuous update timer for GB meter (ISS-042)
    // Cleanup only: these are invalidated/cancelled during deinit without touching UI state.
    @ObservationIgnored
    nonisolated(unsafe) private var updateTimer: Timer?
    @ObservationIgnored
    nonisolated(unsafe) private var activityPulseTimer: Timer?
    private var pulseAtLowAlpha = false

    // Event-driven lightweight scan automation
    @ObservationIgnored
    nonisolated(unsafe) private var fileEventsWatcher: FSEventsWatcher?
    private var watchedPaths: [String] = []
    @ObservationIgnored
    nonisolated(unsafe) private var recentChangeTask: Task<Void, Never>?
    private var isInventoryRefreshInProgress = false
    private var pendingRecentChangePaths: Set<URL> = []
    private(set) var lastAutomaticScanAt: Date?
    var lastDetectedChangeAt: Date?
    private var isUnderDiskPressure = false
    private var lastFileEventAt: Date?
    var hasPendingRecentChanges = false
    var isProcessingRecentChanges = false
    /// True when incremental deltas have been applied since the last full scan snapshot.
    /// Routes subcategory drill-down reads to the working set instead of the stale snapshot.
    private var hasIncrementalDeltasSinceSnapshot = false
    /// True only when the user explicitly tapped the "Check Growth" button.
    var isCheckingGrowth = false {
        didSet { updateMenuBarActivityEffect() }
    }
    var isAcceptingGrowth = false
    var lastAcceptedGrowthAt: Date? = nil
    private var suppressGrowthIndicators = false

    // Silent background reconciliation
    private var lastReconciliationAt: Date?
    private var isReconciling = false
    @ObservationIgnored
    nonisolated(unsafe) private var reconciliationTask: Task<Void, Never>?
    private var upgradeRetryCount = 0
    /// Set when background scan fails repeatedly so the UI can surface a retry option.
    var backgroundScanError: Error? = nil

    var lastScanStatusText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full

        if isCheckingGrowth {
            return "Checking for changes…"
        }

        if hasPendingRecentChanges {
            return "Changes detected"
        }

        if let lastChangeAt = lastDetectedChangeAt {
            let relative = formatter.localizedString(for: lastChangeAt, relativeTo: Date())
            return "Last update: \(relative)"
        }

        guard let lastScanAt = lastAutomaticScanAt else {
            return "Last update: never"
        }

        let relative = formatter.localizedString(for: lastScanAt, relativeTo: Date())
        return "No changes (scanned \(relative))"
    }

    private let normalRecentChangeDebounce: TimeInterval = 1.5
    private let pressureRecentChangeDebounce: TimeInterval = 0.75

    static var shared: MenuBarManager?

    // MARK: - Init

    override init() {
        super.init()
        Self.shared = self
        setupMenuBar()
        setupContextMenu()
        updateFreeSpace()

        // Start continuous updates (ISS-042)
        startRealtimeUpdates()
        configureFileWatcherIfNeeded()
    }

    private func setupMenuBar() {
        // Create status item in menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "Prunr"
            button.action = #selector(handleButtonClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.alphaValue = 1.0
        }

        // Configure popover (fallback)
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 480)
        popover?.behavior = .transient
        popover?.delegate = self
        popover?.contentViewController = NSHostingController(rootView: MenuBarView(manager: self))

        // Configure panel for native dropdown look (no arrow)
        let panelContent = NSHostingView(rootView: MenuBarView(manager: self))
        panelContent.frame = NSRect(x: 0, y: 0, width: 320, height: 480)

        panel = DropdownPanel(contentView: panelContent) { [weak self] in
            self?.isPopoverShown = false
            // Reset auto-close suspension state when panel closes via focus loss
            self?.panelAutoCloseSuspensionCount = 0
            self?.panel?.closesOnResignKey = true
        }
    }

    private func setupContextMenu() {
        let menu = NSMenu()

        #if DEBUG
        // Create Test Data (Debug only)
        let createDataItem = NSMenuItem(
            title: "Create Test Data",
            action: #selector(createTestDataAction),
            keyEquivalent: ""
        )
        createDataItem.target = self
        menu.addItem(createDataItem)

        menu.addItem(NSMenuItem.separator())
        #endif

        // Settings...
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit Prunr
        let quitItem = NSMenuItem(
            title: "Quit Prunr",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        contextMenu = menu
    }

    @objc private func handleButtonClick() {
        let now = Date()

        // Debounce rapid clicks to prevent double-click issues (ISS-013)
        // Check this FIRST before any event handling to catch all rapid clicks
        if let lastClick = lastClickTimestamp,
           now.timeIntervalSince(lastClick) < clickDebounceInterval {
            return
        }
        lastClickTimestamp = now

        // The action is called for both left and right mouse up
        // We need to determine which type of click occurred
        if let event = NSApp.currentEvent {
            // Right-click shows menu, left-click shows popover
            if event.type == .rightMouseUp {
                showContextMenu()
                return
            }
        }

        // Default to showing popover for left-click or when event is unavailable
        togglePopover()
    }

    private func showContextMenu() {
        guard let menu = contextMenu, let button = statusItem?.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func openSettings() {
        // Close popover if open
        if let popover = popover, popover.isShown {
            popover.performClose(nil)
            isPopoverShown = false
        }

        // Small delay to ensure popover is fully closed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)

            // Bring Settings window to front immediately - ISS-024
            // Use a very short delay (50ms) to let window creation complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.activate()

                // Find settings window by title
                if let settingsWindow = NSApp.windows.first(where: {
                    $0.title.contains("Settings")
                }) {
                    // Ensure window behavior is correct
                    settingsWindow.hidesOnDeactivate = false

                    // Temporarily elevate window level to bring to front
                    let originalLevel = settingsWindow.level
                    settingsWindow.level = .floating
                    settingsWindow.makeKeyAndOrderFront(nil)
                    settingsWindow.orderFrontRegardless()

                    // Reset to normal level immediately after focusing (no delay)
                    settingsWindow.level = originalLevel
                } else {
                    // If window not found yet, try once more with a longer delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.activate()
                        if let settingsWindow = NSApp.windows.first(where: { $0.title.contains("Settings") }) {
                            settingsWindow.hidesOnDeactivate = false
                            settingsWindow.level = .floating
                            settingsWindow.makeKeyAndOrderFront(nil)
                            settingsWindow.orderFrontRegardless()
                            settingsWindow.level = .normal
                        }
                    }
                }
            }
        }
    }


    @objc private func resetBaseline() {
        guard confirmDeleteAllSnapshots() else { return }
        Task { await performReset() }
    }

    /// Public method to reset baseline (called by View)
    func performReset() async {
        do {
            try await baselineService.resetBaseline()
            await refreshAfterBaselineReset()
        } catch {
            print("[MenuBarManager] Failed to reset baseline: \(error)")
        }
    }

    /// Applies scope changes that require deleting existing snapshots, then refreshes
    /// all visible menu-bar state so the popover reflects the new scope immediately.
    func applyScopeChanges() async throws {
        try await baselineService.resetBaseline()
        await DatabaseCleanupService.shared.performAutoCleanup()
        await refreshAfterBaselineReset()
        configureFileWatcherIfNeeded()
        await updatePathSize()
    }

    private func refreshAfterBaselineReset() async {
        clearInventoryState()
        backgroundScanError = nil
        errorMessage = nil
        hasPendingRecentChanges = false
        pendingRecentChangePaths.removeAll()
        lastDetectedChangeAt = nil
        lastAutomaticScanAt = nil
        hasIncrementalDeltasSinceSnapshot = false
        updateMonitoredPathName()
        updateFreeSpace()
        await checkBaseline()
    }

    private func confirmDeleteAllSnapshots() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete all snapshots?"
        alert.informativeText = "This removes all scan history. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func displayPath(for scannedPath: String, rootPath: String) -> String {
        let standardizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let standardizedScannedPath = URL(fileURLWithPath: scannedPath).standardizedFileURL.path

        if standardizedScannedPath == standardizedRoot {
            return "."
        }

        let rootPrefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
        if standardizedScannedPath.hasPrefix(rootPrefix) {
            let relativePath = String(standardizedScannedPath.dropFirst(rootPrefix.count))
            return relativePath.isEmpty ? "." : "./\(relativePath)"
        }

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if standardizedScannedPath.hasPrefix(homePath) {
            return "~" + String(standardizedScannedPath.dropFirst(homePath.count))
        }

        return standardizedScannedPath
    }

    private func snapshotIDsSignature(_ snapshotIDsByPath: [UUID: Int64]) -> String? {
        guard !snapshotIDsByPath.isEmpty else { return nil }

        return snapshotIDsByPath
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { "\($0.key.uuidString):\($0.value)" }
            .joined(separator: "|")
    }

    private func trackedPathsByID(_ trackedPaths: [TrackedPath]) -> [UUID: TrackedPath] {
        Dictionary(uniqueKeysWithValues: trackedPaths.map { ($0.id, $0) })
    }

    private func createBaselines(
        for trackedPaths: [TrackedPath],
        progressCallback: @escaping (TrackedPath, ScanService.ScanProgress) -> Void
    ) async throws -> [UUID: Snapshot] {
        // Reset any leftover cancellation state from a previous scan before starting.
        await ScanService.shared.resetCancellationForNewBatch()

        // `effectiveTrackedPaths` already deduplicates nested paths, so all paths in
        // `trackedPaths` are independent (no path is a subpath of another). Each gets
        // its own snapshot, so there are no DB write conflicts — safe to scan in parallel.
        guard trackedPaths.count > 1 else {
            // Single path: run inline (no task group overhead)
            var snapshotsByPath: [UUID: Snapshot] = [:]
            if let trackedPath = trackedPaths.first {
                scanProgress = "Scanning \(trackedPath.displayName)..."
                scanCurrentPath = trackedPath.url.path
                scanCurrentPathDisplay = "."
                let snapshot = try await baselineService.createBaseline(
                    trackedPath: trackedPath,
                    progress: { progress in progressCallback(trackedPath, progress) }
                )
                snapshotsByPath[trackedPath.id] = snapshot
            }
            return snapshotsByPath
        }

        // Multiple independent paths: scan concurrently via TaskGroup.
        // Any thrown error cancels the group (and all remaining scans) immediately.
        return try await withThrowingTaskGroup(of: (UUID, Snapshot).self) { group in
            for trackedPath in trackedPaths {
                let capturedPath = trackedPath
                group.addTask {
                    let snapshot = try await self.baselineService.createBaseline(
                        trackedPath: capturedPath,
                        progress: { progress in progressCallback(capturedPath, progress) }
                    )
                    return (capturedPath.id, snapshot)
                }
            }

            var snapshotsByPath: [UUID: Snapshot] = [:]
            for try await (pathId, snapshot) in group {
                snapshotsByPath[pathId] = snapshot
            }
            return snapshotsByPath
        }
    }

    // MARK: - Scan & Growth Logic (Moved from ViewModel)

    // Properties are now synthesized by @Observable macro at class level
    // and initialized above.

    /// Loads inventory data with growth trends for the preferred enabled tracked path
    func loadInventory(isAutomatic: Bool = false, trackedPathsOverride: [TrackedPath]? = nil) async {
        // Prefer the most specific enabled tracked path to avoid scanning huge umbrella roots.
        let enabledPaths = effectiveTrackedPaths(from: trackedPathsOverride ?? SettingsStore.shared.enabledTrackedPaths)
        guard let trackedPath = primaryTrackedPath(from: enabledPaths) else {
            errorMessage = "No paths enabled in Settings"
            return
        }
        guard beginInventoryRefresh() else { return }
        defer { endInventoryRefresh() }

        isLoading = true
        backgroundScanError = nil
        errorMessage = nil
        noBaseline = false
        filesScanned = 0
        isAnalyzingChanges = false
        recentChangeTask?.cancel()
        recentChangeTask = nil
        pendingRecentChangePaths.removeAll()
        hasPendingRecentChanges = false
        scanProgress = "Scanning \(trackedPath.displayName)..."
        scanCurrentPath = trackedPath.url.path
        scanCurrentPathDisplay = "."
        prepareAggregateScanProgress(for: enabledPaths)
        // Start slightly above zero so the UI never appears stalled before the first callback lands.
        scanProgressPercentage = 0.03
        scanEstimatedTotalFiles = 0
        hasReliableScanProgressEstimate = false
        partialScanCategoryTotals = [:] // Reset live-fill data for this scan session

        // Record scan start time for minimum display duration
        let startTime = Date()
        scanStartTime = startTime

        var wasCancelled = false
        var completedSuccessfully = false
        var completedSnapshotsByPath: [UUID: Snapshot] = [:]

        // Create progress callback for updating UI during scan
        // Note: MainActor.run ensures UI updates happen on main thread
        let progressCallback: (TrackedPath, ScanService.ScanProgress) -> Void = { trackedPath, progress in
            Task { @MainActor in
                self.applyAggregateScanProgress(for: trackedPath, progress: progress)
            }
        }

        do {
            // First, take a new snapshot
            completedSnapshotsByPath = try await createBaselines(
                for: enabledPaths,
                progressCallback: progressCallback
            )

            // Briefly show real 100% only when scan is actually complete.
            scanProgressPercentage = 1.0
            hasReliableScanProgressEstimate = true
            scanProgress = "Finalizing scan..."
            try? await Task.sleep(for: .milliseconds(120))

            // Scanning is complete; now load inventory with trends
            isAnalyzingChanges = true
            scanProgress = "Analyzing inventory..."
            scanCurrentPath = ""
            scanCurrentPathDisplay = ""
            scanProgressPercentage = 1.0
            hasReliableScanProgressEstimate = true

            // Get inventory with growth trends
            let aggregation = await baselineService.getInventoryWithTrends(trackedPaths: enabledPaths)

            applyInventory(
                aggregation.inventory,
                snapshotIDsByPath: aggregation.latestSnapshotIdsByPath,
                growthBaselineSnapshotIDsByPath: aggregation.baselineSnapshotIdsByPath,
                invalidateSubcategoryCache: true
            )

            // Keep legacy categoryItems for drill-down compatibility during transition
            // TODO: Remove once drill-down is migrated to inventory-based
            categoryItems = []

            // Also compute disk accounting for free space tracking
            do {
                reconciliationResult = await baselineService.getDiskAccounting(
                    trackedPaths: enabledPaths,
                    primaryTrackedPath: trackedPath
                )
            }

            reconcileDrillDownSelection()
            scanProgress = ""
            scanCurrentPath = ""
            scanCurrentPathDisplay = ""
            completedSuccessfully = true

            // If this scan completes while in deltas-only mode, clear the marker — we now have
            // a full baseline so isDeltasOnlyMode becomes false automatically.
            if SettingsStore.shared.trackingStartedAt != nil {
                SettingsStore.shared.endDeltasOnlyMode()
            }

            let snapshotTimestamp = aggregation.latestSnapshotDate ?? Date()
            if !growingCategories.isEmpty {
                lastDetectedChangeAt = snapshotTimestamp
            }

            // Refresh storage space after scan (ISS-042)
            updateFreeSpace()
            hasPendingRecentChanges = !pendingRecentChangePaths.isEmpty
        } catch {
            if let baselineError = error as? BaselineService.BaselineError,
               case .insufficientSnapshots = baselineError {
                noBaseline = false
                growingCategories = []
                stableCategories = []
                stableTotalBytes = 0
                categoryItems = []
                subcategoryGroupsByCategory = [:]
                invalidateGrowthContributorCache()
                currentInventorySnapshotIDsByPath = [:]
                currentGrowthBaselineSnapshotIDsByPath = [:]
                reconciliationResult = nil
                reconcileDrillDownSelection()
            } else if let baselineError = error as? BaselineService.BaselineError,
               case .noBaseline = baselineError {
                noBaseline = true
                growingCategories = []
                stableCategories = []
                stableTotalBytes = 0
                categoryItems = []
                subcategoryGroupsByCategory = [:]
                invalidateGrowthContributorCache()
                currentInventorySnapshotIDsByPath = [:]
                currentGrowthBaselineSnapshotIDsByPath = [:]
                reconciliationResult = nil
                reconcileDrillDownSelection()
            } else if let scanError = error as? ScanError, case .cancelled = scanError {
                scanProgress = "Cancelled"
                scanCurrentPath = ""
                scanCurrentPathDisplay = ""
                isAnalyzingChanges = false
                wasCancelled = true
            } else {
                print("[MenuBarManager] Error loading inventory: \(error)")
                if !isAutomatic {
                    errorMessage = "Scan failed: \(error.localizedDescription)"
                }
            }
        }

        // Calculate elapsed time
        let elapsed = Date().timeIntervalSince(startTime)

        // Apply minimum display duration (skip on cancellation or if stop was pressed)
        let shouldSkipDelay = wasCancelled || scanStartTime == nil
        if !shouldSkipDelay && elapsed < minimumDisplayDuration {
            let delay = minimumDisplayDuration - elapsed
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
        }

        if !completedSnapshotsByPath.isEmpty && !wasCancelled {
            isCleaningUp = true
            scanProgress = "Cleaning up..."
            scanCurrentPath = ""
            scanCurrentPathDisplay = ""
            scanProgressPercentage = 1.0
            hasReliableScanProgressEstimate = true
            await DatabaseCleanupService.shared.performAutoCleanup()
            await growthJournalService.prune(retentionDays: SettingsStore.shared.categoryHistoryRetentionDays)
            isCleaningUp = false
        }

        isLoading = false
        hasIncrementalDeltasSinceSnapshot = false
        scanProgress = ""
        scanCurrentPath = ""
        scanCurrentPathDisplay = ""
        resetAggregateScanProgress()
        scanProgressPercentage = 0.0
        scanEstimatedTotalFiles = 0
        hasReliableScanProgressEstimate = false
        filesScanned = 0
        isAnalyzingChanges = false
        scanStartTime = nil
        partialScanCategoryTotals = [:] // Clear live-fill data after scan completes
        if completedSuccessfully {
            lastAutomaticScanAt = completedSnapshotsByPath.values.map(\.createdAt).max() ?? Date()
        }

        await updatePathSize()

        // Flush any FSEvents that arrived during the scan
        if !pendingRecentChangePaths.isEmpty {
            scheduleRecentChangeRefreshTask(after: 0.5)
        }
    }

    func loadInventoryFromLatestSnapshot(
        refreshedAt: Date? = nil,
        invalidateSubcategoryCache: Bool = false,
        force: Bool = false
    ) async {
        if force {
            isInventoryRefreshInProgress = true
        } else {
            guard beginInventoryRefresh() else { return }
        }
        defer { endInventoryRefresh() }

        let enabledPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
        guard let trackedPath = primaryTrackedPath(from: enabledPaths) else {
            noBaseline = true
            clearInventoryState()
            lastAutomaticScanAt = nil
            updateMonitoredPathName()
            return
        }

        do {
            let aggregation = await baselineService.getInventoryWithTrends(trackedPaths: enabledPaths)
            guard !aggregation.latestSnapshotIdsByPath.isEmpty else {
                noBaseline = true
                clearInventoryState()
                lastAutomaticScanAt = nil
                updateMonitoredPathName()
                return
            }

            noBaseline = false
            lastAutomaticScanAt = refreshedAt ?? aggregation.latestSnapshotDate
            errorMessage = nil
            applyInventory(
                aggregation.inventory,
                snapshotIDsByPath: aggregation.latestSnapshotIdsByPath,
                growthBaselineSnapshotIDsByPath: aggregation.baselineSnapshotIdsByPath,
                invalidateSubcategoryCache: invalidateSubcategoryCache
                    || snapshotIDsSignature(aggregation.latestSnapshotIdsByPath)
                        != snapshotIDsSignature(currentInventorySnapshotIDsByPath)
            )

            reconciliationResult = await baselineService.getDiskAccounting(
                trackedPaths: enabledPaths,
                primaryTrackedPath: trackedPath
            )

            updateMonitoredPathName()
        } catch {
            print("[MenuBarManager] Failed to load cached inventory: \(error)")
            errorMessage = "Couldn't load latest inventory"
            clearInventoryState()
        }
    }

    func refreshVisibleInventory() async {
        guard !isLoading, !isAutoScanning else { return }
        guard !isInventoryRefreshInProgress else { return }
        // Cancel any in-progress reconciliation — manual scan takes priority
        reconciliationTask?.cancel()
        reconciliationTask = nil
        isReconciling = false
        isAutoScanning = true
        defer { isAutoScanning = false }
        await loadInventory(isAutomatic: true)
        lastReconciliationAt = Date()
    }

    /// Accepts current growth by resetting baselines to the current working set sizes.
    /// Optimistic: clears visible growth indicators instantly, then commits to DB.
    func acceptGrowth() async {
        guard !isLoading, !isAutoScanning, !isCheckingGrowth else { return }
        let priorPresentationState = captureGrowthPresentationState()
        isAcceptingGrowth = true
        defer { isAcceptingGrowth = false }

        let enabledPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
        guard !enabledPaths.isEmpty else { return }

        suppressGrowthIndicators = true
        clearVisibleGrowthIndicators()

        do {
            for trackedPath in enabledPaths {
                try await baselineService.acceptGrowth(for: trackedPath)
            }

            suppressGrowthIndicators = false
            await loadInventoryFromLatestSnapshot(
                refreshedAt: Date(),
                invalidateSubcategoryCache: true,
                force: true
            )
            lastAcceptedGrowthAt = Date()
        } catch {
            suppressGrowthIndicators = false
            restoreGrowthPresentationState(priorPresentationState)
            errorMessage = "Couldn't accept growth: \(error.localizedDescription)"
        }
    }

    /// Lightweight growth check: flushes any pending FSEvents changes immediately
    /// without running a full filesystem scan.
    func checkGrowth() async {
        guard !isLoading, !isAutoScanning, !isProcessingRecentChanges else { return }
        isCheckingGrowth = true
        defer { isCheckingGrowth = false }
        // Cancel any pending debounced refresh so we can run immediately
        recentChangeTask?.cancel()
        recentChangeTask = nil

        if pendingRecentChangePaths.isEmpty {
            // Force a root-level refresh instead of just re-reading stale DB data
            let enabledPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
            for tp in enabledPaths {
                pendingRecentChangePaths.insert(tp.url.standardizedFileURL)
            }
        }
        await performRecentChangeRefresh()
    }

    /// Starts deltas-only tracking mode: enables FSEvents immediately without running a full scan.
    /// Categories will appear as file changes are detected. A background reconciliation scan
    /// fills in absolute sizes automatically after a delay.
    ///
    /// Call this from the onboarding "Start tracking" flow after the user has selected a folder.
    func startDeltasOnlyTracking() {
        let settings = SettingsStore.shared
        settings.beginDeltasOnlyMode()

        // noBaseline stays true — FSEvents feeds incremental data without a snapshot baseline.
        noBaseline = true

        // Ensure the file watcher is running immediately so we capture changes right away.
        configureFileWatcherIfNeeded()

        // Schedule a background reconciliation scan after 10 minutes to build the full picture.
        scheduleDeltasOnlyUpgrade()
    }

    /// Schedules a background full scan to upgrade from deltas-only to full inventory mode.
    /// Fires 10 minutes after initial tracking starts (or immediately on next app launch
    /// if 10 minutes have already elapsed since `trackingStartedAt`).
    func scheduleDeltasOnlyUpgrade() {
        let settings = SettingsStore.shared
        guard let startedAt = settings.trackingStartedAt else { return }

        let upgradeDelay: TimeInterval = 10 * 60 // 10 minutes
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = max(0, upgradeDelay - elapsed)

        reconciliationTask?.cancel()
        reconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            guard self.isDeltasOnlyMode else { return }
            await self.upgradeDeltasOnlyToFullInventory()
        }
    }

    /// Runs a silent full scan to upgrade from deltas-only mode to full inventory.
    /// When complete, clears the trackingStartedAt marker so isDeltasOnlyMode becomes false
    /// and the UI seamlessly switches to showing absolute category sizes.
    private func upgradeDeltasOnlyToFullInventory() async {
        guard isDeltasOnlyMode else { return }
        guard !isReconciling, !isLoading, !isAutoScanning, !isInventoryRefreshInProgress else {
            // Retry after a short delay
            reconciliationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.upgradeDeltasOnlyToFullInventory()
            }
            return
        }

        isReconciling = true
        defer {
            isReconciling = false
            reconciliationTask = nil
        }

        let enabledPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
        guard !enabledPaths.isEmpty else { return }

        do {
            _ = try await createBaselines(for: enabledPaths) { _, _ in }
        } catch {
            upgradeRetryCount += 1
            Self.logger.error("Background scan failed (attempt \(self.upgradeRetryCount)): \(error.localizedDescription)")

            if upgradeRetryCount >= 3 {
                backgroundScanError = error
            }

            // Exponential backoff: 30s → 60s → 120s, capped at 10 min
            let delay = min(30.0 * pow(2.0, Double(upgradeRetryCount - 1)), 600.0)
            reconciliationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.upgradeDeltasOnlyToFullInventory()
            }
            return
        }

        guard !Task.isCancelled else { return }

        upgradeRetryCount = 0
        backgroundScanError = nil

        // Clear deltas-only mode — full baseline now exists
        SettingsStore.shared.endDeltasOnlyMode()
        noBaseline = false

        // Reload inventory from the new snapshot (no user-visible loading state)
        await loadInventoryFromLatestSnapshot(refreshedAt: Date())
        lastReconciliationAt = Date()
    }

    /// Silently reconciles the working set against a fresh full scan.
    /// No spinners, no status text changes — applies corrections as incremental patches.
    func performSilentReconciliation() async {
        guard !isReconciling, !isLoading, !isAutoScanning, !isInventoryRefreshInProgress else { return }
        isReconciling = true
        defer {
            isReconciling = false
            reconciliationTask = nil
        }

        let enabledPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
        guard !enabledPaths.isEmpty else { return }

        do {
            _ = try await createBaselines(for: enabledPaths) { _, _ in }
        } catch {
            Self.logger.error("Silent reconciliation failed: \(error.localizedDescription)")
            return
        }

        guard !Task.isCancelled else { return }

        // Silently reload inventory from the new snapshot — no invalidation
        await loadInventoryFromLatestSnapshot(refreshedAt: Date())
        lastReconciliationAt = Date()
    }

    /// Kicks off silent reconciliation if the last one exceeds the user's configured scan interval.
    func reconcileIfStale() {
        guard !noBaseline else { return }
        let staleThreshold = SettingsStore.shared.automaticFullScanInterval
        if let lastReconciliation = lastReconciliationAt ?? lastAutomaticScanAt,
           Date().timeIntervalSince(lastReconciliation) < staleThreshold {
            return
        }

        reconciliationTask = Task { @MainActor in
            await performSilentReconciliation()
        }
    }

    /// Legacy: Loads the category-based growth list (deprecated, use loadInventory)
    @available(*, deprecated, message: "Use loadInventory() instead")
    func loadCategoryGrowthList(isAutomatic: Bool = false) async {
        await loadInventory(isAutomatic: isAutomatic)
    }

    private func reconcileDrillDownSelection() {
        guard isDrilledDown else { return }

        withAnimationsDisabled {
            guard let currentSelection = selectedInventoryCategory else {
                isDrilledDown = false
                isSubcategoryDrillDown = false
                selectedSubcategory = nil
                return
            }

            if let refreshed = (growingCategories + stableCategories).first(where: { $0.category == currentSelection.category }) {
                selectedInventoryCategory = refreshed
            } else {
                selectedInventoryCategory = nil
                selectedSubcategory = nil
                isSubcategoryDrillDown = false
                isDrilledDown = false
            }

            if isSubcategoryDrillDown {
                guard let selectedSubcategory else {
                    isSubcategoryDrillDown = false
                    return
                }

                let groups = subcategoryGroupsByCategory[currentSelection.category] ?? []
                if let refreshedSubcategory = groups.first(where: { $0.displayName == selectedSubcategory.displayName }) {
                    self.selectedSubcategory = refreshedSubcategory
                } else {
                    self.selectedSubcategory = nil
                    isSubcategoryDrillDown = false
                }
            }
        }
    }

    func isSubcategoryBreakdownReady(for category: GrowthCategory) -> Bool {
        guard subcategoryGroupsByCategory[category] != nil else { return false }
        return subcategoryBreakdownCacheGenerationByCategory[category] == growthContributorCacheGeneration
    }

    func isSubcategoryBreakdownLoading(for category: GrowthCategory) -> Bool {
        subcategoryBreakdownLoadingCategories.contains(category)
    }

    func completeInitialSubcategoryWarmup() {
        guard !hasCompletedInitialSubcategoryWarmup else { return }

        withAnimationsDisabled {
            hasCompletedInitialSubcategoryWarmup = true
        }
    }

    func preloadSubcategoryBreakdowns(for categories: [GrowthCategory]) {
        var seenCategories = Set<GrowthCategory>()

        for category in categories where seenCategories.insert(category).inserted {
            guard !isSubcategoryBreakdownReady(for: category) else { continue }
            guard subcategoryBreakdownLoadTasks[category] == nil else { continue }
            setSubcategoryBreakdownLoading(true, for: category)

            Task { @MainActor in
                _ = await loadSubcategoryBreakdown(for: category)
            }
        }
    }

    func loadSubcategoryBreakdown(for category: GrowthCategory) async -> [SubcategoryGroup] {
        if isSubcategoryBreakdownReady(for: category), let cached = subcategoryGroupsByCategory[category] {
            setSubcategoryBreakdownLoading(false, for: category)
            return cached
        }

        if let existingTask = subcategoryBreakdownLoadTasks[category] {
            return await resolveSubcategoryBreakdownLoad(existingTask, for: category)
        }

        setSubcategoryBreakdownLoading(true, for: category)

        let loadTask = Task { @MainActor in
            if Task.isCancelled {
                return SubcategoryBreakdownLoadResult.skipped
            }

            let enabledPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
            let trackedPathsByID = trackedPathsByID(enabledPaths)
            guard !trackedPathsByID.isEmpty else {
                return .skipped
            }

            let groups: [SubcategoryGroup]
            if currentInventorySnapshotIDsByPath.isEmpty {
                groups = await baselineService.getSubcategoryBreakdownFromWorkingSet(
                    for: category,
                    trackedPathsById: trackedPathsByID,
                    baselineSnapshotIdsByPath: currentGrowthBaselineSnapshotIDsByPath
                )
            } else {
                // Prefer snapshot-backed structure whenever available.
                // Recent growth is overlaid from the journal, which keeps
                // drill-down responsive even when incremental deltas exist.
                groups = await baselineService.getSubcategoryBreakdown(
                    for: category,
                    trackedPathsById: trackedPathsByID,
                    latestSnapshotIdsByPath: currentInventorySnapshotIDsByPath,
                    baselineSnapshotIdsByPath: currentGrowthBaselineSnapshotIDsByPath
                )
            }
            if Task.isCancelled {
                return .skipped
            }

            if suppressGrowthIndicators {
                let hiddenGroups = groups.map { group in
                    var updatedGroup = group
                    updatedGroup.growthBytes = nil
                    return updatedGroup
                }
                return .loaded(hiddenGroups)
            }

            return .loaded(groups)
        }

        subcategoryBreakdownLoadTasks[category] = loadTask
        return await resolveSubcategoryBreakdownLoad(loadTask, for: category)
    }

    /// Loads more files for a specific subcategory (pagination support).
    /// Updates the subcategoryGroupsByCategory cache with the new files.
    /// - Parameter group: The SubcategoryGroup to load more files for
    /// - Returns: Updated SubcategoryGroup with more files, or nil if failed/maxed out
    @discardableResult
    func loadMoreFiles(for group: SubcategoryGroup) async -> SubcategoryGroup? {
        guard let category = selectedInventoryCategory?.category else { return nil }
        let requestedCategory = category
        let requestedGroupId = group.id

        // Check if we've hit the maximum
        guard group.loadedFileCount < SubcategoryGroup.maxLoadableFiles else {
            return nil
        }

        // Check if there are more files to load
        guard group.hasMoreFiles else { return nil }

        do {
            let additionalFiles: [GrowthItem]
            if currentInventorySnapshotIDsByPath.isEmpty {
                let enabledPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
                guard let primaryPath = primaryTrackedPath(from: enabledPaths) else { return nil }
                additionalFiles = await baselineService.loadMoreSubcategoryFilesFromWorkingSet(
                    for: category,
                    subcategory: group.subcategory,
                    trackedPathId: primaryPath.id,
                    totalBytes: group.totalBytes,
                    offset: group.loadedFileCount
                )
            } else {
                additionalFiles = await baselineService.loadMoreSubcategoryFiles(
                    for: category,
                    subcategory: group.subcategory,
                    snapshotIdsByPath: currentInventorySnapshotIDsByPath,
                    totalBytes: group.totalBytes,
                    offset: group.loadedFileCount
                )
            }

            guard !additionalFiles.isEmpty else { return nil }
            guard !Task.isCancelled else { return nil }
            guard selectedInventoryCategory?.category == requestedCategory else { return nil }

            // Update the cached group with new files
            var updatedGroup = group
            var seenPaths = Set(updatedGroup.topFiles.map(\.path))
            for file in additionalFiles where seenPaths.insert(file.path).inserted {
                updatedGroup.topFiles.append(file)
            }
            updatedGroup.topFiles.sort {
                if $0.currentSizeBytes == $1.currentSizeBytes {
                    return $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }
                return $0.currentSizeBytes > $1.currentSizeBytes
            }

            // Update the cache
            if var groups = subcategoryGroupsByCategory[requestedCategory] {
                if let index = groups.firstIndex(where: { $0.id == requestedGroupId }) {
                    groups[index] = updatedGroup
                    subcategoryGroupsByCategory[requestedCategory] = groups
                } else {
                    return nil
                }
            } else {
                return nil
            }

            // Update selectedSubcategory if it matches
            if selectedSubcategory?.id == requestedGroupId {
                selectedSubcategory = updatedGroup
            }

            return updatedGroup
        } catch {
            print("[MenuBarManager] Failed loading more files: \(error)")
            return nil
        }
    }

    /// Loads growth contributors for a specific subcategory group
    func loadGrowthContributors(for group: SubcategoryGroup, category: GrowthCategory) async -> [GrowthContributor] {
        guard !suppressGrowthIndicators else { return [] }
        guard let snapshotSignature = snapshotIDsSignature(currentInventorySnapshotIDsByPath),
              let baselineSignature = snapshotIDsSignature(currentGrowthBaselineSnapshotIDsByPath) else {
            return []
        }

        let cacheKey = growthContributorCacheKey(
            snapshotSignature: snapshotSignature,
            baselineSnapshotSignature: baselineSignature,
            category: category,
            group: group
        )

        if let cached = growthContributorsBySubcategory[cacheKey] {
            return cached
        }

        // Only show contributors backed by the live working set. Falling back
        // to historical snapshot diffs mixes older growth into the current
        // drill-down and makes pre-baseline files appear newly grown.
        let contributors = await baselineService.getGrowthContributors(
            baselineSnapshotIdsByPath: currentGrowthBaselineSnapshotIDsByPath,
            category: category,
            subcategory: group.subcategory
        )
        growthContributorsBySubcategory[cacheKey] = contributors
        return contributors
    }

    func cachedGrowthContributors(for group: SubcategoryGroup, category: GrowthCategory) -> [GrowthContributor]? {
        guard !suppressGrowthIndicators else { return [] }
        guard let snapshotSignature = snapshotIDsSignature(currentInventorySnapshotIDsByPath),
              let baselineSignature = snapshotIDsSignature(currentGrowthBaselineSnapshotIDsByPath) else {
            return nil
        }
        let cacheKey = growthContributorCacheKey(
            snapshotSignature: snapshotSignature,
            baselineSnapshotSignature: baselineSignature,
            category: category,
            group: group
        )
        return growthContributorsBySubcategory[cacheKey]
    }

    /// Takes the initial snapshot for enabled paths
    func takeInitialSnapshot() async {
        let enabledPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)

        // If no paths are enabled, try to enable the default path
        var pathsToTry = enabledPaths
        if pathsToTry.isEmpty {
            if let defaultPath = SettingsStore.shared.allTrackedPaths.first(where: { $0.isDefault }) {
                // Ensure the path exists before enabling it
                if FileManager.default.fileExists(atPath: defaultPath.url.path) {
                    SettingsStore.shared.setPathEnabled(defaultPath, enabled: true)
                    pathsToTry = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
                } else {
                    errorMessage = "Default path not found. Please configure a valid path in Settings."
                    return
                }
            }
        }

        guard let trackedPath = pathsToTry.first else {
            errorMessage = "No valid paths configured. Please add a path in Settings."
            return
        }

        isLoading = true
        errorMessage = nil
        filesScanned = 0
        isAnalyzingChanges = false
        scanProgress = "Taking initial snapshot for \(trackedPath.displayName)..."
        scanCurrentPathDisplay = "."
        // Reset progress percentage at scan start (ISS-033)
        scanProgressPercentage = 0.0
        scanEstimatedTotalFiles = 0
        hasReliableScanProgressEstimate = false

        do {
            _ = try await createBaselines(for: pathsToTry) { _, _ in }
            noBaseline = false
            scanProgress = ""
            scanCurrentPath = ""
            scanCurrentPathDisplay = ""

            // Refresh storage space after baseline creation (ISS-042)
            updateFreeSpace()

        } catch {
            if let scanError = error as? ScanError, case .cancelled = scanError {
                scanProgress = "Cancelled"
                scanCurrentPath = ""
                scanCurrentPathDisplay = ""
            } else {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
        scanProgress = ""
        scanCurrentPath = ""
        scanCurrentPathDisplay = ""
        scanProgressPercentage = 0.0
        scanEstimatedTotalFiles = 0
        hasReliableScanProgressEstimate = false
    }

    /// Auto-initializes the app on first launch (zero-friction onboarding)
    /// Silently takes an initial snapshot if none exist
    func autoInitializeIfNeeded() async {
        // Check if we already have snapshots
        let hasSnapshots = await baselineService.hasBaseline()

        if hasSnapshots {
            noBaseline = false
            return
        }

        // Enable default path if needed
        let enabledPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
        if enabledPaths.isEmpty {
            if let defaultPath = SettingsStore.shared.allTrackedPaths.first(where: { $0.isDefault }) {
                if FileManager.default.fileExists(atPath: defaultPath.url.path) {
                    SettingsStore.shared.setPathEnabled(defaultPath, enabled: true)
                }
            }
        }

        let pathsToScan = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
        guard let _ = primaryTrackedPath(from: pathsToScan) else {
            return
        }

        // Take snapshot silently in background (isAutoScanning = true to avoid blocking UI)
        isAutoScanning = true

        do {
            _ = try await createBaselines(for: pathsToScan) { _, _ in }
            noBaseline = false
        } catch {
            // Silent failure - auto-init is optional
        }

        isAutoScanning = false
    }

    /// Stops the current scan
    func stopScan() async {
        await ScanService.shared.cancelScan()
        scanProgress = "Stopping..."

        // Clear scan start time to skip minimum display delay
        scanStartTime = nil
    }

    /// Checks if baseline exists without triggering a scan.
    /// Lightweight: only checks for snapshot existence, does not load full inventory.
    func checkBaseline() async {
        let trackedPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
        guard !trackedPaths.isEmpty else {
            noBaseline = true
            lastAutomaticScanAt = nil
            updateMonitoredPathName()
            return
        }

        lastAutomaticScanAt = nil
        var hasAnySnapshot = false
        for trackedPath in trackedPaths {
            if let snapshots = try? await DatabaseManager.shared
                .fetchRecentSnapshots(trackedPathId: trackedPath.id, limit: 1),
               let snapshot = snapshots.first {
                hasAnySnapshot = true
                if lastAutomaticScanAt == nil || snapshot.createdAt > lastAutomaticScanAt! {
                    lastAutomaticScanAt = snapshot.createdAt
                }
            }
        }
        noBaseline = !hasAnySnapshot
        updateMonitoredPathName()

        // If we're in deltas-only mode (trackingStartedAt set but no snapshot yet),
        // resume the background upgrade schedule so it fires at the right time.
        if isDeltasOnlyMode {
            configureFileWatcherIfNeeded()
            scheduleDeltasOnlyUpgrade()
        }
    }

    /// Loads just category totals from the pre-computed workingSetCategoryTotal table.
    /// No growth stories, no trends — just sizes. Near-instant.
    func loadQuickInventory() async -> Bool {
        let enabledPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
        guard !enabledPaths.isEmpty else { return false }

        var itemsByCategory: [GrowthCategory: Int64] = [:]
        for trackedPath in enabledPaths {
            guard let totals = try? await DatabaseManager.shared
                .fetchWorkingSetCategoryTotals(for: trackedPath.id) else { continue }
            for item in totals {
                itemsByCategory[item.category, default: 0] += item.currentSizeBytes
            }
        }
        guard !itemsByCategory.isEmpty else { return false }

        let items = itemsByCategory.map {
            CategoryInventoryItem(category: $0.key, currentSizeBytes: $0.value,
                                  growthTrend: nil, recentGrowthStory: nil)
        }.sorted { $0.currentSizeBytes > $1.currentSizeBytes }

        // All appear as stable initially (no growth stories loaded yet)
        growingCategories = []
        stableCategories = items
        stableTotalBytes = items.reduce(0) { $0 + $1.currentSizeBytes }
        noBaseline = false
        return true
    }

    private func applyInventory(
        _ inventory: [CategoryInventoryItem],
        snapshotIDsByPath: [UUID: Int64],
        growthBaselineSnapshotIDsByPath: [UUID: Int64],
        invalidateSubcategoryCache: Bool
    ) {
        let previousSnapshotSignature = snapshotIDsSignature(currentInventorySnapshotIDsByPath)
        let previousBaselineSignature = snapshotIDsSignature(currentGrowthBaselineSnapshotIDsByPath)
        let newSnapshotSignature = snapshotIDsSignature(snapshotIDsByPath)
        let newBaselineSignature = snapshotIDsSignature(growthBaselineSnapshotIDsByPath)
        let shouldInvalidateSubcategoryCache =
            invalidateSubcategoryCache
            || previousSnapshotSignature != newSnapshotSignature
            || previousBaselineSignature != newBaselineSignature

        var growing: [CategoryInventoryItem] = []
        var stable: [CategoryInventoryItem] = []
        var stableTotal: Int64 = 0

        for item in inventory {
            let visibleItem = suppressGrowthIndicators ? suppressedGrowthItem(from: item) : item

            if visibleItem.recentGrowthStory != nil {
                growing.append(visibleItem)
            } else {
                stable.append(visibleItem)
                stableTotal += visibleItem.currentSizeBytes
            }
        }

        growingCategories = growing.sorted { $0.currentSizeBytes > $1.currentSizeBytes }
        stableCategories = stable.sorted { $0.currentSizeBytes > $1.currentSizeBytes }
        stableTotalBytes = stableTotal
        currentInventorySnapshotIDsByPath = snapshotIDsByPath
        currentGrowthBaselineSnapshotIDsByPath = growthBaselineSnapshotIDsByPath

        if shouldInvalidateSubcategoryCache {
            cancelSubcategoryBreakdownLoads()
            subcategoryGroupsByCategory = [:]
            subcategoryBreakdownCacheGenerationByCategory = [:]
            subcategoryBreakdownLoadingCategories = []
            hasCompletedInitialSubcategoryWarmup = false
        } else {
            let validCategories = Set((growingCategories + stableCategories).map(\.category))
            subcategoryGroupsByCategory = subcategoryGroupsByCategory.filter { validCategories.contains($0.key) }
            subcategoryBreakdownCacheGenerationByCategory = subcategoryBreakdownCacheGenerationByCategory.filter {
                validCategories.contains($0.key)
            }
            subcategoryBreakdownLoadingCategories = Set(
                subcategoryBreakdownLoadingCategories.filter { validCategories.contains($0) }
            )
            for category in subcategoryBreakdownLoadTasks.keys where !validCategories.contains(category) {
                subcategoryBreakdownLoadTasks[category]?.cancel()
                subcategoryBreakdownLoadTasks[category] = nil
            }
        }
        invalidateGrowthContributorCache()

        reconcileDrillDownSelection()

        if shouldInvalidateSubcategoryCache, isDrilledDown, let category = selectedInventoryCategory?.category {
            preloadSubcategoryBreakdowns(for: [category])
        }
    }

    private func clearInventoryState() {
        withAnimationsDisabled {
            growingCategories = []
            stableCategories = []
            stableTotalBytes = 0
            categoryItems = []
            cancelSubcategoryBreakdownLoads()
            subcategoryGroupsByCategory = [:]
            subcategoryBreakdownCacheGenerationByCategory = [:]
            subcategoryBreakdownLoadingCategories = []
            invalidateGrowthContributorCache()
            selectedInventoryCategory = nil
            selectedSubcategory = nil
            isDrilledDown = false
            isSubcategoryDrillDown = false
            reconciliationResult = nil
            currentInventorySnapshotIDsByPath = [:]
            currentGrowthBaselineSnapshotIDsByPath = [:]
        }
    }

    private func resolveSubcategoryBreakdownLoad(
        _ task: Task<SubcategoryBreakdownLoadResult, Never>,
        for category: GrowthCategory
    ) async -> [SubcategoryGroup] {
        let result = await task.value

        if subcategoryBreakdownLoadTasks[category] != nil {
            subcategoryBreakdownLoadTasks[category] = nil
        }

        switch result {
        case .loaded(let groups):
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                subcategoryGroupsByCategory[category] = groups
                subcategoryBreakdownCacheGenerationByCategory[category] = growthContributorCacheGeneration
                subcategoryBreakdownLoadingCategories.remove(category)
            }
            return groups
        case .skipped:
            setSubcategoryBreakdownLoading(false, for: category)
            return subcategoryGroupsByCategory[category] ?? []
        }
    }

    private func setSubcategoryBreakdownLoading(_ isLoading: Bool, for category: GrowthCategory) {
        withAnimationsDisabled {
            if isLoading {
                subcategoryBreakdownLoadingCategories.insert(category)
            } else {
                subcategoryBreakdownLoadingCategories.remove(category)
            }
        }
    }

    private func cancelSubcategoryBreakdownLoads() {
        for task in subcategoryBreakdownLoadTasks.values {
            task.cancel()
        }
        subcategoryBreakdownLoadTasks = [:]
    }

    private func invalidateGrowthContributorCache() {
        growthContributorsBySubcategory = [:]
        growthContributorCacheGeneration &+= 1
    }

    private func suppressedGrowthItem(from item: CategoryInventoryItem) -> CategoryInventoryItem {
        var updated = item
        updated.growthTrend = nil
        updated.recentGrowthStory = nil
        return updated
    }

    private func captureGrowthPresentationState() -> GrowthPresentationState {
        GrowthPresentationState(
            growingCategories: growingCategories,
            stableCategories: stableCategories,
            stableTotalBytes: stableTotalBytes,
            subcategoryGroupsByCategory: subcategoryGroupsByCategory
        )
    }

    private func clearVisibleGrowthIndicators() {
        withAnimationsDisabled {
            let allCategories = (growingCategories + stableCategories)
                .map(suppressedGrowthItem(from:))
                .sorted { $0.currentSizeBytes > $1.currentSizeBytes }

            growingCategories = []
            stableCategories = allCategories
            stableTotalBytes = allCategories.reduce(0) { $0 + $1.currentSizeBytes }
            subcategoryGroupsByCategory = subcategoryGroupsByCategory.mapValues { groups in
                groups.map { group in
                    var updatedGroup = group
                    updatedGroup.growthBytes = nil
                    return updatedGroup
                }
            }
            invalidateGrowthContributorCache()
            reconcileDrillDownSelection()
        }
    }

    private func restoreGrowthPresentationState(_ state: GrowthPresentationState) {
        withAnimationsDisabled {
            growingCategories = state.growingCategories
            stableCategories = state.stableCategories
            stableTotalBytes = state.stableTotalBytes
            subcategoryGroupsByCategory = state.subcategoryGroupsByCategory
            invalidateGrowthContributorCache()
            reconcileDrillDownSelection()
        }
    }

    private func withAnimationsDisabled(_ updates: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }

    private func growthContributorCacheKey(
        snapshotSignature: String,
        baselineSnapshotSignature: String,
        category: GrowthCategory,
        group: SubcategoryGroup
    ) -> String {
        "\(snapshotSignature):\(baselineSnapshotSignature):\(category.rawValue):\(group.id)"
    }

    private func updateMonitoredPathName() {
        if let path = primaryTrackedPath() {
            monitoredPathName = path.displayName
        } else {
            monitoredPathName = "None"
        }
    }

    /// Reveals the given path in Finder and activates Finder
    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])

        // Also activate Finder to bring it to front
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate()
            if let finderBundle = Bundle(url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")),
               let bundleId = finderBundle.bundleIdentifier {
                let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
                runningApp?.activate()
            }
        }
    }

    /// Shows a folder picker dialog for onboarding
    /// - Parameter completion: Called with the selected folder URL, or nil if cancelled
    func showOnboardingFolderPicker(completion: @escaping (URL?) -> Void) {
        suspendPanelAutoClose()

        // Store original level and hide the dropdown panel
        let originalLevel = panel?.level
        let wasVisible = panel?.isVisible ?? false

        // Order out the panel so file picker can take focus
        panel?.orderOut(nil)

        // Create and configure the open panel
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.message = "Choose a folder to track disk usage"
        openPanel.level = .floating  // Ensure it's above other windows

        // Show the panel
        openPanel.begin { [weak self] response in
            DispatchQueue.main.async {
                self?.resumePanelAutoClose()

                // Restore dropdown panel if it was visible
                if let dropdownPanel = self?.panel, wasVisible {
                    dropdownPanel.level = originalLevel ?? .statusBar
                    NSApp.activate()
                    dropdownPanel.makeKeyAndOrderFront(nil)
                    self?.isPopoverShown = true
                }

                if response == .OK, let url = openPanel.url {
                    completion(url)
                } else {
                    completion(nil)
                }
            }
        }

        // Activate the app and bring file picker to front after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate()
            openPanel.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Opens the menu bar panel if it isn't already visible
    func showPopover() {
        if let panel = panel, panel.isVisible { return }
        togglePopover()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else {
            return
        }

        if let panel = panel, panel.isVisible {
            // Panel is shown, close it
            panel.orderOut(nil)
            isPopoverShown = false

            // Reset auto-close suspension state when manually closing
            panelAutoCloseSuspensionCount = 0
            panel.closesOnResignKey = true
        } else {
            // Panel is not shown, show it
            guard let buttonWindow = button.window,
                  let buttonScreen = buttonWindow.screen else {
                return
            }

            // Ensure auto-close is enabled when opening
            panelAutoCloseSuspensionCount = 0
            panel?.closesOnResignKey = true

            // Activate app to ensure panel comes to front
            NSApp.activate()

            // Get button frame in screen coordinates
            let buttonFrameInWindow = button.convert(button.bounds, to: nil)
            let buttonFrameInScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
            let screenFrame = buttonScreen.frame

            // Position panel below the button, aligned to right edge
            let panelWidth: CGFloat = 320
            let panelHeight: CGFloat = 480

            // Right-align panel with button
            let panelX = buttonFrameInScreen.origin.x + buttonFrameInScreen.size.width - panelWidth

            // Position below menu bar (button bottom is at top of screen area)
            // Menu bar is at the top of screenFrame, button is below it
            let panelY = buttonFrameInScreen.origin.y - panelHeight - 5

            let panelFrame = NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)

            panel?.setFrame(panelFrame, display: true)
            panel?.makeKeyAndOrderFront(nil)
            isPopoverShown = true
        }
    }

    /// Updates free space only if it's been more than 2 seconds since the last update
    /// This prevents excessive disk checks while keeping data reasonably fresh (ISS-032)
    /// Reduced from 5s to 2s for better real-time feedback in menu bar
    func updateFreeSpaceIfNeeded() {
        let cacheInterval: TimeInterval = 2.0 // 2 seconds (reduced for ISS-032)

        if let lastUpdate = lastFreeSpaceUpdate,
           Date().timeIntervalSince(lastUpdate) < cacheInterval {
            // Cache hit - skip disk check
            return
        }

        updateFreeSpace()
        lastFreeSpaceUpdate = Date()
    }

    func updateFreeSpace() {
        let targetURL = primaryTrackedPath()?.url ?? FileManager.default.homeDirectoryForCurrentUser
        let free = DiskSpaceService.shared.getFreeSpace(for: targetURL)
        let total = DiskSpaceService.shared.getTotalSpace(for: targetURL)

        self.freeBytes = free
        self.totalBytes = total
        self.usedBytes = total - free

        if free > 0 {
            let gb = Double(free) / 1_000_000_000
            if gb >= 1000 {
                let tb = gb / 1000
                updateFreeSpaceDisplay("\(String(format: "%.1f", tb)) TB")
            } else {
                updateFreeSpaceDisplay("\(String(format: "%.1f", gb)) GB")
            }
        } else {
            updateFreeSpaceDisplay("Prunr")
        }

        lastFreeSpaceUpdate = Date()

        if total > 0 {
            let freeRatio = Double(free) / Double(total)
            isUnderDiskPressure = freeRatio < 0.15 || free < 40_000_000_000
        } else {
            isUnderDiskPressure = false
        }

        if let result = reconciliationResult {
            reconciliationResult = result.withUpdatedFreeSpace(free)
        }
    }

    func updateFreeSpaceDisplay(_ freeSpace: String) {
        statusItem?.button?.title = freeSpace
    }

    private var shouldPulseActivity: Bool {
        isLoading || isAutoScanning
    }

    private func updateMenuBarActivityEffect() {
        if shouldPulseActivity {
            startActivityPulseIfNeeded()
        } else {
            stopActivityPulse()
        }
    }

    private func startActivityPulseIfNeeded() {
        guard activityPulseTimer == nil else { return }

        applyStatusItemAlpha(0.94, animated: true)
        pulseAtLowAlpha = true

        activityPulseTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.shouldPulseActivity else {
                    self.stopActivityPulse()
                    return
                }

                self.pulseAtLowAlpha.toggle()
                let targetAlpha: CGFloat = self.pulseAtLowAlpha ? 0.86 : 0.98
                self.applyStatusItemAlpha(targetAlpha, animated: true)
            }
        }
    }

    private func stopActivityPulse() {
        activityPulseTimer?.invalidate()
        activityPulseTimer = nil
        pulseAtLowAlpha = false
        applyStatusItemAlpha(1.0, animated: true)
    }

    private func applyStatusItemAlpha(_ alpha: CGFloat, animated: Bool) {
        guard let button = statusItem?.button else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                button.animator().alphaValue = alpha
            }
        } else {
            button.alphaValue = alpha
        }
    }

    /// Starts continuous updates to keep menu bar in sync (ISS-042)
    private func startRealtimeUpdates() {
        updateTimer?.invalidate()

        updateTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateFreeSpace()
                self?.configureFileWatcherIfNeeded()
            }
        }
    }

    /// Updates the monitored path size from the latest baseline or current state
    func updatePathSize() async {
        let trackedPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
        guard let trackedPath = primaryTrackedPath(from: trackedPaths) else {
            self.monitoredPathSizeBytes = 0
            self.pathSizeBytesByID = [:]
            return
        }

        await updatePathSizesFromLatestSnapshots(for: trackedPaths, primaryPath: trackedPath)
    }

    private func updatePathSizesFromLatestSnapshots(for trackedPaths: [TrackedPath], primaryPath: TrackedPath) async {
        isCalculatingPathSize = true
        defer { isCalculatingPathSize = false }

        var sizesByID: [UUID: Int64] = [:]

        for trackedPath in trackedPaths {
            do {
                let snapshots = try await DatabaseManager.shared.fetchRecentSnapshots(trackedPathId: trackedPath.id, limit: 1)
                guard let latestId = snapshots.first?.id else {
                    sizesByID[trackedPath.id] = 0
                    continue
                }

                sizesByID[trackedPath.id] = try await DatabaseManager.shared.sumEntrySizes(for: latestId)
            } catch {
                sizesByID[trackedPath.id] = 0
            }
        }

        pathSizeBytesByID = sizesByID
        monitoredPathSizeBytes = sizesByID[primaryPath.id] ?? 0
    }

    func pathSizeBytes(for trackedPath: TrackedPath) -> Int64 {
        pathSizeBytesByID[trackedPath.id] ?? 0
    }

    func closePopover() {
        if isPopoverShown {
            // Close panel if using panel mode
            if let panel = panel, panel.isVisible {
                panel.orderOut(nil)
            }
            // Also close popover for legacy support
            popover?.performClose(nil)
            isPopoverShown = false

            // Reset auto-close suspension state when manually closing
            panelAutoCloseSuspensionCount = 0
            panel?.closesOnResignKey = true
        }
    }

    private func suspendPanelAutoClose() {
        panelAutoCloseSuspensionCount += 1
        panel?.closesOnResignKey = false
    }

    private func resumePanelAutoClose() {
        panelAutoCloseSuspensionCount = max(0, panelAutoCloseSuspensionCount - 1)
        panel?.closesOnResignKey = panelAutoCloseSuspensionCount == 0
    }

    // MARK: - Actions

    #if DEBUG
    @objc private func createTestDataAction() {
        // Run in background with low priority to avoid blocking UI
        Task.detached(priority: .utility) {
            await self.generateTestData()
        }
    }

    /// Generates test data at the default test path
    /// Creates files in paths that match category patterns for testing
    /// Includes comprehensive boundary folders for testing boundary detection
    func generateTestData() async {
        let testDataPath = NSTemporaryDirectory() + "prunr_test_data"
        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: testDataPath)

        do {
            // Create base directory
            try fm.createDirectory(at: baseURL, withIntermediateDirectories: true)

            let timestamp = Int(Date().timeIntervalSince1970)

            // MARK: - Category-specific test data (existing)

            let categoryPaths: [(path: String, sizeKB: Int, fileCount: Int)] = [
                // Library/Caches (matches libraryCaches)
                ("Library/Caches", 200, 3),           // 0.6 MB
                // Downloads (matches downloads)
                ("Downloads", 500, 2),                // 1 MB
                // node_modules (matches nodeModules)
                ("node_modules", 300, 2),             // 0.6 MB
                // .Trash (matches trash)
                (".Trash", 100, 2),                  // 0.2 MB
                // Documents (won't match, goes to other)
                ("Documents", 400, 2),                // 0.8 MB
                // Logs (won't match, goes to other)
                ("logs", 100, 2),                     // 0.2 MB
            ]

            var totalCreated = 0
            for folder in categoryPaths {
                let folderURL = baseURL.appendingPathComponent(folder.path)
                try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

                let sizeBytes = folder.sizeKB * 1024

                for i in 1...folder.fileCount {
                    let fileName = "file_\(timestamp)_\(i)_\(arc4random() % 10000).dat"
                    let fileURL = folderURL.appendingPathComponent(fileName)

                    var bytes = [UInt8](repeating: 0, count: sizeBytes)
                    for j in 0..<sizeBytes {
                        bytes[j] = UInt8.random(in: 0...255)
                    }
                    try Data(bytes).write(to: fileURL)
                    totalCreated += sizeBytes
                }
            }

            // MARK: - Big file for testing big file display

            // Create one "big file" (105MB) in Downloads to test big file display
            let downloadsURL = baseURL.appendingPathComponent("Downloads")
            let bigFileSizeBytes = 105 * 1024 * 1024 // 105 MB
            let bigFileName = "big_test_file_\(timestamp).dat"
            let bigFileURL = downloadsURL.appendingPathComponent(bigFileName)

            // Create big file in chunks to avoid memory issues
            let chunkSize = 1024 * 1024 // 1 MB chunks
            var bigFileData = Data()
            for _ in 0..<(bigFileSizeBytes / chunkSize) {
                let chunk = [UInt8](repeating: UInt8.random(in: 0...255), count: chunkSize)
                bigFileData.append(contentsOf: chunk)
            }
            try bigFileData.write(to: bigFileURL)
            totalCreated += bigFileSizeBytes

            // MARK: - Boundary-specific test data for comprehensive testing

            // Test project structure with various boundary folders
            let testProjects = [
                // JavaScript project
                ("project_js", [
                    ".git": (50, 5),           // 50MB in boundary
                    "node_modules": (60, 3),   // 60MB in boundary
                    "src": (5, 2),             // 5MB in regular folder
                ]),
                // Python project
                ("project_py", [
                    ".git": (55, 5),           // 55MB in boundary
                    ".venv": (60, 3),          // 60MB in boundary
                    "venv": (60, 3),           // 60MB in boundary (alt)
                    "src": (5, 2),             // 5MB in regular folder
                ]),
                // Rust project
                ("project_rust", [
                    ".git": (50, 5),           // 50MB in boundary
                    "target": (70, 4),         // 70MB in boundary
                    "src": (5, 2),             // 5MB in regular folder
                ]),
                // Xcode project
                ("project_ios", [
                    ".git": (50, 5),           // 50MB in boundary
                    "DerivedData": (80, 3),    // 80MB in boundary
                    ".swiftpm": (60, 2),       // 60MB in boundary
                    "Pods": (60, 3),           // 60MB in boundary
                    "src": (5, 2),             // 5MB in regular folder
                ]),
                // Build-heavy project
                ("project_build", [
                    ".git": (50, 5),           // 50MB in boundary
                    "build": (70, 4),          // 70MB in boundary
                    ".build": (70, 4),         // 70MB in boundary (alt)
                    "src": (5, 2),             // 5MB in regular folder
                ]),
                // Dependency-heavy project
                ("project_deps", [
                    ".git": (50, 5),           // 50MB in boundary
                    "vendor": (65, 3),         // 65MB in boundary
                    "third_party": (65, 3),    // 65MB in boundary
                    "src": (5, 2),             // 5MB in regular folder
                ]),
                // Cache-heavy project
                ("project_cache", [
                    ".git": (50, 5),           // 50MB in boundary
                    ".cache": (60, 3),         // 60MB in boundary
                    "Cache": (60, 3),          // 60MB in boundary (alt)
                    "src": (5, 2),             // 5MB in regular folder
                ]),
            ]

            // Create boundary test projects
            for (projectName, folders) in testProjects {
                let projectURL = baseURL.appendingPathComponent(projectName)
                try fm.createDirectory(at: projectURL, withIntermediateDirectories: true)

                for (folderName, (sizeMB, fileCount)) in folders {
                    let folderURL = projectURL.appendingPathComponent(folderName)
                    try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

                    let sizeBytes = sizeMB * 1024 * 1024 // Convert MB to bytes

                    for i in 1...fileCount {
                        let fileName = "\(folderName)_\(timestamp)_\(i)_\(arc4random() % 10000).dat"
                        let fileURL = folderURL.appendingPathComponent(fileName)

                        // For large files, create in chunks to avoid memory issues
                        if sizeBytes > 10 * 1024 * 1024 { // > 10MB
                            var fileData = Data()
                            let chunkSize = 1024 * 1024 // 1 MB chunks
                            for _ in 0..<(sizeBytes / chunkSize) {
                                let chunk = [UInt8](repeating: UInt8.random(in: 0...255), count: chunkSize)
                                fileData.append(contentsOf: chunk)
                            }
                            try fileData.write(to: fileURL)
                        } else {
                            var bytes = [UInt8](repeating: 0, count: sizeBytes)
                            for j in 0..<sizeBytes {
                                bytes[j] = UInt8.random(in: 0...255)
                            }
                            try Data(bytes).write(to: fileURL)
                        }
                        totalCreated += sizeBytes
                    }
                }

                // Create a small config file in each project
                let configFile = projectURL.appendingPathComponent("config.txt")
                try "Test config file".data(using: .utf8)?.write(to: configFile)
            }

            print("[MenuBarManager] Created \(Double(totalCreated) / 1024.0 / 1024.0) MB of test data")
            print("[MenuBarManager] Categories: Library/Caches, Downloads, node_modules, .Trash, other")
            print("[MenuBarManager] Big file: 105 MB file in Downloads (tests >= 100MB threshold)")
            print("[MenuBarManager] Boundary test projects: 7 projects with comprehensive boundary folders")
            print("[MenuBarManager]   - project_js: .git, node_modules, src")
            print("[MenuBarManager]   - project_py: .git, .venv, venv, src")
            print("[MenuBarManager]   - project_rust: .git, target, src")
            print("[MenuBarManager]   - project_ios: .git, DerivedData, .swiftpm, Pods, src")
            print("[MenuBarManager]   - project_build: .git, build, .build, src")
            print("[MenuBarManager]   - project_deps: .git, vendor, third_party, src")
            print("[MenuBarManager]   - project_cache: .git, .cache, Cache, src")

        } catch {
            print("[MenuBarManager] Failed to create test data: \(error)")
        }
    }
    #endif

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        if isPopoverShown {
            isPopoverShown = false
        }
    }

    func popoverWillClose(_ notification: Notification) {
        // Early state sync for better reliability (ISS-013)
        if isPopoverShown {
            isPopoverShown = false
        }
    }

    private func configureFileWatcherIfNeeded() {
        let enabledPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
        let urls = enabledPaths
            .filter { shouldAutoWatchTrackedPath($0) }
            .map(\.url.standardizedFileURL)
        let watchedSignature = urls.map(\.path)

        if watchedSignature == watchedPaths {
            Task { @MainActor in
                if let watcher = fileEventsWatcher, await watcher.isRunning {
                    return
                }
                await configureFileWatcher(with: urls)
            }
            return
        }

        watchedPaths = watchedSignature
        Task { @MainActor in
            await configureFileWatcher(with: urls)
        }
    }

    @MainActor
    private func configureFileWatcher(with urls: [URL]) async {
        if let watcher = fileEventsWatcher {
            await watcher.stop()
        }
        fileEventsWatcher = nil

        guard !urls.isEmpty else {
            return
        }

        // Refresh custom ignores cache before starting watcher
        FSEventsNoiseFilter.refreshCustomIgnoresCache()

        let watcher = FSEventsWatcher(pathsToWatch: urls, debounceInterval: 1.0)
        await watcher.setOnChange { [weak self] changeBatch in
            Task { @MainActor in
                guard let self else { return }

                // Filter out noisy paths before processing
                let filteredPaths = changeBatch.changedPaths.filter { url in
                    !FSEventsNoiseFilter.shouldIgnore(url.path)
                }
                guard !filteredPaths.isEmpty else { return }
                guard !self.shouldIgnoreAutoScanChanges(filteredPaths) else { return }

                self.lastFileEventAt = Date()
                // Always accumulate — never drop events during scan/cleanup
                self.pendingRecentChangePaths.formUnion(filteredPaths.map(\.standardizedFileURL))
                self.hasPendingRecentChanges = true

                // Only schedule processing when not scanning — events accumulate
                // and will be flushed after loadInventory completes
                if !self.isLoading, !self.isAutoScanning {
                    self.scheduleRecentChangeRefreshTask(after: self.currentRecentChangeDebounce)
                }
            }
        }
        fileEventsWatcher = watcher
        await watcher.start()
    }

    private func scheduleRecentChangeRefresh(_ changedPaths: Set<URL>) {
        guard !changedPaths.isEmpty else { return }
        guard !SettingsStore.shared.enabledTrackedPaths.isEmpty else { return }

        pendingRecentChangePaths.formUnion(changedPaths.map(\.standardizedFileURL))
        hasPendingRecentChanges = true
        scheduleRecentChangeRefreshTask(after: currentRecentChangeDebounce)
    }

    private func performRecentChangeRefresh() async {
        guard !pendingRecentChangePaths.isEmpty else {
            hasPendingRecentChanges = false
            return
        }
        guard !isLoading, !isInventoryRefreshInProgress, !isAutoScanning else {
            scheduleRecentChangeRefreshTask(after: currentRecentChangeDebounce)
            return
        }

        let enabledPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
        guard !enabledPaths.isEmpty else {
            pendingRecentChangePaths.removeAll()
            hasPendingRecentChanges = false
            return
        }

        let changedPaths = pendingRecentChangePaths
        pendingRecentChangePaths.removeAll()
        isProcessingRecentChanges = true
        defer {
            isProcessingRecentChanges = false
            hasPendingRecentChanges = !pendingRecentChangePaths.isEmpty
        }

        // Route each changed path to the tracked path it falls under
        var pathsByTrackedPath: [UUID: (trackedPath: TrackedPath, urls: Set<URL>)] = [:]
        for url in changedPaths {
            let urlPath = url.standardizedFileURL.path
            // Find the most specific (longest) tracked root that contains this path
            var bestMatch: TrackedPath?
            var bestLength = 0
            for tp in enabledPaths {
                let root = tp.url.standardizedFileURL.path
                let rootWithSlash = root == "/" ? "/" : root + "/"
                if urlPath == root || urlPath.hasPrefix(rootWithSlash) {
                    if root.count > bestLength {
                        bestLength = root.count
                        bestMatch = tp
                    }
                }
            }
            if let match = bestMatch {
                pathsByTrackedPath[match.id, default: (trackedPath: match, urls: [])].urls.insert(url)
            }
        }

        var allDeltas: [DatabaseManager.JournalDeltaKey: Int64] = [:]
        var hadUpdate = false

        for (_, entry) in pathsByTrackedPath {
            let result = await recentChangeService.refreshChangedPaths(entry.urls, trackedPath: entry.trackedPath)
            switch result {
            case .updated(let deltas):
                hadUpdate = true
                for (key, delta) in deltas where delta != 0 {
                    allDeltas[key, default: 0] += delta
                }
            case .needsFullScan:
                hadUpdate = true
            case .noChanges:
                break
            }
        }

        if hadUpdate {
            lastDetectedChangeAt = Date()
            if !allDeltas.isEmpty {
                applyIncrementalDeltas(allDeltas)
            }
        }
    }

    /// Patches category totals in-place from incremental deltas.
    /// Creates new category entries when they don't exist yet (e.g. deltas-only mode).
    /// No subcategory cache invalidation, no spinners.
    private func applyIncrementalDeltas(_ deltas: [DatabaseManager.JournalDeltaKey: Int64]) {
        guard !deltas.isEmpty else { return }
        hasIncrementalDeltasSinceSnapshot = true

        // Aggregate deltas by category (sum all subcategory deltas)
        var categoryDeltas: [GrowthCategory: Int64] = [:]
        for (key, delta) in deltas {
            categoryDeltas[key.category, default: 0] += delta
        }

        // Track which categories were already present so we can add missing ones
        var matchedCategories = Set<GrowthCategory>()

        let now = Date()

        // Apply to growing categories (clamp to zero — deltas-only mode can overshoot)
        for i in growingCategories.indices {
            if let delta = categoryDeltas[growingCategories[i].category] {
                growingCategories[i].currentSizeBytes = max(0, growingCategories[i].currentSizeBytes + delta)
                matchedCategories.insert(growingCategories[i].category)
                if delta > 0 {
                    growingCategories[i].recentGrowthStory = accumulateGrowthStory(
                        existing: growingCategories[i].recentGrowthStory,
                        category: growingCategories[i].category,
                        delta: delta,
                        now: now
                    )
                }
            }
        }

        // Demote growing categories whose size hit zero or whose growth story
        // is now fully offset by shrinkage
        var demotedIndices = IndexSet()
        for i in growingCategories.indices {
            if growingCategories[i].currentSizeBytes == 0 {
                growingCategories[i].recentGrowthStory = nil
                demotedIndices.insert(i)
            } else if let delta = categoryDeltas[growingCategories[i].category], delta < 0 {
                if let story = growingCategories[i].recentGrowthStory {
                    let newDelta = story.deltaBytes + delta
                    if newDelta <= 0 {
                        growingCategories[i].recentGrowthStory = nil
                        demotedIndices.insert(i)
                    } else {
                        growingCategories[i].recentGrowthStory = RecentGrowthStory(
                            category: story.category, subcategory: story.subcategory,
                            deltaBytes: newDelta, startedAt: story.startedAt,
                            endedAt: now, duration: story.duration,
                            displayLabel: story.displayLabel
                        )
                    }
                }
            }
        }
        for i in demotedIndices.reversed() {
            stableCategories.append(growingCategories.remove(at: i))
        }

        // Apply to stable categories (clamp to zero) and promote those with growth
        var promotedIndices = IndexSet()
        for i in stableCategories.indices {
            if let delta = categoryDeltas[stableCategories[i].category] {
                stableCategories[i].currentSizeBytes = max(0, stableCategories[i].currentSizeBytes + delta)
                matchedCategories.insert(stableCategories[i].category)
                if delta > 0 {
                    stableCategories[i].recentGrowthStory = accumulateGrowthStory(
                        existing: stableCategories[i].recentGrowthStory,
                        category: stableCategories[i].category,
                        delta: delta,
                        now: now
                    )
                    if stableCategories[i].recentGrowthStory != nil {
                        promotedIndices.insert(i)
                    }
                }
            }
        }
        // Move categories with new growth from stable → growing so they're visible
        for i in promotedIndices.reversed() {
            growingCategories.append(stableCategories.remove(at: i))
        }

        // Create new entries for categories that don't exist yet (deltas-only mode bootstrap)
        for (category, delta) in categoryDeltas where !matchedCategories.contains(category) && delta >= 1_048_576 {
            let story = RecentGrowthStory(
                category: category, subcategory: nil,
                deltaBytes: delta, startedAt: now, endedAt: now,
                duration: 0, displayLabel: "just now"
            )
            let item = CategoryInventoryItem(
                category: category,
                currentSizeBytes: delta,
                growthTrend: nil,
                recentGrowthStory: story
            )
            growingCategories.append(item)
        }

        // Re-sort growing categories by size descending
        if !growingCategories.isEmpty {
            growingCategories.sort { $0.currentSizeBytes > $1.currentSizeBytes }
        }

        var newStableTotal: Int64 = 0
        for i in stableCategories.indices {
            newStableTotal += stableCategories[i].currentSizeBytes
        }
        stableTotalBytes = newStableTotal

        // Selectively invalidate subcategory topFiles for categories with non-zero deltas only
        let affectedCategories = categoryDeltas.filter { $0.value != 0 }.map(\.key)
        var needsDrillDownReload = false
        for category in affectedCategories {
            if subcategoryGroupsByCategory[category] != nil {
                // Invalidate just this category's subcategory cache so it reloads on next drill-down
                subcategoryGroupsByCategory.removeValue(forKey: category)
                subcategoryBreakdownCacheGenerationByCategory.removeValue(forKey: category)
                if isDrilledDown, selectedInventoryCategory?.category == category {
                    needsDrillDownReload = true
                }
            }
        }

        reconcileDrillDownSelection()

        // If the currently drilled-down category was invalidated, reload its subcategory data
        // in the background so the user doesn't see an empty drilldown.
        if needsDrillDownReload, let category = selectedInventoryCategory?.category {
            preloadSubcategoryBreakdowns(for: [category])
        }
    }

    /// Creates or accumulates a growth story for incremental deltas.
    /// If a story already exists, adds the new delta to it; otherwise creates a fresh one.
    private func accumulateGrowthStory(
        existing: RecentGrowthStory?,
        category: GrowthCategory,
        delta: Int64,
        now: Date
    ) -> RecentGrowthStory? {
        let totalDelta = (existing?.deltaBytes ?? 0) + delta
        // Skip if cumulative growth is below 1 MB threshold
        guard totalDelta >= 1_048_576 else { return existing }

        if let existing {
            return RecentGrowthStory(
                category: category,
                subcategory: existing.subcategory,
                deltaBytes: totalDelta,
                startedAt: existing.startedAt,
                endedAt: now,
                duration: now.timeIntervalSince(existing.startedAt),
                displayLabel: "recent"
            )
        }
        return RecentGrowthStory(
            category: category,
            subcategory: nil,
            deltaBytes: delta,
            startedAt: now,
            endedAt: now,
            duration: 0,
            displayLabel: "just now"
        )
    }

    private var currentRecentChangeDebounce: TimeInterval {
        isUnderDiskPressure ? pressureRecentChangeDebounce : normalRecentChangeDebounce
    }

    private func scheduleRecentChangeRefreshTask(after delay: TimeInterval) {
        recentChangeTask?.cancel()
        recentChangeTask = Task { @MainActor in
            defer { recentChangeTask = nil }
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard !Task.isCancelled else { return }
            await performRecentChangeRefresh()
        }
    }

    private func beginInventoryRefresh() -> Bool {
        guard !isInventoryRefreshInProgress else { return false }
        isInventoryRefreshInProgress = true
        return true
    }

    private func endInventoryRefresh() {
        isInventoryRefreshInProgress = false
    }

    private func shouldIgnoreAutoScanChanges(_ changedPaths: Set<URL>) -> Bool {
        guard !changedPaths.isEmpty else { return true }

        let ignoredRoots = autoScanIgnoredRoots()
        let relevantChanges = changedPaths.filter { url in
            let standardized = url.standardizedFileURL
            return !ignoredRoots.contains(where: { standardized.path.hasPrefix($0.path) })
        }

        return relevantChanges.isEmpty
    }

    private func autoScanIgnoredRoots() -> [URL] {
        var roots: [URL] = []

        if let dbPath = DatabaseManager.shared.databasePath {
            roots.append(URL(fileURLWithPath: dbPath).deletingLastPathComponent().standardizedFileURL)
        }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        roots.append(bundleURL)
        roots.append(bundleURL.deletingLastPathComponent().standardizedFileURL)

        return roots
    }

    deinit {
        updateTimer?.invalidate()
        activityPulseTimer?.invalidate()
        recentChangeTask?.cancel()
        reconciliationTask?.cancel()
        let watcher = fileEventsWatcher
        if let watcher {
            Task { await watcher.stop() }
        }
    }
}
