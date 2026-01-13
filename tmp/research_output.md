TOPIC 1: Push Animation (ISS-040, ISS-036)
Why Your ZStack Approach Creates Overlap
Your current implementation causes visual overlap because:

swift
// ❌ CURRENT APPROACH - Creates Overlapping
ZStack {
    categoryListView
        .offset(x: selectedCategory == nil ? 0 : -320)  // Moves left
    
    if selectedCategory != nil {
        categoryDetailView
            .offset(x: selectedCategory == nil ? 320 : 0)  // Slides in from right
    }
}
.animation(.easeInOut(duration: 0.3), value: selectedCategory)
The problem: Both views exist in the same ZStack layer simultaneously. When list moves left and detail slides in, they temporarily occupy the same space = visual overlap. SwiftUI renders both views at the same z-index, just with different x-offsets.

Why NavigationStack Isn't the Answer
macOS doesn't have iOS-style NavigationController push animations. NavigationStack on macOS defaults to sidebar/split view, not horizontal push animation. Finder's column view effect is actually a NavigationSplitView, not a push.

The Proper Solution: Conditional Rendering + .transition()
swift
struct CategoryGrowthListView: View {
    @State private var selectedCategory: CategoryGrowthItem?
    
    var body: some View {
        ZStack {
            if selectedCategory == nil {
                categoryListView
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading),
                        removal: .move(edge: .leading)
                    ))
            } else {
                categoryDetailView
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .trailing)
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: selectedCategory)
    }
    
    @ViewBuilder
    var categoryListView: some View {
        // List of categories
        // Selection changes state
    }
    
    @ViewBuilder
    var categoryDetailView: some View {
        // Detail view for selected category
        // Back button changes state to nil
    }
}
Why this works:

Only ONE view renders at a time - no overlap

List exits left while detail enters right - synchronized push effect

No transparency fighting - SwiftUI handles transition timing

Native macOS animation feel - smooth, coordinated motion

For Finder-Style Back Navigation
swift
categoryDetailView
    .transition(.asymmetric(
        insertion: .move(edge: .trailing),
        removal: .move(edge: .leading)  // ← Exits opposite direction
    ))
    .overlay(alignment: .topLeading) {
        Button(action: goBack) {
            Image(systemName: "chevron.left")
        }
        .padding(12)
    }

func goBack() {
    withAnimation(.easeInOut(duration: 0.3)) {
        selectedCategory = nil  // ← Triggers reverse animation
    }
}
When user clicks back:

Detail view exits LEFT (came from right)

List re-enters from LEFT (exits left originally)

Creates "unfolding" push effect, reverse of entry

TOPIC 2: Real-Time Storage Updates (ISS-042, ISS-032)
Why @Observable Updates Don't Refresh Menu Bar
Your MenuBarManager is @Observable, but the NSStatusItem button doesn't automatically sync:

swift
// ❌ Problem: @Observable updates SwiftUI views, NOT NSAppKit
@MainActor
@Observable
final class MenuBarManager: NSObject {
    var freeBytes: Int64 = 0  // ← Updates SwiftUI views automatically
    
    func updateFreeSpace() {
        self.freeBytes = DiskSpaceService.shared.getFreeSpace()
        // ← DriveBarView sees this change immediately
        // ← NSStatusItem.button.title does NOT
    }
}

// In popup (SwiftUI):
DriveBarView(manager: manager)  // ✅ Updates automatically

// In menu bar (AppKit):
statusItem?.button?.title = ???  // ❌ Still shows old value
Root cause: The menu bar icon is pure AppKit (NSStatusItem.button). SwiftUI @Observable only propagates changes to SwiftUI views, not to AppKit controls.

Solution: Explicit Menu Bar Updates
swift
@MainActor
@Observable
final class MenuBarManager: NSObject {
    var freeBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var usedBytes: Int64 = 0
    var statusItem: NSStatusItem?
    
