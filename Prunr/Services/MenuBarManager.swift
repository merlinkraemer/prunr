import AppKit
import SwiftUI

@MainActor
@Observable
final class MenuBarManager: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    var popover: NSPopover?
    var isPopoverShown = false

    // For debugging menubar click reliability (ISS-013)
    private var lastClickTimestamp: Date?
    private let clickDebounceInterval: TimeInterval = 0.1 // 100ms

    /// Baseline service for growth tracking
    private let baselineService = BaselineService.shared

    /// Right-click menu
    private var contextMenu: NSMenu?
    
    // MARK: - Scan & Growth Logic (Moved from ViewModel)
    
    // Published state for UI
    var growthItems: [GrowthItem] = []
    var categoryItems: [CategoryGrowthItem] = []
    var isDrilledDown: Bool = false // Tracks if user is in category detail view (ISS-037)
    var selectedCategoryForDrilldown: CategoryGrowthItem? = nil // External category selection for drill-down (ISS-043)
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
        if let path = SettingsStore.shared.enabledTrackedPaths.first {
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
    var filesScanned: Int = 0
    var isAnalyzingChanges: Bool = false {
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
    private var watchedPathIDs: [UUID] = []
    private var autoScanTask: Task<Void, Never>?
    private var lastAutomaticScanAt: Date?
    private var lastDetectedChangeAt: Date?
    private var lastAutomaticScanAttemptAt: Date?
    private var isUnderDiskPressure = false

    var lastScanStatusText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full

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

    private let normalAutoScanDebounce: TimeInterval = 90
    private let pressureAutoScanDebounce: TimeInterval = 20
    private let normalAutoScanInterval: TimeInterval = 20 * 60
    private let pressureAutoScanInterval: TimeInterval = 5 * 60
    private let normalAutoScanAttemptInterval: TimeInterval = 4 * 60
    private let pressureAutoScanAttemptInterval: TimeInterval = 90
    
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
            button.action = #selector(handleButtonClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.alphaValue = 1.0
        }

        // Configure popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 480) // Increased from 420 to 480
        popover?.behavior = .transient
        popover?.delegate = self
        // Pass self to MenuBarView
        popover?.contentViewController = NSHostingController(rootView: MenuBarView(manager: self))
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

            // Also clear growth items since baseline is gone/reset
            growthItems = []
            categoryItems = []
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
    
    // MARK: - Scan & Growth Logic (Moved from ViewModel)
     
    // Properties are now synthesized by @Observable macro at class level
    // and initialized above.
    
    /// Loads the category-based growth list
    func loadCategoryGrowthList(isAutomatic: Bool = false) async {
        // Get first enabled tracked path from settings
        let enabledPaths = SettingsStore.shared.enabledTrackedPaths
        guard let trackedPath = enabledPaths.first else {
            print("[MenuBarManager] No enabled tracked paths in settings")
            errorMessage = "No paths enabled in Settings"
            return
        }

        isLoading = true
        errorMessage = nil
        noBaseline = false
        filesScanned = 0
        isAnalyzingChanges = false
        scanProgress = "Scanning \(trackedPath.displayName)..."
        scanCurrentPath = trackedPath.url.path
        // Reset progress percentage at scan start (ISS-033)
        scanProgressPercentage = 0.0

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
                self.scanCurrentPath = progress.currentPath

                // Show detailed path immediately for better scan visibility
                let rootPath = trackedPath.url.path
                var displayPath = progress.currentPath
                if displayPath.hasPrefix(rootPath) {
                    let relativePath = String(displayPath.dropFirst(rootPath.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    displayPath = relativePath.isEmpty ? "." : "./\(relativePath)"
                }
                self.scanProgress = "Scanning \(displayPath)"
            }
        }

        do {
            // First, take a new snapshot
            completedSnapshot = try await baselineService.createBaseline(trackedPath: trackedPath, progress: progressCallback)

            // Briefly show real 100% only when scan is actually complete.
            scanProgressPercentage = 1.0
            scanProgress = "Finalizing scan..."
            try? await Task.sleep(for: .milliseconds(120))

            // Scanning is complete; now compute deltas/categories
            isAnalyzingChanges = true
            scanProgress = "Checking what changed since the last scan..."
            scanCurrentPath = ""
            scanProgressPercentage = 1.0
            
            // Then, get the growth list comparing the latest two snapshots
            let items = try await baselineService.getCategoryGrowthList(trackedPath: trackedPath)
            categoryItems = items
            reconcileDrillDownSelection()
            scanProgress = ""
            scanCurrentPath = ""
            completedSuccessfully = true

            let snapshotTimestamp = completedSnapshot?.createdAt ?? Date()
            if !items.isEmpty {
                lastDetectedChangeAt = snapshotTimestamp
            }

            // Refresh storage space after scan (ISS-042)
            updateFreeSpace()
        } catch {
            if let baselineError = error as? BaselineService.BaselineError,
               case .insufficientSnapshots = baselineError {
                print("[MenuBarManager] Insufficient snapshots for comparison")
                // If we only have 1 snapshot, we can't compare yet.
                // But we just took one, so this means it was the FIRST snapshot.
                // We should show an empty list or a message.
                noBaseline = false
                categoryItems = []
                reconcileDrillDownSelection()
            } else if let baselineError = error as? BaselineService.BaselineError,
               case .noBaseline = baselineError {
                print("[MenuBarManager] No baseline exists")
                noBaseline = true
                categoryItems = []
                reconcileDrillDownSelection()
            } else if let scanError = error as? ScanError, case .cancelled = scanError {
                print("[MenuBarManager] Scan was cancelled")
                scanProgress = "Cancelled"
                scanCurrentPath = ""
                isAnalyzingChanges = false
                wasCancelled = true
            } else {
                print("[MenuBarManager] Error loading category growth list: \(error)")
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

        isLoading = false
        scanProgress = ""
        scanCurrentPath = ""
        scanProgressPercentage = 0.0
        filesScanned = 0
        isAnalyzingChanges = false
        scanStartTime = nil
        if completedSuccessfully {
            lastAutomaticScanAt = completedSnapshot?.createdAt ?? Date()
        }

        await updatePathSize()
    }

    private func reconcileDrillDownSelection() {
        guard isDrilledDown else { return }

        guard let currentSelection = selectedCategoryForDrilldown else {
            isDrilledDown = false
            return
        }

        if let refreshed = categoryItems.first(where: { $0.id == currentSelection.id }) {
            selectedCategoryForDrilldown = refreshed
        } else {
            selectedCategoryForDrilldown = nil
            isDrilledDown = false
        }
    }

    /// Loads the growth list by comparing current state with baseline
    func loadGrowthList() async {
        // Get first enabled tracked path from settings
        let enabledPaths = SettingsStore.shared.enabledTrackedPaths
        guard let trackedPath = enabledPaths.first else {
            print("[MenuBarManager] No enabled tracked paths in settings")
            errorMessage = "No paths enabled in Settings"
            return
        }

        isLoading = true
        errorMessage = nil
        noBaseline = false
        filesScanned = 0
        isAnalyzingChanges = false
        scanProgress = "Scanning \(trackedPath.displayName)..."
        scanCurrentPath = trackedPath.url.path

        do {
            // First, take a new snapshot
            _ = try await baselineService.createBaseline(trackedPath: trackedPath)
            
            let items = try await baselineService.getGrowthList(trackedPath: trackedPath)
            growthItems = items
            scanProgress = ""

            // Refresh storage space after scan (ISS-042)
            updateFreeSpace()
        } catch {
            if let baselineError = error as? BaselineService.BaselineError,
               case .insufficientSnapshots = baselineError {
                print("[MenuBarManager] Insufficient snapshots for comparison")
                noBaseline = false
                growthItems = []
            } else if let baselineError = error as? BaselineService.BaselineError,
               case .insufficientSnapshots = baselineError {
                noBaseline = false
                growthItems = []
            } else if let baselineError = error as? BaselineService.BaselineError,
               case .noBaseline = baselineError {
                noBaseline = true
                growthItems = []
            } else if let scanError = error as? ScanError, case .cancelled = scanError {
                scanProgress = "Cancelled"
            } else {
                errorMessage = "Scan failed: \(error.localizedDescription)"
            }
        }

        isLoading = false
        scanProgress = ""
        scanProgressPercentage = 0.0
        isAnalyzingChanges = false
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
        // Reset progress percentage at scan start (ISS-033)
        scanProgressPercentage = 0.0

        do {
            _ = try await baselineService.createBaseline(trackedPath: trackedPath)
            noBaseline = false
            scanProgress = ""
            scanCurrentPath = ""

            // Refresh storage space after baseline creation (ISS-042)
            updateFreeSpace()

        } catch {
            if let scanError = error as? ScanError, case .cancelled = scanError {
                scanProgress = "Cancelled"
                scanCurrentPath = ""
            } else {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
        scanProgress = ""
        scanCurrentPath = ""
        scanProgressPercentage = 0.0
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

        guard let trackedPath = SettingsStore.shared.enabledTrackedPaths.first else {
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
        let hasBaseline = await baselineService.hasBaseline()
        noBaseline = !hasBaseline
        updateMonitoredPathName()
    }
    
    private func updateMonitoredPathName() {
        if let path = SettingsStore.shared.enabledTrackedPaths.first {
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else {
            return
        }

        // Check actual popover state, not just cached flag (ISS-013)
        let actualPopoverState = popover?.isShown ?? false

        if let popover = popover, actualPopoverState {
            // Popover is actually shown, close it
            popover.performClose(nil)
            isPopoverShown = false
        } else {
            // Popover is not shown, show it

            // Ensure popover is not already shown before showing
            if let popover = popover, !popover.isShown {
                // ISS-025: Store the menubar screen for multi-monitor setups
                // We'll use this to prevent the popup from jumping to other screens
                guard let buttonWindow = button.window,
                      let screen = buttonWindow.screen else {
                    return
                }

                // Activate app to ensure popup comes to front
                NSApp.activate()

                // Disable animations for instant popup display
                CATransaction.begin()
                CATransaction.setDisableActions(true)

                // Show popover relative to button - NSPopover will handle positioning
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

                CATransaction.commit()

                isPopoverShown = true

                // ISS-025: Verify popup is on the correct screen after a short delay
                // This allows NSPopover to complete its positioning first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    if let popoverWindow = popover.contentViewController?.view.window {
                        // Check if popup is on the wrong screen
                        if let popupScreen = popoverWindow.screen,
                           popupScreen != screen {
                            // Close and reopen to force repositioning
                            popover.performClose(nil)
                            self.isPopoverShown = false

                            // Small delay before reopening
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                if self.popover?.isShown == false {
                                    CATransaction.begin()
                                    CATransaction.setDisableActions(true)
                                    self.popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                                    CATransaction.commit()
                                    self.isPopoverShown = true
                                }
                            }
                        } else {
                            popoverWindow.makeKey()
                        }
                    }
                }
            }
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
        let free = DiskSpaceService.shared.getFreeSpace()
        let total = DiskSpaceService.shared.getTotalSpace()

        // Update observable state for UI (DriveBarView reacts automatically)
        self.freeBytes = free
        self.totalBytes = total
        self.usedBytes = total - free

        // CRITICAL: Explicitly sync AppKit menu bar (ISS-042)
        let gb = Double(free) / 1_000_000_000
        if gb >= 1000 {
            let tb = gb / 1000
            updateFreeSpaceDisplay("\(String(format: "%.1f", tb)) TB")
        } else {
            updateFreeSpaceDisplay("\(String(format: "%.1f", gb)) GB")
        }

        // Update cache timestamp
        lastFreeSpaceUpdate = Date()

        if total > 0 {
            let freeRatio = Double(free) / Double(total)
            isUnderDiskPressure = freeRatio < 0.15 || free < 40_000_000_000
        } else {
            isUnderDiskPressure = false
        }
    }

    func updateFreeSpaceDisplay(_ freeSpace: String) {
        statusItem?.button?.title = freeSpace
    }

    private var shouldPulseActivity: Bool {
        isLoading || isAutoScanning || isAnalyzingChanges
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
            }
        }
    }

    /// Updates the monitored path size from the latest baseline or current state
    func updatePathSize() async {
        let trackedPaths = SettingsStore.shared.enabledTrackedPaths
        guard let trackedPath = trackedPaths.first else {
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

                let entries = try await DatabaseManager.shared.fetchEntries(for: latestId)
                sizesByID[trackedPath.id] = entries.reduce(0) { $0 + $1.sizeBytes }
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
            popover?.performClose(nil)
            isPopoverShown = false
        }
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
        let enabledPaths = SettingsStore.shared.enabledTrackedPaths
        let ids = enabledPaths.map(\.id)
        guard ids != watchedPathIDs else { return }

        watchedPathIDs = ids
        let urls = enabledPaths.map { $0.url.standardizedFileURL }

        Task { @MainActor in
            if let watcher = fileEventsWatcher {
                await watcher.stop()
            }
            fileEventsWatcher = nil

            guard !urls.isEmpty else { return }

            let watcher = FSEventsWatcher(pathsToWatch: urls, debounceInterval: 2.0)
            await watcher.setOnChange { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleAutomaticScan()
                }
            }
            fileEventsWatcher = watcher
            await watcher.start()
        }
    }

    private func scheduleAutomaticScan() {
        autoScanTask?.cancel()

        let debounce = isUnderDiskPressure ? pressureAutoScanDebounce : normalAutoScanDebounce
        autoScanTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(debounce * 1000)))
            guard !Task.isCancelled else { return }
            guard !isLoading else { return }

            let minimumInterval = isUnderDiskPressure ? pressureAutoScanInterval : normalAutoScanInterval
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

            isAutoScanning = true
            await loadCategoryGrowthList(isAutomatic: true)
            isAutoScanning = false
        }
    }

    deinit {}
}
