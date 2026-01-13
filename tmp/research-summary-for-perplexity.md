# SwiftUI macOS Animation & Storage Monitoring Research

## App Context: Prunr - Storage Monitoring Menu Bar App

**Technology Stack:**
- macOS 14+ (Sonoma) with SwiftUI
- NSStatusItem (menu bar icon) + NSPopover (popup window, 320x480pt)
- @Observable (not @ObservableObject) for state management
- @MainActor for UI updates

**App Architecture:**
- User's menu bar shows GB free (e.g., "45.2 GB")
- Click menu bar icon → opens popover popup
- Popover shows:
  - **Storage bar** (visual bar showing drive usage percentage)
  - **Monitor path** (e.g., "~/dev/projects")
  - **Category list** (growth by category: Downloads, node_modules, etc.)
- Click category → **drill-down view** shows all items in that category
- Need proper navigation animation between list and detail views

---

## RESEARCH TOPIC 1: macOS Native Push Animation (Finder-Style)

### Current Implementation (Overlapping, Not Pushing)

```swift
// CategoryGrowthListView.swift
// Current animation using ZStack with offsets
ZStack {
    // Background dimming overlay
    if selectedCategory != nil {
        Color.black.opacity(0.1)
            .ignoresSafeArea()
    }

    // Category list (main view)
    categoryListView
        .offset(x: selectedCategory == nil ? 0 : -320)  // Move left when drilled down

    // Category detail (drill-down view)
    if selectedCategory != nil {
        categoryDetailView
            .offset(x: selectedCategory == nil ? 320 : 0)  // Slide in from right
    }
}
.animation(.easeInOut(duration: 0.3), value: selectedCategory)
```

### Problem
- Detail view slides OVER the main list (overlap)
- Main list doesn't visibly move aside
- Not like macOS Finder's column view where columns slide
- Looks like overlay/fade, not push navigation

### What We Need
**macOS Finder-style push animation where:**
1. **Main view visibly pushes LEFT** and slides off-screen
2. **Detail view slides IN from RIGHT** at the same time
3. **Both views move simultaneously** (synchronized)
4. **No transparency/overlap** during animation
5. **Feels like native macOS navigation** (Finder column view, System Preferences panes)

**Similar to:**
- Finder's column view navigation (command-click columns to navigate back)
- System Preferences pane transitions
- iOS NavigationController push (but for macOS)

### Current View Structure
```swift
struct CategoryGrowthListView: View {
    @State private var selectedCategory: CategoryGrowthItem?
    @State private var maxWidth: CGFloat = 320

    var body: some View {
        ZStack {
            // Two views that need to swap with push animation
            categoryListView  // Main list
            categoryDetailView // Detail view (when selected)
        }
    }
}
```

### Specific Questions for Perplexity

**Q1:** In SwiftUI for macOS, how do I implement a Finder-style push animation for navigating between two views in a fixed-width container (320pt)?
- View A should slide LEFT and off-screen
- View B should slide IN from RIGHT simultaneously
- Both views are fully opaque (no transparency/overlap)
- Similar to Finder's column view navigation

**Q2:** What's the correct SwiftUI approach for macOS native-style push navigation:
1. NavigationStack (iOS-style, works on macOS?)
2. Custom ZStack with .offset() and .animation() - what am I doing wrong?
3. GeometryReader with position()
4. .transition(.move(edge:)) modifier
5. MatchedGeometryEffect for coordinated motion
6. Something else entirely for macOS?

**Q3:** My current ZStack with offsets causes overlapping. How do I:
- Ensure both views are fully visible during animation (no z-index fighting)
- Coordinate timing so they move exactly together
- Make it feel like native macOS animation (easeInOut? duration? curve?)
- Handle the animation "in place" without layout shifts

### Code Context

**View hierarchy:**
```
MenuBarView (320x480 NSPopover)
├── StorageBar (always visible, 80pt height)
└── CategoryGrowthListView (remaining space)
    ├── CategoryListView (main list of categories)
    └── CategoryDetailView (drill-down items)
```

