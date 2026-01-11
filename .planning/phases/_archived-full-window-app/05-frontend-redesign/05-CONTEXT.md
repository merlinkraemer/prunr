# Phase 5: Growth Journal UX - Context

**Gathered:** 2025-01-10
**Updated:** 2025-01-11
**Status:** Ready for planning

<vision>
## How This Should Work

Prunr is a filesystem growth journal that answers "What filled my disk?" When you open Prunr:

**Left Sidebar:** A list of scan locations like Finder's sidebar (Home, Documents, Downloads, Desktop, Developer, etc.). You can add/remove paths, and it remembers your choices. Click a path to scan it.

**Right Main Area:** A growth list showing what changed in the selected time window:
- **Time filter:** [1d] [7d] [30d] — show what grew in this period
- **Growth bars:** Visual bars (█) showing relative size change
- **Smart grouping:** Scattered files grouped logically (Homebrew: postgresql, node_modules, etc.)
- **Sorted by:** Biggest growth first

**Drill-down:** Click any group → see individual files → [Reveal in Finder] [Delete]

The key insight: Homebrew, npm, and apps scatter files across multiple directories. Smart grouping links these together so users see "Homebrew: 12GB" not 50 tiny entries.

**Target UX:**
```
┌─────────────────────────────────────┐
│ Home +43GB in 7d  [1d][7d][30d]    │
├─────────────────────────────────────┤
│ ▸ Desktop                 +45GB ████│
│ ▸ Homebrew: postgresql    +12GB ███ │
│ ▸ tmp-videos-folder       +25GB 🆕  │
│ ▸ node_modules            +8GB  ██  │
│ └─ ~/Library/Caches       +3GB  █   │
└─────────────────────────────────────┘
```

</vision>

<essential>
## What Must Be Nailed

- **Smart grouping** - Detect Homebrew, npm, apps → link scattered paths. This is the key differentiator.

- **Growth bars** - Visual feedback makes big changes obvious at a glance. Relative size indicators.

- **Time windows** - 1d / 7d / 30d. Covers "yesterday", "last week", "last month" use cases.

- **Directory-level snapshots** - ~500KB/snapshot. Sufficient for "what grew" questions.

</essential>

<boundaries>
## What's Out of Scope

- **Cleanup actions** - Delete, move to trash, file operations. That's Phase 6.
- **Exact Finder replication** - Inspired by Finder, simpler behavior is fine.
- **Heavy polish** - Function over form. Animations, hover states, refined styling deferred if needed for shipping.
- **File-level snapshots** - Directory-level is sufficient. Individual files tracked later for delete operations.

</boundaries>

<specifics>
## Specific Ideas

- **Sidebar:** Like Finder's sidebar with section headers. Default paths: Home, Documents, Downloads, Desktop, Developer. User can add/remove.

- **Time filter:** Three presets: 1 day, 7 days, 30 days. Shows growth within that window.

- **Smart grouping patterns:**
  - Homebrew: `/usr/local/Cellar/*`, `/usr/local/var/*`, `~/Library/Caches/Homebrew/*`
  - npm: `node_modules/` folders (across multiple projects)
  - Apps: `.app` bundles with their `~/Library/Containers/*` and `~/Library/Caches/*` grouped together
  - Xcode: `DerivedData/`, `.build/`, Archives

- **Growth bar rendering:** Calculate max growth in the set, render bars as proportional width. Use █ character or native SwiftUI progress bar.

- **Drill-down:** Click group → expand to show individual files. Click file → reveal in Finder.

</specifics>

<notes>
## Additional Context

**User priorities:**
- Smart grouping is the core value — scattered files → logical groups
- Visual growth bars make the answer obvious at a glance
- Simple time windows (1d/7d/30d) cover the main use cases

**Technical constraints from research:**
- NavigationSplitView for sidebar + main layout
- @AppStorage for persisting tracked paths
- Target macOS 14+ (Sonoma)

**Key differentiator vs DaisyDisk:**
- DaisyDisk: Shows what's big now
- Prunr: Shows what GREW over time + groups scattered files

</notes>

---

*Phase: 05-growth-journal-ux*
*Context gathered: 2025-01-10*
*Updated: 2025-01-11 — clarified smart grouping vision*
*Ready for planning: yes*
