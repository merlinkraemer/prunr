import AppKit
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
    var growthContributorsBySubcategory: [String: [GrowthContributor]] = [:]
    var growthContributorCacheGeneration: UInt64 = 0
    private var currentInventorySnapshotID: Int64?
    var monitoredPathName: String = ""
    var enabledPathCount: Int {
        SettingsStore.shared.enabledTrackedPaths.count
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
        let candidates = paths ?? SettingsStore.shared.enabledTrackedPaths
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

    private func preferredTrackedPath(from paths: [TrackedPath]? = nil) -> TrackedPath? {
        let candidates = paths ?? SettingsStore.shared.enabledTrackedPaths
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

    private func shouldAutoWatchTrackedPath(_ path: TrackedPath) -> Bool {
        let standardized = path.url.standardizedFileURL
        if standardized.path == "/" {
            return false
        }

        return true
    }

    private func automaticFullScanInterval(for trackedPath: TrackedPath?) -> TimeInterval {
        guard let trackedPath else {
            return isUnderDiskPressure ? 10 * 60 : 15 * 60
        }

        let standardized = trackedPath.url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

        if standardized.path == "/" {
            return isUnderDiskPressure ? 10 * 60 : 45 * 60
        }

        if standardized == home {
            return isUnderDiskPressure ? 8 * 60 : 15 * 60
        }

        return isUnderDiskPressure ? 4 * 60 : 7 * 60
    }
    var isLoading = false {
        didSet { updateMenuBarActivityEffect() }
    }
    var isAutoScanning = false { // Visual feedback for background scans
        didSet { updateMenuBarActivityEffect() }
    }
    var errorMessage: String?
    var noBaseline = false
    var scanProgress: String = ""
    var scanCurrentPath: String = ""
    var scanCurrentPathDisplay: String = ""
    var filesScanned: Int = 0
    var scanEstimatedTotalFiles: Int = 0
    var hasReliableScanProgressEstimate = false
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
    // nonisolated(unsafe) allows deinit to access it from nonisolated context
    private var updateTimer: Timer?
    private var activityPulseTimer: Timer?
    private var pulseAtLowAlpha = false

    // Event-driven lightweight scan automation
    private var fileEventsWatcher: FSEventsWatcher?
    private var watchedPaths: [String] = []
    private var autoScanTask: Task<Void, Never>?
    private enum AutoScanTrigger {
        case fileEvent
        case fallbackTimer
    }
    private var pendingFallbackAutoScanTick = false
    private var recentChangeTask: Task<Void, Never>?
    private var isInventoryRefreshInProgress = false
    private var pendingOverflowFullScan = false
    private var pendingRecentChangePaths: Set<URL> = []
    private(set) var lastAutomaticScanAt: Date?
    var lastDetectedChangeAt: Date?
    private var lastAutomaticScanAttemptAt: Date?
    private var isUnderDiskPressure = false
    private var lastFileEventAt: Date?
    var hasPendingRecentChanges = false
    var isProcessingRecentChanges = false {
        didSet { updateMenuBarActivityEffect() }
    }

    var lastScanStatusText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full

        if isProcessingRecentChanges {
            return "Updating recent changes…"
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

    private let normalAutoScanDebounce: TimeInterval = 20
    private let pressureAutoScanDebounce: TimeInterval = 8
    private let normalRecentChangeDebounce: TimeInterval = 75
    private let pressureRecentChangeDebounce: TimeInterval = 45
    private let normalAutoScanAttemptInterval: TimeInterval = 45
    private let pressureAutoScanAttemptInterval: TimeInterval = 15
    private let startupAutoScanGracePeriod: TimeInterval = 20
    private var useFallbackAutoScan = false
    private let appLaunchAt = Date()

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

        // Create Test Data (Debug)
        let createDataItem = NSMenuItem(
            title: "Create Test Data",
            action: #selector(createTestDataAction),
            keyEquivalent: ""
        )
        createDataItem.target = self
        menu.addItem(createDataItem)

        menu.addItem(NSMenuItem.separator())

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
            updateFreeSpace()
            await checkBaseline() // Update state

            // Also clear categories since baseline is gone/reset
            growingCategories = []
            stableCategories = []
            stableTotalBytes = 0
            categoryItems = []
            subcategoryGroupsByCategory = [:]
            invalidateGrowthContributorCache()
            selectedInventoryCategory = nil
            selectedSubcategory = nil
            isDrilledDown = false
            isSubcategoryDrillDown = false
        } catch {
            print("[MenuBarManager] Failed to reset baseline: \(error)")
        }
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

    // MARK: - Scan & Growth Logic (Moved from ViewModel)

    // Properties are now synthesized by @Observable macro at class level
    // and initialized above.

    /// Loads inventory data with growth trends for the preferred enabled tracked path
    func loadInventory(isAutomatic: Bool = false) async {
        // Prefer the most specific enabled tracked path to avoid scanning huge umbrella roots.
        let enabledPaths = SettingsStore.shared.enabledTrackedPaths
        guard let trackedPath = primaryTrackedPath(from: enabledPaths) else {
            print("[MenuBarManager] No enabled tracked paths in settings")
            errorMessage = "No paths enabled in Settings"
            return
        }
        guard beginInventoryRefresh() else { return }
        defer { endInventoryRefresh() }

        isLoading = true
        errorMessage = nil
        noBaseline = false
        filesScanned = 0
        isAnalyzingChanges = false
        scanProgress = "Scanning \(trackedPath.displayName)..."
        scanCurrentPath = trackedPath.url.path
        scanCurrentPathDisplay = "."
        // Start slightly above zero so the UI never appears stalled before the first callback lands.
        scanProgressPercentage = 0.03
        scanEstimatedTotalFiles = 0
        hasReliableScanProgressEstimate = false

        // Record scan start time for minimum display duration
        let startTime = Date()
        scanStartTime = startTime

        print("[MenuBarManager] Starting scan for: \(trackedPath.displayName)")

        var wasCancelled = false
        var completedSuccessfully = false
        var completedSnapshot: Snapshot?

        // Create progress callback for updating UI during scan
        // Note: MainActor.run ensures UI updates happen on main thread
        let progressCallback: (ScanService.ScanProgress) -> Void = { progress in
            Task { @MainActor in
                // Update files scanned count
                self.filesScanned = progress.foldersScanned

                // Update percentage for progress bar (ISS-033)
                let clamped = max(0.0, min(1.0, progress.percentage))
                // Keep visual progress just under 100% until scan is truly done.
                self.scanProgressPercentage = clamped >= 1.0 ? 0.99 : clamped
                self.scanEstimatedTotalFiles = max(progress.totalFiles, progress.foldersScanned)
                self.hasReliableScanProgressEstimate = progress.hasReliableEstimate
                self.scanCurrentPath = progress.currentPath

                let rootPath = trackedPath.url.path
                let displayPath = self.displayPath(for: progress.currentPath, rootPath: rootPath)
                self.scanCurrentPathDisplay = displayPath
                self.scanProgress = "Scanning \(displayPath)"
            }
        }

        do {
            // First, take a new snapshot
            completedSnapshot = try await baselineService.createBaseline(trackedPath: trackedPath, progress: progressCallback)

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
            let inventory = await baselineService.getInventoryWithTrends(trackedPath: trackedPath)

            applyInventory(
                inventory,
                snapshotID: completedSnapshot?.id,
                invalidateSubcategoryCache: true
            )

            // Keep legacy categoryItems for drill-down compatibility during transition
            // TODO: Remove once drill-down is migrated to inventory-based
            categoryItems = []

            // Also compute disk accounting for free space tracking
            do {
                let result = try await baselineService.getDiskAccounting(trackedPath: trackedPath)
                reconciliationResult = result
            } catch {
                print("[MenuBarManager] Disk accounting failed: \(error)")
                reconciliationResult = nil
            }

            reconcileDrillDownSelection()
            scanProgress = ""
            scanCurrentPath = ""
            scanCurrentPathDisplay = ""
            completedSuccessfully = true

            let snapshotTimestamp = completedSnapshot?.createdAt ?? Date()
            if !growingCategories.isEmpty {
                lastDetectedChangeAt = snapshotTimestamp
            }

            // Refresh storage space after scan (ISS-042)
            updateFreeSpace()
            hasPendingRecentChanges = !pendingRecentChangePaths.isEmpty
        } catch {
            if let baselineError = error as? BaselineService.BaselineError,
               case .insufficientSnapshots = baselineError {
                print("[MenuBarManager] Insufficient snapshots for comparison")
                noBaseline = false
                growingCategories = []
                stableCategories = []
                stableTotalBytes = 0
                categoryItems = []
                subcategoryGroupsByCategory = [:]
                invalidateGrowthContributorCache()
                currentInventorySnapshotID = nil
                reconciliationResult = nil
                reconcileDrillDownSelection()
            } else if let baselineError = error as? BaselineService.BaselineError,
               case .noBaseline = baselineError {
                print("[MenuBarManager] No baseline exists")
                noBaseline = true
                growingCategories = []
                stableCategories = []
                stableTotalBytes = 0
                categoryItems = []
                subcategoryGroupsByCategory = [:]
                invalidateGrowthContributorCache()
                currentInventorySnapshotID = nil
                reconciliationResult = nil
                reconcileDrillDownSelection()
            } else if let scanError = error as? ScanError, case .cancelled = scanError {
                print("[MenuBarManager] Scan was cancelled")
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

        if completedSnapshot != nil && !wasCancelled {
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
        scanProgress = ""
        scanCurrentPath = ""
        scanCurrentPathDisplay = ""
        scanProgressPercentage = 0.0
        scanEstimatedTotalFiles = 0
        hasReliableScanProgressEstimate = false
        filesScanned = 0
        isAnalyzingChanges = false
        scanStartTime = nil
        if completedSuccessfully {
            lastAutomaticScanAt = completedSnapshot?.createdAt ?? Date()
        }

        await updatePathSize()
    }

    func loadInventoryFromLatestSnapshot() async {
        guard beginInventoryRefresh() else { return }
        defer { endInventoryRefresh() }

        let enabledPaths = SettingsStore.shared.enabledTrackedPaths
        guard let trackedPath = primaryTrackedPath(from: enabledPaths) else {
            noBaseline = true
            clearInventoryState()
            lastAutomaticScanAt = nil
            updateMonitoredPathName()
            return
        }

        do {
            let snapshots = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPath.id)
            guard !snapshots.isEmpty else {
                noBaseline = true
                clearInventoryState()
                lastAutomaticScanAt = nil
                updateMonitoredPathName()
                return
            }

            let inventory = await baselineService.getInventoryWithTrends(trackedPath: trackedPath)
            let latestSnapshotID = snapshots.first?.id
            noBaseline = false
            lastAutomaticScanAt = snapshots.first?.createdAt
            errorMessage = nil
            applyInventory(
                inventory,
                snapshotID: latestSnapshotID,
                invalidateSubcategoryCache: latestSnapshotID != currentInventorySnapshotID
            )

            do {
                reconciliationResult = try await baselineService.getDiskAccounting(trackedPath: trackedPath)
            } catch {
                reconciliationResult = nil
            }

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
        lastAutomaticScanAttemptAt = Date()
        isAutoScanning = true
        await loadInventory(isAutomatic: true)
        isAutoScanning = false
    }

    /// Legacy: Loads the category-based growth list (deprecated, use loadInventory)
    @available(*, deprecated, message: "Use loadInventory() instead")
    func loadCategoryGrowthList(isAutomatic: Bool = false) async {
        await loadInventory(isAutomatic: isAutomatic)
    }

    private func reconcileDrillDownSelection() {
        guard isDrilledDown else { return }

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

    func loadSubcategoryBreakdown(for category: GrowthCategory) async -> [SubcategoryGroup] {
        if let cached = subcategoryGroupsByCategory[category] {
            return cached
        }

        if Task.isCancelled {
            return []
        }

        let enabledPaths = SettingsStore.shared.enabledTrackedPaths
        guard let trackedPath = primaryTrackedPath(from: enabledPaths) else {
            return []
        }

        do {
            let snapshots = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPath.id)
            guard let latestSnapshot = snapshots.first,
                  let latestSnapshotId = latestSnapshot.id else {
                return []
            }

            let groups = await baselineService.getSubcategoryBreakdown(for: category, snapshotId: latestSnapshotId)
            if Task.isCancelled {
                return []
            }

            // Try working-set-based growth first, then fall back to journal data
            var growthTotals = await baselineService.getSubcategoryGrowthTotals(
                trackedPathId: trackedPath.id,
                snapshotId: latestSnapshotId,
                category: category
            )

            // If working set comparison found no growth, use journal data
            if growthTotals.isEmpty {
                let journalTotals = await growthJournalService.subcategoryGrowthTotals(
                    trackedPath: trackedPath,
                    category: category,
                    retentionDays: SettingsStore.shared.categoryHistoryRetentionDays
                )
                if !journalTotals.isEmpty {
                    growthTotals = journalTotals
                }
            }

            let hydratedGroups = groups.map { group in
                SubcategoryGroup(
                    subcategory: group.subcategory,
                    displayName: group.displayName,
                    totalBytes: group.totalBytes,
                    fileCount: group.fileCount,
                    growthBytes: growthTotals[group.subcategory],
                    topFiles: group.topFiles
                )
            }

            if Task.isCancelled {
                return []
            }

            subcategoryGroupsByCategory[category] = hydratedGroups
            return hydratedGroups
        } catch {
            print("[MenuBarManager] Failed loading subcategory breakdown for \(category.rawValue): \(error)")
            return []
        }
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
            print("[MenuBarManager] Max files limit reached for subcategory: \(group.displayName)")
            return nil
        }

        // Check if there are more files to load
        guard group.hasMoreFiles else { return nil }

        let enabledPaths = SettingsStore.shared.enabledTrackedPaths
        guard let trackedPath = primaryTrackedPath(from: enabledPaths) else { return nil }

        do {
            let snapshots = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPath.id)
            guard let latestSnapshotId = snapshots.first?.id else { return nil }

            let additionalFiles = await baselineService.loadMoreSubcategoryFiles(
                for: category,
                subcategory: group.subcategory,
                snapshotId: latestSnapshotId,
                totalBytes: group.totalBytes,
                offset: group.loadedFileCount
            )

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
        let enabledPaths = SettingsStore.shared.enabledTrackedPaths
        guard let trackedPath = primaryTrackedPath(from: enabledPaths) else { return [] }

        do {
            let snapshots = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPath.id)
            guard let latestSnapshotId = snapshots.first?.id else { return [] }
            let cacheKey = growthContributorCacheKey(
                snapshotId: latestSnapshotId,
                category: category,
                group: group
            )

            if let cached = growthContributorsBySubcategory[cacheKey] {
                return cached
            }

            let latestEntryCount = try await DatabaseManager.shared.fetchEntryCount(for: latestSnapshotId)
            let journalGrowthLimit = await growthContributorJournalLimit(
                trackedPath: trackedPath,
                category: category,
                subcategory: group.subcategory
            )

            print("[GrowthDebug] \(snapshots.count) snapshots for tracked path, latest ID=\(latestSnapshotId), entries=\(latestEntryCount)")

            // Try working-set comparison first
            var contributors = await baselineService.getGrowthContributors(
                trackedPathId: trackedPath.id,
                snapshotId: latestSnapshotId,
                category: category,
                subcategory: group.subcategory
            )
            print("[GrowthDebug] Working-set comparison returned \(contributors.count) contributors for \(category.rawValue)/\(group.subcategory?.rawValue ?? "nil")")

            // Fallback: compare latest snapshot with the most recent comparable snapshot.
            if contributors.isEmpty,
               let previousSnapshotId = try await fallbackSnapshotDiffBaseline(
                from: snapshots,
                latestSnapshotId: latestSnapshotId,
                latestEntryCount: latestEntryCount
               ) {
                print("[GrowthDebug] Falling back to snapshot diff: latest=\(latestSnapshotId) vs previous=\(previousSnapshotId)")
                contributors = try await DatabaseManager.shared.fetchSnapshotDiffContributors(
                    latestSnapshotId: latestSnapshotId,
                    previousSnapshotId: previousSnapshotId,
                    category: category,
                    subcategory: group.subcategory
                )
                print("[GrowthDebug] Snapshot diff returned \(contributors.count) contributors")
                for c in contributors.prefix(5) {
                    print("[GrowthDebug]   \(URL(fileURLWithPath: c.path).lastPathComponent): current=\(c.currentSizeBytes), growth=\(c.growthBytes)")
                }
            } else if contributors.isEmpty,
                      let previousSnapshotId = snapshots.dropFirst().compactMap(\.id).first,
                      let journalGrowthLimit,
                      previousSnapshotId != latestSnapshotId {
                print("[GrowthDebug] Using bounded snapshot diff against snapshot \(previousSnapshotId) with journal target \(journalGrowthLimit)")
                contributors = try await DatabaseManager.shared.fetchSnapshotDiffContributors(
                    latestSnapshotId: latestSnapshotId,
                    previousSnapshotId: previousSnapshotId,
                    category: category,
                    subcategory: group.subcategory
                )
                contributors = boundedGrowthContributors(
                    contributors,
                    targetGrowthBytes: journalGrowthLimit
                )
                print("[GrowthDebug] Bounded snapshot diff returned \(contributors.count) contributors")
            } else if contributors.isEmpty {
                print("[GrowthDebug] Skipping snapshot diff fallback: no comparable previous snapshot")
            }

            growthContributorsBySubcategory[cacheKey] = contributors
            return contributors
        } catch {
            print("[MenuBarManager] Failed loading growth contributors: \(error)")
            return []
        }
    }

    /// Takes the initial snapshot for enabled paths
    func takeInitialSnapshot() async {
        let enabledPaths = SettingsStore.shared.enabledTrackedPaths

        // If no paths are enabled, try to enable the default path
        var pathsToTry = enabledPaths
        if pathsToTry.isEmpty {
            if let defaultPath = SettingsStore.shared.allTrackedPaths.first(where: { $0.isDefault }) {
                // Ensure the path exists before enabling it
                if FileManager.default.fileExists(atPath: defaultPath.url.path) {
                    SettingsStore.shared.setPathEnabled(defaultPath, enabled: true)
                    pathsToTry = SettingsStore.shared.enabledTrackedPaths
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

        print("[MenuBarManager] Taking initial snapshot for: \(trackedPath.displayName)")

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
            _ = try await baselineService.createBaseline(trackedPath: trackedPath)
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
        let enabledPaths = SettingsStore.shared.enabledTrackedPaths
        if enabledPaths.isEmpty {
            if let defaultPath = SettingsStore.shared.allTrackedPaths.first(where: { $0.isDefault }) {
                if FileManager.default.fileExists(atPath: defaultPath.url.path) {
                    SettingsStore.shared.setPathEnabled(defaultPath, enabled: true)
                }
            }
        }

        guard let trackedPath = primaryTrackedPath() else {
            return
        }

        // Take snapshot silently in background (isAutoScanning = true to avoid blocking UI)
        isAutoScanning = true

        do {
            _ = try await baselineService.createBaseline(trackedPath: trackedPath)
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

    /// Checks if baseline exists without triggering a scan
    func checkBaseline() async {
        guard let trackedPath = primaryTrackedPath() else {
            noBaseline = true
            lastAutomaticScanAt = nil
            updateMonitoredPathName()
            return
        }

        do {
            let snapshots = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPath.id)
            noBaseline = snapshots.isEmpty
            lastAutomaticScanAt = snapshots.first?.createdAt
        } catch {
            noBaseline = true
            lastAutomaticScanAt = nil
        }
        updateMonitoredPathName()
    }

    private func applyInventory(
        _ inventory: [CategoryInventoryItem],
        snapshotID: Int64?,
        invalidateSubcategoryCache: Bool
    ) {
        var growing: [CategoryInventoryItem] = []
        var stable: [CategoryInventoryItem] = []
        var stableTotal: Int64 = 0

        for item in inventory {
            if item.recentGrowthStory != nil || item.growthTrend != nil {
                growing.append(item)
            } else {
                stable.append(item)
                stableTotal += item.currentSizeBytes
            }
        }

        growingCategories = growing.sorted { $0.currentSizeBytes > $1.currentSizeBytes }
        stableCategories = stable.sorted { $0.currentSizeBytes > $1.currentSizeBytes }
        stableTotalBytes = stableTotal
        currentInventorySnapshotID = snapshotID

        if invalidateSubcategoryCache {
            subcategoryGroupsByCategory = [:]
        } else {
            let validCategories = Set((growingCategories + stableCategories).map(\.category))
            subcategoryGroupsByCategory = subcategoryGroupsByCategory.filter { validCategories.contains($0.key) }
        }
        invalidateGrowthContributorCache()

        reconcileDrillDownSelection()
    }

    private func clearInventoryState() {
        growingCategories = []
        stableCategories = []
        stableTotalBytes = 0
        categoryItems = []
        subcategoryGroupsByCategory = [:]
        invalidateGrowthContributorCache()
        selectedInventoryCategory = nil
        selectedSubcategory = nil
        isDrilledDown = false
        isSubcategoryDrillDown = false
        reconciliationResult = nil
        currentInventorySnapshotID = nil
    }

    private func invalidateGrowthContributorCache() {
        growthContributorsBySubcategory = [:]
        growthContributorCacheGeneration &+= 1
    }

    private func growthContributorCacheKey(
        snapshotId: Int64,
        category: GrowthCategory,
        group: SubcategoryGroup
    ) -> String {
        "\(snapshotId):\(category.rawValue):\(group.id)"
    }

    private func growthContributorJournalLimit(
        trackedPath: TrackedPath,
        category: GrowthCategory,
        subcategory: GrowthSubcategory?
    ) async -> Int64? {
        let totals = await growthJournalService.subcategoryGrowthTotals(
            trackedPath: trackedPath,
            category: category,
            retentionDays: SettingsStore.shared.categoryHistoryRetentionDays
        )

        guard let total = totals[subcategory], total > 0 else {
            return nil
        }

        return total
    }

    private func boundedGrowthContributors(
        _ contributors: [GrowthContributor],
        targetGrowthBytes: Int64
    ) -> [GrowthContributor] {
        guard targetGrowthBytes > 0 else { return contributors }

        var bounded: [GrowthContributor] = []
        var accumulatedGrowth: Int64 = 0

        for contributor in contributors {
            bounded.append(contributor)
            accumulatedGrowth += max(0, contributor.growthBytes)

            if accumulatedGrowth >= targetGrowthBytes {
                break
            }
        }

        return bounded
    }

    private func fallbackSnapshotDiffBaseline(
        from snapshots: [Snapshot],
        latestSnapshotId: Int64,
        latestEntryCount: Int
    ) async throws -> Int64? {
        guard latestEntryCount > 0 else { return nil }

        let minimumComparableEntryCount = latestEntryCount / 2

        for snapshot in snapshots.dropFirst() {
            guard let candidateSnapshotId = snapshot.id else { continue }

            let candidateEntryCount = try await DatabaseManager.shared.fetchEntryCount(for: candidateSnapshotId)
            if candidateEntryCount <= 100 {
                print("[GrowthDebug] Skipping snapshot \(candidateSnapshotId): only \(candidateEntryCount) entries")
                continue
            }

            if candidateEntryCount < minimumComparableEntryCount {
                print("[GrowthDebug] Skipping snapshot \(candidateSnapshotId): \(candidateEntryCount) entries vs latest \(latestEntryCount)")
                continue
            }

            if candidateSnapshotId == latestSnapshotId {
                continue
            }

            return candidateSnapshotId
        }

        return nil
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
            if let finderBundle = Bundle(url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")) {
                let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundle.bundleIdentifier!).first
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
        openPanel.message = "Choose a folder to scan for duplicate files"
        openPanel.level = .floating  // Ensure it's above other windows

        // Show the panel
        openPanel.begin { [weak self] response in
            DispatchQueue.main.async {
                self?.resumePanelAutoClose()

                // Restore dropdown panel if it was visible
                if let dropdownPanel = self?.panel, wasVisible {
                    dropdownPanel.level = originalLevel ?? .statusBar
                    NSApp.activate(ignoringOtherApps: true)
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
            NSApp.activate(ignoringOtherApps: true)
            openPanel.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
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
        isLoading || isAutoScanning || isAnalyzingChanges || isCleaningUp || isProcessingRecentChanges
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

    /// Starts continuous 2-second updates to keep menu bar in sync (ISS-042)
    private func startRealtimeUpdates() {
        // Invalidate any existing timer
        updateTimer?.invalidate()

        // Create timer that fires every 2 seconds
        updateTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateFreeSpace()
                self?.configureFileWatcherIfNeeded()
                if self?.useFallbackAutoScan == true {
                    self?.scheduleAutomaticScan(resetDebounce: false, trigger: .fallbackTimer)
                }
            }
        }
    }

    /// Updates the monitored path size from the latest baseline or current state
    func updatePathSize() async {
        let trackedPaths = SettingsStore.shared.enabledTrackedPaths
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
                let snapshots = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPath.id)
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
        let testDataPath = "/Users/merlinkramer/dev/projects/prunr/test_data"
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
        let urls: [URL]
        if let trackedPath = primaryTrackedPath(), shouldAutoWatchTrackedPath(trackedPath) {
            urls = [trackedPath.url.standardizedFileURL]
        } else {
            urls = []
        }
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
            useFallbackAutoScan = primaryTrackedPath() != nil
            return
        }

        let watcher = FSEventsWatcher(pathsToWatch: urls, debounceInterval: 2.0)
        await watcher.setOnChange { [weak self] changedPaths in
            Task { @MainActor in
                guard let self else { return }
                guard !self.shouldIgnoreAutoScanChanges(changedPaths) else { return }
                self.lastFileEventAt = Date()
                self.hasPendingRecentChanges = true
                self.scheduleRecentChangeRefresh(changedPaths)
                self.scheduleAutomaticScan(resetDebounce: false, trigger: .fileEvent)
            }
        }
        fileEventsWatcher = watcher
        await watcher.start()
        useFallbackAutoScan = !(await watcher.isRunning)
    }

    private func scheduleRecentChangeRefresh(_ changedPaths: Set<URL>) {
        guard !changedPaths.isEmpty else { return }
        guard let trackedPath = primaryTrackedPath(),
              shouldAutoWatchTrackedPath(trackedPath) else {
            return
        }

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
            scheduleRecentChangeRefreshTask(after: 5)
            return
        }
        guard let trackedPath = primaryTrackedPath() else {
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

        let result = await recentChangeService.refreshChangedPaths(changedPaths, trackedPath: trackedPath)
        switch result {
        case .updated:
            lastDetectedChangeAt = Date()
            await loadInventoryFromLatestSnapshot()
        case .needsFullScan:
            print("[MenuBarManager] Refresh scan overflowed — triggering full scan")
            await requestOverflowFullScan()
        case .noChanges:
            break
        }
    }

    private func scheduleAutomaticScan(resetDebounce: Bool = true, trigger: AutoScanTrigger = .fileEvent) {
        guard !watchedPaths.isEmpty || useFallbackAutoScan else { return }
        if Date().timeIntervalSince(appLaunchAt) < startupAutoScanGracePeriod {
            return
        }

        if resetDebounce {
            autoScanTask?.cancel()
        } else if autoScanTask != nil {
            if trigger == .fallbackTimer {
                pendingFallbackAutoScanTick = true
            }
            return
        }

        let debounce = isUnderDiskPressure ? pressureAutoScanDebounce : normalAutoScanDebounce
        autoScanTask = Task { @MainActor in
            defer {
                autoScanTask = nil
                if pendingFallbackAutoScanTick {
                    pendingFallbackAutoScanTick = false
                    scheduleAutomaticScan(resetDebounce: false, trigger: .fallbackTimer)
                }
            }
            try? await Task.sleep(for: .milliseconds(Int(debounce * 1000)))
            guard !Task.isCancelled else { return }
            guard !isLoading, !isInventoryRefreshInProgress, !isAutoScanning else {
                return
            }

            let minimumInterval = automaticFullScanInterval(for: primaryTrackedPath())
            if let lastAutomaticScanAt,
               Date().timeIntervalSince(lastAutomaticScanAt) < minimumInterval {
                return
            }

            let minimumAttemptInterval = isUnderDiskPressure ? pressureAutoScanAttemptInterval : normalAutoScanAttemptInterval
            if let lastAutomaticScanAttemptAt,
               Date().timeIntervalSince(lastAutomaticScanAttemptAt) < minimumAttemptInterval {
                return
            }

            lastAutomaticScanAttemptAt = Date()
            await runAutomaticFullScan()
        }
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
        if pendingOverflowFullScan {
            Task { @MainActor [weak self] in
                await self?.runAutomaticFullScanIfPossible()
            }
        }
    }

    private func requestOverflowFullScan() async {
        pendingOverflowFullScan = true
        await runAutomaticFullScanIfPossible()
    }

    private func runAutomaticFullScanIfPossible() async {
        guard pendingOverflowFullScan else { return }
        guard !isAutoScanning, !isLoading, !isInventoryRefreshInProgress else { return }
        pendingOverflowFullScan = false
        await runAutomaticFullScan()
    }

    private func runAutomaticFullScan() async {
        guard !isAutoScanning, !isLoading, !isInventoryRefreshInProgress else { return }
        isAutoScanning = true
        defer { isAutoScanning = false }
        await loadInventory(isAutomatic: true)
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

        let fileManager = FileManager.default

        if let dbPath = DatabaseManager.shared.databasePath {
            roots.append(URL(fileURLWithPath: dbPath).deletingLastPathComponent().standardizedFileURL)
        }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        roots.append(bundleURL)
        roots.append(bundleURL.deletingLastPathComponent().standardizedFileURL)

        let repoBuild = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("dev/projects/prunr/.build", isDirectory: true)
            .standardizedFileURL
        if fileManager.fileExists(atPath: repoBuild.path) {
            roots.append(repoBuild)
        }

        return roots
    }

    deinit {
        MainActor.assumeIsolated {
            updateTimer?.invalidate()
            activityPulseTimer?.invalidate()
            autoScanTask?.cancel()
            recentChangeTask?.cancel()

            let watcher = fileEventsWatcher
            if let watcher {
                Task {
                    await watcher.stop()
                }
            }
        }
    }
}