    // CRITICAL: This must be called whenever storage changes
    func updateFreeSpace() {
        let free = DiskSpaceService.shared.getFreeSpace()
        let total = DiskSpaceService.shared.getTotalSpace()
        
        self.freeBytes = free
        self.totalBytes = total
        self.usedBytes = total - free
        
        // ← NEW: Explicitly sync menu bar
        updateMenuBarDisplay()
    }
    
    // CRITICAL: New method for AppKit synchronization
    private func updateMenuBarDisplay() {
        let gb = Double(freeBytes) / 1_000_000_000
        statusItem?.button?.title = "\(String(format: "%.1f", gb)) GB"
    }
    
    // CRITICAL: Call this after scans complete
    func loadCategoryGrowthList() async {
        isLoading = true
        // ... scanning logic ...
        isLoading = false
        
        // NEW: Trigger storage update after scan
        updateFreeSpace()  // ← This line was missing!
    }
    
    // CRITICAL: New: For auto-updates every 2 seconds
    func startRealtimeUpdates() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateFreeSpace()
        }
    }
}
Architecture: Hybrid Update System (Recommended)
swift
@main
struct PrunrApp: App {
    @State private var menuBarManager = MenuBarManager()
    
    var body: some Scene {
        MenuBarExtra("", systemImage: "externaldrive") {
            PopoverContentView()
                .environmentObject(menuBarManager)
        }
        .onAppear {
            // 1. Initial update
            menuBarManager.updateFreeSpace()
            
            // 2. Timer: Refresh menu bar every 2 seconds
            menuBarManager.startRealtimeUpdates()
            
            // 3. FSEvents: Monitor path for immediate response
            menuBarManager.setupFSEventsMonitoring()
        }
    }
}

// FSEvents monitoring for immediate updates
extension MenuBarManager {
    func setupFSEventsMonitoring() {
        let path = FileManager.default.expandPath("~/dev/projects")
        
        // Monitor file system changes using FSEvents
        FSEventStream(
            paths: [path],
            sinceWhen: .init(kFSEventStreamEventIdSinceNow),
            flags: [.useExtendedDataInitFlag, .fullHistory],
            handler: { [weak self] _ in
                // When files change, immediately trigger scan
                Task { @MainActor in
                    await self?.loadCategoryGrowthList()
                }
            }
        ).start()
    }
}
Update Timeline
text
Timeline of updates:

1. App Launch
   → updateFreeSpace() ✅ Menu bar shows GB
   → startRealtimeUpdates() starts

2. User Creates/Deletes Files
   → FSEvents detects change
   → loadCategoryGrowthList() triggered
   → updateFreeSpace() called (now included)
   → Menu bar updates + SwiftUI views refresh ✅

3. Timer Tick (every 2 seconds)
   → updateFreeSpace() called
   → Menu bar and popup stay in sync ✅

4. Popup Closes/Opens
   → Updates still happening in background
   → Menu bar always current (not just on open)
Why Menu Bar Shows System Drive, Not Monitored Path
Research shows apps like Stats display:

Menu bar: System drive free space (universal, always relevant)

Popover: Path-specific analysis and growth

Users expect menu bar to show disk space. Keep this convention:

swift
// Menu bar = system drive
statusItem?.button?.title = "\(systemDriveFreeGB) GB"

// Popover = monitored path growth
DrivePrintView {
    CategoryGrowthListView()  // Shows ~/dev/projects growth
}
Key Technical Fixes Summary
Animation (ISS-040, ISS-036)
✅ Replace ZStack offset with conditional rendering

✅ Use .transition(.asymmetric()) for coordinated push/pop

✅ Only one view visible at a time (no overlap)

✅ Back button triggers reverse animation automatically

Real-Time Updates (ISS-042, ISS-032)
✅ Add updateFreeSpace() call in loadCategoryGrowthList()

✅ Create explicit updateMenuBarDisplay() method

✅ Add Timer for consistent 2-second updates

✅ Add FSEvents monitoring for immediate response

✅ System drive in menu bar, path-specific in popover

