# Phase 5: Frontend Redesign - Context

**Created:** 2025-01-10
**User Requirements Provided**

## Vision

Complete redesign of Prunr's UI to follow macOS Finder patterns - sidebar for path management, column view for navigation, and simplified time-based comparison.

## Detailed Requirements

### 1. Left Sidebar (Scan Paths)
**Like Finder's sidebar:**
- Customizable list of paths to watch/scan
- Default list included (Home, Documents, Downloads, Desktop, etc.)
- Add/remove paths functionality
- Persistent (saved to UserDefaults or database)

**UI Pattern:** Finder-style sidebar with:
- Section headers (Favorites, Devices, etc.)
- Clickable path items
- Add/remove buttons (or drag-drop)
- Visual indication of currently selected path

### 2. Right Main Area (Column View)
**Like Finder's Column View:**
- Column 1: Categories (Files/Folders, Apps, Packages, Containers, etc.)
- Column 2: Specific items within selected category
- Column 3: Details about selected item (size, growth, delta info)

**Navigation:**
- Click category → shows items in next column
- Click item → shows details in next column
- Arrow keys navigate between columns
- Back/forward navigation support

### 3. Top Bar (Comparison Controls)
**Simplified from current 2-snapshot picker:**
- "Rescan" button
- "Compare Since" dropdown with presets:
  - 1 hour ago
  - 12 hours ago
  - 24 hours ago
  - 3 days ago
  - 7 days ago
  - Custom date picker
- Always compares: "since X" vs "current state" (no need to select 2 snapshots)

### 4. Future Features (Out of Scope for Phase 5)
- Cleanup actions (delete, move to trash)
- Add to roadmap as future phase

## Technical Implications

### Data Model Changes Needed
1. **Tracked Paths Model**
   - Store user's scan paths
   - Persist order and sections
   - Mark default vs user-added

2. **Categorization Logic**
   - Determine item category (App, Package, Container, regular file/folder)
   - Group deltas by category for Column 1

3. **Comparison Model**
   - Change from "snapshot A vs snapshot B" to "since X vs current"
   - Always compare latest scan vs historical scan at time X
   - May need to create "current" state on-demand if no scan exists

### SwiftUI Components to Research
1. **NavigationSplitView** - For sidebar + main content layout
2. **OutlineGroup** or **List** - For sidebar structure
3. **Custom column view** - Not a stock SwiftUI component (need to build)
4. **UserDefaults** or **AppStorage** - For persisting paths
5. **Toolbar** - For top bar controls

## Open Questions

1. **Column View Implementation**: SwiftUI doesn't have a stock "column view" like NSBrowser. Options:
   - Build custom with HStack of Lists
   - Use NSBrowser wrapped via NSViewRepresentable
   - Use NavigationSplitView with depth

2. **Categorization**: How to detect item type?
   - Bundle inspection for .app
   - File extension checking
   - Path pattern matching (~/Library/Containers/*)
   - MIME type detection

3. **"Current State"**: When user selects "Compare Since 24h ago":
   - If scan exists from 24h ago, use it
   - If no exact match, find closest scan
   - Always compare against most recent scan (or trigger new scan)

4. **Path Persistence**: Where to store tracked paths?
   - UserDefaults (simple, limited to ~100 paths)
   - SQLite table (more scalable, allows metadata)
   - JSON file (human-editable)

## Constraints

- Must follow macOS design patterns (HIG)
- Target macOS 14+ (Sonoma)
- Keep performance snappy with thousands of items
- Maintain existing backend (Scanner, DeltaService, DatabaseManager)