**State management:**
```swift
@State private var selectedCategory: CategoryGrowthItem?

func selectCategory(_ item: CategoryGrowthItem) {
    selectedCategory = item  // Should trigger push animation
}

func goBack() {
    selectedCategory = nil  // Should trigger reverse push animation
}
```

### Reference Behavior
Watch macOS Finder's column view:
1. Navigate to folder → columns slide left
2. Click earlier column → columns slide right
3. All motion is horizontal, synchronized, no fade
4. Columns never overlap or show transparency

---

## RESEARCH TOPIC 2: Real-Time Menu Bar Storage Updates

### Current Implementation (Not Updating)

```swift
// MenuBarManager.swift - manages NSStatusItem and NSPopover
@MainActor
@Observable
final class MenuBarManager: NSObject {
    var freeBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var usedBytes: Int64 = 0
    private var lastFreeSpaceUpdate: Date?

    // Called on popup open, but not after scans
    func updateFreeSpaceIfNeeded() {
        let cacheInterval: TimeInterval = 2.0  // Reduced from 5s

        if let lastUpdate = lastFreeSpaceUpdate,
           Date().timeIntervalSince(lastUpdate) < cacheInterval {
            return  // Cache hit - skip
        }

        updateFreeSpace()
        lastFreeSpaceUpdate = Date()
    }

    func updateFreeSpace() {
        let free = DiskSpaceService.shared.getFreeSpace()
        let total = DiskSpaceService.shared.getTotalSpace()

        self.freeBytes = free
        self.totalBytes = total
        self.usedBytes = total - free

        // Update menu bar icon text
        let gb = Double(free) / 1_000_000_000
        statusItem?.button?.title = "\(String(format: "%.1f", gb)) GB"
    }

    // Scan completion - DOESN'T call updateFreeSpace()
    func loadCategoryGrowthList() async {
        isLoading = true
        // ... scanning logic ...
        isLoading = false

        // PROBLEM: No updateFreeSpace() call here
        // Menu bar GB meter doesn't update after scan
    }
}
```

### Problem
1. **Menu bar GB meter doesn't update after scans**
   - Initial app launch: shows correct GB (e.g., "45.2 GB")
   - User creates 500MB file
   - User clicks "Scan Now" or auto-scan triggers
   - **Menu bar still shows "45.2 GB"** (should show "44.7 GB")
   - Only updates on app restart

2. **Drive bar in popup also doesn't update**
   - Storage bar visual (percentage fill) stays stale
   - @Observable properties changed but UI not refreshing
   - Same underlying issue as menu bar

3. **Current implementation only updates on popup open**
   - `updateFreeSpaceIfNeeded()` called in `.task { }` on view appear
   - Not called after scan completion
   - Not called on file system changes (FSEvents)

### What We Need
**Real-time storage updates like the "Stats" menu bar app:**
1. **Immediate update after any scan** (manual or auto)
2. **Reactive to file system changes** (via FSEvents)
3. **Efficient polling** (not spamming disk checks every second)
4. **Both locations update simultaneously:**
   - Menu bar icon text
   - Drive bar in popup

**Stats app reference:**
- Shows network/CPU usage in menu bar
- Updates in real-time (every 1-2 seconds)
- Lightweight, doesn't slow down system
- Updates visible even when popup closed

### Current Disk Space Service

```swift
// DiskSpaceService.swift
class DiskSpaceService {
    static let shared = DiskSpaceService()

    func getFreeSpace() -> Int64 {
        do {
            let values = try URL(fileURLWithPath: "/")
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            return 0
        }
    }

    func getTotalSpace() -> Int64 {
        do {
            let values = try URL(fileURLWithPath: "/")
                .resourceValues(forKeys: [.volumeTotalCapacityKey])
            return values.volumeTotalCapacity ?? 0
        } catch {
            return 0
        }
    }
}
```

### App Flow & When Updates Should Happen

