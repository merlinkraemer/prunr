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

    /// FSEvents service for file system monitoring
    private let fseventsService = FSEventsService.shared

    /// Baseline service for growth tracking
    private let baselineService = BaselineService.shared

    /// Right-click menu
    private var contextMenu: NSMenu?
    
    // MARK: - Scan & Growth Logic (Moved from ViewModel)
    
    // Published state for UI
    var growthItems: [BaselineService.GrowthItem] = []
    var categoryItems: [CategoryGrowthItem] = []
    var monitoredPathName: String = ""
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
    var isLoading = false
    var isAutoScanning = false // Visual feedback for background scans
    var errorMessage: String?
    var noBaseline = false
    var scanProgress: String = ""
    var filesScanned: Int = 0

    // Scan timing for minimum display duration
    private var scanStartTime: Date?
    private let minimumDisplayDuration: TimeInterval = 0.8 // 800ms
    
    // Disk space state
    var totalBytes: Int64 = 0
    var usedBytes: Int64 = 0
    var freeBytes: Int64 = 0
    var monitoredPathSizeBytes: Int64 = 0
    var isCalculatingPathSize = false

    // Cache for disk space updates (avoid excessive disk checks)
    private var lastFreeSpaceUpdate: Date?
    
    static var shared: MenuBarManager?
    
    // MARK: - Init

    override init() {
        super.init()
        Self.shared = self
        setupMenuBar()
        setupContextMenu()
        updateFreeSpace()
        startWatchingDefaultPaths()
    }

    private func setupMenuBar() {
        // Create status item in menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.action = #selector(handleButtonClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

        // Reset Baseline
        let resetItem = NSMenuItem(
            title: "Reset Baseline",
            action: #selector(resetBaseline),
            keyEquivalent: "r"
        )
        resetItem.target = self
        menu.addItem(resetItem)

        // Separator
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
            print("[MenuBarManager] Click debounced - too soon after last click (\(now.timeIntervalSince(lastClick))s)")
            return
        }
        lastClickTimestamp = now

        // Log click details for debugging (ISS-013)
        if let event = NSApp.currentEvent {
            print("[MenuBarManager] Click detected - type: \(event.type.rawValue), location: \(event.locationInWindow), timestamp: \(now.timeIntervalSince1970)")
            print("[MenuBarManager] isPopoverShown: \(isPopoverShown), popover.isShown: \(popover?.isShown ?? false)")
        } else {
            print("[MenuBarManager] Click detected - NO CURRENT EVENT (async call), timestamp: \(now.timeIntervalSince1970)")
            // Don't return here - continue to toggle popover even without event
        }

        // The action is called for both left and right mouse up
        // We need to determine which type of click occurred
        if let event = NSApp.currentEvent {
            // Right-click shows menu, left-click shows popover
            if event.type == .rightMouseUp {
                print("[MenuBarManager] Right-click detected, showing context menu")
                showContextMenu()
                return
            }
        }

        // Default to showing popover for left-click or when event is unavailable
        print("[MenuBarManager] Toggling popover (left-click or no event)")
        togglePopover()
    }

    private func showContextMenu() {
        guard let menu = contextMenu, let button = statusItem?.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func openSettings() {
        print("[MenuBarManager] Opening settings from context menu")

        // Close popover if open
        if let popover = popover, popover.isShown {
            popover.performClose(nil)
            isPopoverShown = false
            print("[MenuBarManager] Closed popover before opening settings")
        }

        // Small delay to ensure popover is fully closed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            print("[MenuBarManager] Sending showSettingsWindow action")
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)

            // Bring Settings window to front immediately - ISS-024
            // Use a very short delay (50ms) to let window creation complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.activate(ignoringOtherApps: true)

                // Find settings window by title
                if let settingsWindow = NSApp.windows.first(where: {
                    $0.title.contains("Settings")
                }) {
                    print("[MenuBarManager] Found settings window: \(settingsWindow.title)")

                    // Ensure window behavior is correct
                    settingsWindow.hidesOnDeactivate = false

                    // Temporarily elevate window level to bring to front
                    let originalLevel = settingsWindow.level
                    settingsWindow.level = .floating
                    settingsWindow.makeKeyAndOrderFront(nil)
                    settingsWindow.orderFrontRegardless()

                    // Reset to normal level immediately after focusing (no delay)
                    settingsWindow.level = originalLevel

                    print("[MenuBarManager] Settings window brought to front")
                } else {
                    print("[MenuBarManager] WARNING: Could not find settings window, retrying...")
                    // If window not found yet, try once more with a longer delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.activate(ignoringOtherApps: true)
                        if let settingsWindow = NSApp.windows.first(where: { $0.title.contains("Settings") }) {
                            settingsWindow.hidesOnDeactivate = false
                            settingsWindow.level = .floating
                            settingsWindow.makeKeyAndOrderFront(nil)
                            settingsWindow.orderFrontRegardless()
                            settingsWindow.level = .normal
                            print("[MenuBarManager] Settings window brought to front on retry")
                        }
                    }
                }
            }
        }
    }


    @objc private func resetBaseline() {
        Task {
            await performReset()
        }
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
    
    // MARK: - Scan & Growth Logic (Moved from ViewModel)
     
    // Properties are now synthesized by @Observable macro at class level
    // and initialized above.
    
    /// Loads the category-based growth list
    func loadCategoryGrowthList() async {
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
        scanProgress = "Scanning \(trackedPath.displayName)..."

        // Record scan start time for minimum display duration
        let startTime = Date()
        scanStartTime = startTime
        let scanStartTimeForProgress = startTime

        print("[MenuBarManager] Loading category growth list for: \(trackedPath.url.path)")

        var wasCancelled = false

        // Create progress callback for updating UI during scan
        // Note: MainActor.run ensures UI updates happen on main thread
        let progressCallback: (ScanService.ScanProgress) -> Void = { progress in
            Task { @MainActor in
                // Update files scanned count
                self.filesScanned = progress.foldersScanned

                // Show detailed progress after 2 seconds
                let elapsed = Date().timeIntervalSince(scanStartTimeForProgress)
                if elapsed >= 2.0 {
                    // Extract basename from path for cleaner display
                    let basename = URL(fileURLWithPath: progress.currentPath).lastPathComponent
                    let parent = URL(fileURLWithPath: progress.currentPath).deletingLastPathComponent().lastPathComponent

                    // Show "Scanning parent/basename..." for long scans
                    self.scanProgress = "Scanning \(parent)/\(basename)..."
                }
            }
        }

        do {
            let items = try await baselineService.getCategoryGrowthList(trackedPath: trackedPath, progress: progressCallback)
            categoryItems = items
            scanProgress = ""
            print("[MenuBarManager] Loaded \(items.count) category items")
        } catch {
            if let baselineError = error as? BaselineService.BaselineError,
               case .noBaseline = baselineError {
                print("[MenuBarManager] No baseline exists")
                noBaseline = true
                categoryItems = []
            } else if let scanError = error as? ScanError, case .cancelled = scanError {
                print("[MenuBarManager] Scan was cancelled")
                scanProgress = "Cancelled"
                wasCancelled = true
            } else {
                print("[MenuBarManager] Error loading category growth list: \(error)")
                errorMessage = "Scan failed: \(error.localizedDescription)"
            }
        }

        // Calculate elapsed time
        let elapsed = Date().timeIntervalSince(startTime)

        // Apply minimum display duration (skip on cancellation or if stop was pressed)
        let shouldSkipDelay = wasCancelled || scanStartTime == nil
        if !shouldSkipDelay && elapsed < minimumDisplayDuration {
            let delay = minimumDisplayDuration - elapsed
            print("[MenuBarManager] Applying minimum display delay: \(delay * 1000)ms")
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
        }

        isLoading = false
        scanProgress = ""
        filesScanned = 0
        scanStartTime = nil
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
        scanProgress = "Scanning \(trackedPath.displayName)..."
        
        print("[MenuBarManager] Loading growth list for: \(trackedPath.url.path)")

        do {
            let items = try await baselineService.getGrowthList(trackedPath: trackedPath)
            growthItems = items
            scanProgress = ""
            print("[MenuBarManager] Loaded \(items.count) growth items")
        } catch {
            if let baselineError = error as? BaselineService.BaselineError,
               case .noBaseline = baselineError {
                print("[MenuBarManager] No baseline exists")
                noBaseline = true
                growthItems = []
            } else if let scanError = error as? ScanError, case .cancelled = scanError {
                print("[MenuBarManager] Scan was cancelled")
                scanProgress = "Cancelled"
            } else {
                print("[MenuBarManager] Error loading growth list: \(error)")
                errorMessage = "Scan failed: \(error.localizedDescription)"
            }
        }

        isLoading = false
        scanProgress = ""
    }
    
    /// Creates a new baseline from enabled paths
    func createBaseline() async {
        let enabledPaths = SettingsStore.shared.enabledTrackedPaths
        guard let trackedPath = enabledPaths.first else {
            errorMessage = "No paths enabled in Settings"
            return
        }
        
        isLoading = true
        errorMessage = nil
        filesScanned = 0
        scanProgress = "Creating baseline for \(trackedPath.displayName)..."
        
        print("[MenuBarManager] Creating baseline for: \(trackedPath.url.path)")
        
        do {
            _ = try await baselineService.createBaseline(trackedPath: trackedPath)
            noBaseline = false
            scanProgress = ""
            print("[MenuBarManager] Baseline created successfully")
            
            // Start watching this new path
            await startWatchingPaths()
            
        } catch {
            if let scanError = error as? ScanError, case .cancelled = scanError {
                print("[MenuBarManager] Baseline creation cancelled")
                scanProgress = "Cancelled"
            } else {
                print("[MenuBarManager] Error creating baseline: \(error)")
                errorMessage = error.localizedDescription
            }
        }
        
        isLoading = false
        scanProgress = ""
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
            NSApp.activate(ignoringOtherApps: true)
            if let finderBundle = Bundle(url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")) {
                let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundle.bundleIdentifier!).first
                runningApp?.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else {
            print("[MenuBarManager] togglePopover: No button available")
            return
        }

        // Check actual popover state, not just cached flag (ISS-013)
        let actualPopoverState = popover?.isShown ?? false
        print("[MenuBarManager] togglePopover - isPopoverShown: \(isPopoverShown), actual popover.isShown: \(actualPopoverState)")

        if let popover = popover, actualPopoverState {
            // Popover is actually shown, close it
            print("[MenuBarManager] Closing popover")
            popover.performClose(nil)
            isPopoverShown = false
        } else {
            // Popover is not shown, show it
            print("[MenuBarManager] Showing popover")

            // Ensure popover is not already shown before showing
            if let popover = popover, !popover.isShown {
                // ISS-025: Store the menubar screen for multi-monitor setups
                // We'll use this to prevent the popup from jumping to other screens
                guard let buttonWindow = button.window,
                      let screen = buttonWindow.screen else {
                    print("[MenuBarManager] WARNING: Could not get menubar screen")
                    return
                }

                // Activate app to ensure popup comes to front
                NSApp.activate(ignoringOtherApps: false)

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
                            print("[MenuBarManager] WARNING: Popup jumped to wrong screen, closing and reopening")
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
                                    print("[MenuBarManager] Popup reopened on correct screen")
                                }
                            }
                        } else {
                            popoverWindow.makeKey()
                            print("[MenuBarManager] Popup on correct screen: \(screen.localizedName)")
                        }
                    }
                }
            } else {
                print("[MenuBarManager] Popover already shown or nil, not showing again")
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
        
        // Update observable state for UI
        self.freeBytes = free
        self.totalBytes = total
        self.usedBytes = total - free
        
        // Update menu bar text
        let gb = Double(free) / 1_000_000_000

        
        // Also update view state
        // totalBytes, etc. logic could be added here if needed for UI, 
        // but currently UI uses DriveBarView. For now we assume UI might need it.
        // We'll stick to updating the status bar text.

        if gb >= 1000 {
            let tb = gb / 1000
            updateFreeSpaceDisplay("\(String(format: "%.1f", tb)) TB")
        } else {
            updateFreeSpaceDisplay("\(String(format: "%.1f", gb)) GB")
        }
    }

    func updateFreeSpaceDisplay(_ freeSpace: String) {
        statusItem?.button?.title = freeSpace
    }

    /// Updates the monitored path size from the latest baseline or current state
    func updatePathSize() async {
        guard let trackedPath = SettingsStore.shared.enabledTrackedPaths.first else {
            self.monitoredPathSizeBytes = 0
            return
        }

        // Set loading state
        await MainActor.run {
            self.isCalculatingPathSize = true
        }

        // Try to calculate path size directly
        if let pathSize = try? await calculatePathSize(for: trackedPath) {
            await MainActor.run {
                self.monitoredPathSizeBytes = pathSize
                self.isCalculatingPathSize = false
            }
        } else {
            await MainActor.run {
                self.monitoredPathSizeBytes = 0
                self.isCalculatingPathSize = false
            }
        }
    }

    /// Calculates the total size of a path by scanning it
    private func calculatePathSize(for trackedPath: TrackedPath) async throws -> Int64 {
        let url = trackedPath.url
        var totalSize: Int64 = 0

        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey]
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                  let isDirectory = resourceValues.isDirectory,
                  !isDirectory else {
                continue
            }

            if let fileSize = resourceValues.totalFileAllocatedSize {
                totalSize += Int64(fileSize)
            }
        }

        return totalSize
    }

    // MARK: - FSEvents Integration

    /// Starts watching paths from Settings for file system changes.
    private func startWatchingPaths() async {
        let enabledPaths = SettingsStore.shared.enabledTrackedPaths
        let urls = enabledPaths.map { $0.url }

        print("[MenuBarManager] Starting to watch: \(urls.map { $0.path })")
        print("[MenuBarManager] Found \(enabledPaths.count) enabled paths")

        if enabledPaths.isEmpty {
            print("[MenuBarManager] WARNING: No enabled paths found in Settings!")
            return
        }

        // Set up callback to detect changes under tracked paths
        fseventsService.onChangedPaths = { [weak self] changedPaths in
            guard let self else { return }

            print("[MenuBarManager] FSEvents callback triggered with \(changedPaths.count) changed paths")
            for path in changedPaths {
                print("[MenuBarManager]   - Changed: \(path.path)")
            }

            // Only rescan if we have a baseline
            Task {
                let hasBaseline = await self.baselineService.hasBaseline()
                print("[MenuBarManager] hasBaseline = \(hasBaseline)")

                if hasBaseline {
                    let trackedPaths = enabledPaths
                    var shouldRescan = false

                    for changedPath in changedPaths {
                        for trackedPath in trackedPaths {
                            if changedPath.path.hasPrefix(trackedPath.url.path) {
                                print("[MenuBarManager] Change detected under tracked path: \(changedPath.path)")
                                shouldRescan = true
                            }
                        }
                    }

                    if shouldRescan {
                        print("[MenuBarManager] Auto-triggering scan due to file changes...")
                        // Set auto-scanning flag for visual feedback
                        await MainActor.run {
                            self.isAutoScanning = true
                        }
                        await self.loadCategoryGrowthList()
                        await MainActor.run {
                            self.isAutoScanning = false
                        }
                    } else {
                        print("[MenuBarManager] Changes detected but not under tracked paths, skipping rescan")
                    }
                } else {
                    print("[MenuBarManager] No baseline exists, skipping autoscan")
                }
            }
        }

        // Start watching asynchronously
        await fseventsService.startWatching(paths: urls)
        print("[MenuBarManager] FSEvents started watching")
    }
    
    /// Initial watcher setup
    private func startWatchingDefaultPaths() {
        Task {
            await startWatchingPaths()
        }
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
        print("[MenuBarManager] popoverDidClose called - isPopoverShown was: \(isPopoverShown)")
        if isPopoverShown {
            isPopoverShown = false
            print("[MenuBarManager] Popover closed via delegate, isPopoverShown reset to false")
        }
    }

    func popoverWillClose(_ notification: Notification) {
        print("[MenuBarManager] popoverWillClose called - preparing to close")
        // Early state sync for better reliability (ISS-013)
        if isPopoverShown {
            isPopoverShown = false
            print("[MenuBarManager] isPopoverShown reset to false in willClose")
        }
    }
}
