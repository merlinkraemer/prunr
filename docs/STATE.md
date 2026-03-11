## Prunr — Current State

This document describes **what is implemented today**, at a high level, without referencing the previous phase-based planning system.

### Product state

- **MVP**: Complete.  
  - Menu bar–only app (`NSApp.setActivationPolicy(.accessory)`, no Dock icon).  
  - Baseline + growth tracking pipeline (scan → snapshot → delta → growth list).  
  - Popover UI with drive bar, category growth list, drill-down, and contextual empty/error states.  
  - Settings window with 3 tabs: **General**, **Folder Limits**, **About**.

- **Post-MVP polish**: Largely complete.  
  - Category-based grouping (10 categories) with nested big files (≥100 MB).  
  - Finder-style push navigation, back button, and header redesign.  
  - GB meter real-time updates in the menu bar (2s timer + explicit sync after scans).  
  - Improved scan progress overlay with percentage, file count, and cancel button.  
  - Auto-cleanup of old snapshots with periodic `VACUUM`.

- **In-progress / open**  
  - **Animation performance**: Transitions and list updates work, but there is still room for smoothing micro-jank (e.g., during heavy updates).  
  - **Conceptual shift to consecutive-scan comparison** is designed on paper but **not implemented**; the app still uses an explicit baseline.

### Architecture snapshot

- **UI**  
  - `PrunrMenuBar` is the `@main` app entry, wiring up the menu bar–only configuration and the Settings window.  
  - `MenuBarManager` is the central `@Observable` state object that owns:
    - The `NSStatusItem` and popover lifecycle.  
    - Scan orchestration and FSEvents callbacks.  
    - Disk space updates and settings navigation.  
  - `MenuBarView` builds the popover:
    - Top: Drive bar section (always visible).  
    - Middle: header (monitoring paths or drill-down header) and category list / drill-down content.  
    - Bottom: icon-only footer (scan + settings).

- **Services & data layer**  
  - `ScanService` (actor): async filesystem scans with streaming results and batched inserts.  
  - `BaselineService` (actor): creates baseline snapshots, runs comparison scans, and aggregates growth into per-path and per-category views.  
  - `CategoryDetectionService`: groups growth into semantic categories and identifies “big” items.  
  - `DatabaseManager`: GRDB-backed SQLite store, with:
    - Snapshot + snapshotEntry tables.  
    - Composite index on `(snapshotId, path)` for efficient delta queries.  
    - Batched insert API that uses prepared statements.  
  - `DatabaseCleanupService` (actor): retains up to **50 snapshots per tracked path**, deletes older ones, and vacuums periodically.

### Behavior guarantees

- A **baseline must exist** before growth views make sense; Prunr prompts for baseline creation when needed.  
- Scans can be triggered **manually** (via UI) or **automatically** (via FSEvents).  
- Auto-scans run in the background and **do not block** the UI with a full-screen overlay.  
- Manual scans show a **progress overlay** with:
  - Spinner + text (“Scanning…” or more detailed status).  
  - Progress bar and percentage (from 1% to 100%).  
  - File count and a **Stop** button that cancels the scan.

### Limitations (by design, for now)

- **Baseline model**  
  - Comparison is always **“current vs baseline”**, not “current vs previous scan”.  
  - The baseline is explicit and user-managed (via settings / UI actions).

- **Snapshot retention**  
  - Up to **50 snapshots per path** are kept; this is safe but can grow the DB over long-term heavy use.  
  - A future consecutive-scan model is expected to reduce this to a much smaller number.

- **Thresholds and tuning**  
  - 70% drill-down heuristic and ≥100MB “big file” threshold are hardcoded and not yet user-configurable.  

- **View-only**  
  - Prunr focuses on **diagnostics and insight**. It does not perform bulk deletion; instead, it reveals paths in Finder so users can decide what to delete.

### Intentional heavier paths

- **Headless stress commands**
  - `stress-scan` and `stress-report` are intentionally compiled into the app binary for synthetic dataset benchmarking and regression checks. They only run when invoked via CLI arguments and are not part of the normal menu bar flow.

- **Background maintenance**
  - Startup cleanup (`DatabaseCleanupService`) and SQLite maintenance are intentionally retained to keep long-lived installs healthy, even though they can do bursty work after launch or after scans.

- **File watching and automatic scans**
  - FSEvents watching plus throttled automatic scans remain an intentional tradeoff: Prunr spends some background work to keep disk growth state current without requiring manual refreshes.

### Planning going forward

The previous, detailed phase-based planning system (`.planning/phases/...`) is now considered **archival**.  

Going forward:

- High-level intent and future work should be captured in **`docs/OVERVIEW.md`** (vision + bird’s-eye roadmap).  
- Concrete status and constraints should be kept up to date in **this file** (`docs/STATE.md`).  
- If deeper design documents are needed in the future, they should be added under `docs/` as focused, self-contained topics (e.g., `architecture.md`, `ux-principles.md`), not as many fine-grained phases.