```
1. App Launch
   → updateFreeSpace() ✓ (working)

2. Popup Opens
   → updateFreeSpaceIfNeeded() ✓ (working)

3. User Creates/Deletes Large Files
   → FSEvents detects change
   → Triggers auto-scan
   → Scan completes
   → ✗ updateFreeSpace() NOT called (BUG)

4. User Clicks "Scan Now"
   → Manual scan completes
   → ✗ updateFreeSpace() NOT called (BUG)

5. Periodic Refresh (Optional)
   → Timer fires every N seconds
   → Call updateFreeSpace() if needed
   → Not implemented yet
```

### Specific Questions for Perplexity

**Q1:** How does the "Stats" menu bar app (or similar system monitoring apps) achieve real-time updates in the menu bar?
- What's the update frequency (1s, 2s, 5s)?
- How to update NSStatusItem button title efficiently?
- Best practices for not degrading performance?

**Q2:** In my SwiftUI macOS app, when should I call `updateFreeSpace()`?
1. Immediately after scan completes in `loadCategoryGrowthList()`?
2. In FSEvents callback when file changes detected?
3. Using Timer.publish() every N seconds?
4. All of the above (coordinated approach)?

**Q3:** My @Observable properties (`freeBytes`, `totalBytes`) are updated but UI doesn't refresh. Why?
- Do I need explicit @MainActor.run { } wrapper?
- Should updateFreeSpace() be marked @MainActor?
- Do NSStatusItem updates need special handling?
- Why does DriveBarView in popup also not update when it observes these same properties?

**Q4:** What's the efficient pattern for monitoring disk space in real-time on macOS?
1. Polling with Timer (what interval?)
2. Combine pipeline with debounce
3. FSEvents-based reactive updates
4. NSWorkspace notification observers
5. Something else entirely?

**Q5:** How do I ensure BOTH locations update simultaneously:
- Menu bar: `statusItem?.button?.title = "45.2 GB"`
- Popup: Drive bar observes `@Bindable var manager: MenuBarManager` properties

Should I:
- Update properties then force UI refresh?
- Use NotificationCenter to broadcast changes?
- Rely on @Observable automatic propagation (currently not working)?

### Context for Path-Specific Monitoring

The app monitors a **specific path** (e.g., ~/dev/projects), not just root drive "/".

**Question:** Should the menu bar show:
1. **System drive** free space (what it currently does)?
2. **Monitored path** size usage (more relevant to user)?
3. **Both** (toggle between them)?
4. **Delta** (growth since baseline, not absolute size)?

For context: The app tracks growth since baseline. User wants to know "what grew since baseline" not "how big is my disk". But menu bar convention is to show disk space (like Stats, iStat Menus).

---

## What I Need from Research

### For Animation (Topic 1):
1. **Code example** of proper SwiftUI push animation for macOS
2. Explanation of why my ZStack approach causes overlap
3. Correct SwiftUI pattern for Finder-style navigation
4. Whether to use NavigationStack, custom container, or different approach

### For Storage Updates (Topic 2):
1. **Architecture pattern** for real-time menu bar updates
2. Where to place updateFreeSpace() calls (scan completion? FSEvents? timer?)
3. Why @Observable updates aren't refreshing UI
4. Best practices for efficient polling without degrading performance
5. Whether to monitor system drive or specific path (UX question)

---

## Key Technical Constraints

- **Must work in NSPopover** (not full window)
- **Fixed size: 320x480pt**
- **macOS 14+** (latest SwiftUI features available)
- **Menu bar app** (no dock icon, runs in background)
- **Transient popover** (auto-closes when user clicks outside)
- **@Observable** (SwiftData-style observation, not @ObservableObject)

## Current State

- Animation: Overlapping instead of pushing (ISS-040, ISS-036)
- Storage updates: Not updating after scans (ISS-042, ISS-032)
- Architecture: May need overhaul for proper navigation (ISS-039)

Please provide **SwiftUI code examples** and explain **why** current approach fails, not just "use X instead".
