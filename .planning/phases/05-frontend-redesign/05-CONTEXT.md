# Phase 5: Finder-Style Redesign - Context

**Gathered:** 2025-01-10
**Status:** Ready for planning

<vision>
## How This Should Work

Complete redesign following macOS Finder patterns. When you open Prunr, you see a familiar Finder-like interface:

**Left Sidebar:** A list of scan locations like Finder's sidebar (Home, Documents, Downloads, Desktop, etc.). You can add/remove paths, and it remembers your choices between launches. Click a path to scan it.

**Right Main Area:** A 3-column view for browsing what changed:
- **Column 1** shows categories: Apps, Packages, Containers, Caches, Developer, Other
- **Column 2** shows the items within that category that grew/shrank
- **Column 3** shows details about the selected item (size, delta, growth percentage)

**Top Bar:** Simplified controls - just a "Rescan" button and a "Compare Since" dropdown (1h, 12h, 24h, 3d, 7d, Custom). No more picking two snapshots - always compares "since X ago" vs "current state."

The feel should be Finder-inspired (not exact replication). Think "using Finder to explore what ate your disk space" rather than a custom interface.

</vision>

<essential>
## What Must Be Nailed

- **Everything together** - The sidebar + column view + simplified comparison work as a cohesive whole. The value is in the complete Finder-like experience, not individual pieces.

- **Fixed categories** - Column 1 uses predefined categories (Apps, Packages, Containers, Caches, Developer, Other). No custom categories for now.

- **"Since X ago" comparison** - Always compare a historical scan vs current state. User doesn't pick two snapshots anymore.

</essential>

<boundaries>
## What's Out of Scope

- **Cleanup actions** - Delete, move to trash, file operations. That's Phase 6.
- **Custom categories** - Fixed categories only. User customization can come later.
- **Exact Finder replication** - Inspired by Finder, simpler behavior is fine.
- **Heavy polish** - Function over form. Animations, hover states, refined styling deferred if needed for shipping.
- **NSBrowser complexity** - If NSBrowser is too complex, custom HStack of Lists is acceptable.

</boundaries>

<specifics>
## Specific Ideas

- **Sidebar:** Like Finder's sidebar with section headers. Default paths: Home, Documents, Downloads, Desktop, Developer. User can add/remove.
- **Categories:** Apps (.app bundles), Packages (.pkg, .app bundles in disguise), Containers (~/Library/Containers/*), Caches (~/Library/Caches/*), Developer (node_modules, build folders, Xcode DerivedData), Other (everything else).
- **Column navigation:** Click category → see items. Click item → see details. Arrow keys should work.
- **Comparison presets:** 1 hour, 12 hours, 24 hours, 3 days, 7 days, Custom date picker.

</specifics>

<notes>
## Additional Context

**User priorities:**
- Full redesign in one go - don't split into sidebar-first/columns-later
- Function over form - focus on layout and navigation working correctly
- Finder-inspired but not exact - simpler behavior acceptable

**Technical constraints from research:**
- NavigationSplitView for sidebar + main layout
- @AppStorage for persisting tracked paths
- Custom HStack of Lists for 3-column view (NSBrowser is backup plan)
- Target macOS 14+ (Sonoma)

</notes>

---

*Phase: 05-finder-style-redesign*
*Context gathered: 2025-01-10*
*Ready for planning: yes*
