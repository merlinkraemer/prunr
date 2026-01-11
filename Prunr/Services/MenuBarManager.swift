import AppKit
import SwiftUI

@MainActor
@Observable
final class MenuBarManager: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    var popover: NSPopover?
    var isPopoverShown = false

    /// FSEvents service for file system monitoring
    private let fseventsService = FSEventsService.shared

    /// Baseline service for growth tracking
    private let baselineService = BaselineService.shared

    /// Right-click menu
    private var contextMenu: NSMenu?
    
    // MARK: - Scan & Growth Logic (Moved from ViewModel)
    
    // Published state for UI
    var growthItems: [BaselineService.GrowthItem] = []
    var monitoredPathName: String = ""
    var isLoading = false
    var errorMessage: String?
    var noBaseline = false
    var scanProgress: String = ""
    var filesScanned: Int = 0
    
    // Disk space state
    var totalBytes: Int64 = 0
    var usedBytes: Int64 = 0
    var freeBytes: Int64 = 0
    
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
        popover?.contentSize = NSSize(width: 320, height: 420)
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
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        // Right-click shows menu, left-click shows popover
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        guard let menu = contextMenu, let button = statusItem?.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func openSettings() {
        // Close popover if open
        popover?.performClose(nil)
        isPopoverShown = false
        
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)

        // Bring Settings window to front (works even if already open)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            if let settingsWindow = NSApp.windows.first(where: { $0.title.contains("Settings") }) {
                settingsWindow.makeKeyAndOrderFront(nil)
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
        } catch {
            print("[MenuBarManager] Failed to reset baseline: \(error)")
        }
    }
    
    // MARK: - Scan & Growth Logic (Moved from ViewModel)
     
    // Properties are now synthesized by @Observable macro at class level
    // and initialized above.
    
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
    
    /// Reveals the given path in Finder
    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover = popover, popover.isShown {
            popover.performClose(nil)
            isPopoverShown = false
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            isPopoverShown = true
            popover?.contentViewController?.view.window?.makeKey()
            
            // Just check baseline on open
            Task {
                await checkBaseline()
            }
        }
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

    // MARK: - FSEvents Integration

    /// Starts watching paths from Settings for file system changes.
    private func startWatchingPaths() async {
        let enabledPaths = SettingsStore.shared.enabledTrackedPaths
        let urls = enabledPaths.map { $0.url }
        
        print("[MenuBarManager] Starting to watch: \(urls.map { $0.path })")

        // Set up callback to detect changes under tracked paths
        fseventsService.onChangedPaths = { [weak self] changedPaths in
            guard let self else { return }

            // Only rescan if we have a baseline
            Task {
                if await self.baselineService.hasBaseline() {
                    let trackedPaths = enabledPaths
                    var shouldRescan = false

                    for changedPath in changedPaths {
                        for trackedPath in trackedPaths {
                            if changedPath.path.hasPrefix(trackedPath.url.path) {
                                print("[MenuBarManager] Change detected: \(changedPath.path)")
                                shouldRescan = true
                            }
                        }
                    }
                    
                    if shouldRescan {
                        print("[MenuBarManager] Auto-triggering scan due to file changes...")
                        await self.loadGrowthList()
                    }
                }
            }
        }

        // Start watching asynchronously
        await fseventsService.startWatching(paths: urls)
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
        Task {
            await generateTestData()
        }
    }
    
    /// Generates test data at the default test path
    func generateTestData() async {
        let testDataPath = "/Users/merlinkramer/dev/projects/prunr/test_data"
        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: testDataPath)
        
        do {
            // Create base directory
            try fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
            
            // Create small random files for quick testing (~10MB total)
            let timestamp = Int(Date().timeIntervalSince1970)
            let folders: [(name: String, sizeKB: Int, fileCount: Int)] = [
                ("documents", 500, 2),   // 1 MB
                ("images", 1000, 3),     // 3 MB
                ("cache", 200, 5),       // 1 MB
                ("downloads", 2000, 2),  // 4 MB
                ("logs", 100, 5)         // 0.5 MB
            ]
            
            var totalCreated = 0
            for folder in folders {
                let folderURL = baseURL.appendingPathComponent(folder.name)
                try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
                
                let sizeBytes = folder.sizeKB * 1024
                
                for i in 1...folder.fileCount {
                    let fileName = "\(folder.name)_\(timestamp)_\(i)_\(arc4random() % 10000).dat"
                    let fileURL = folderURL.appendingPathComponent(fileName)
                    
                    var bytes = [UInt8](repeating: 0, count: sizeBytes)
                    for j in 0..<sizeBytes {
                        bytes[j] = UInt8.random(in: 0...255)
                    }
                    try Data(bytes).write(to: fileURL)
                    totalCreated += sizeBytes
                }
            }
            
            print("[MenuBarManager] Created \(Double(totalCreated) / 1024.0 / 1024.0) MB of test data")
            
            // Note: FSEvents should pick this up automatically if validation is running
            
        } catch {
            print("[MenuBarManager] Failed to create test data: \(error)")
        }
    }
    
    // MARK: - NSPopoverDelegate
    
    func popoverDidClose(_ notification: Notification) {
        if isPopoverShown {
            isPopoverShown = false
            print("[MenuBarManager] Popover closed via delegate")
        }
    }
}
