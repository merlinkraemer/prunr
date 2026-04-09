## Prunr — Overview

Prunr is a macOS menu bar app that answers **“What filled my disk?”** by tracking **growth over time** rather than just showing what is big right now.

### What it does

- **Tracks growth**: Takes snapshots of directory sizes and computes how much each path has grown since a baseline.
- **Explains culprits**: Groups scattered growth into meaningful **categories** (e.g. Homebrew, node_modules, Downloads) so users see *why* storage dropped.
- **Lives in the menu bar**: No Dock icon; a compact popover shows a drive bar, category growth list, and drill-down views.
- **Respects the filesystem**: Uses FSEvents to know when to rescan, and SQLite (GRDB) to store snapshots efficiently.

### Target users

- Developers with large and fast-changing codebases (`node_modules`, Xcode caches, Docker images).
- Creators with large project files and app caches.
- Anyone on a 256–512GB Mac who actively manages disk space and wants **insight, not blind cleanup**.

### How it works (today)

1. **Baseline**  
   - User creates a **single baseline snapshot** for each monitored path.  
   - Baseline snapshot IDs are stored in SQLite and referenced via `UserDefaults`.

2. **Watch**  
   - An FSEvents-based watcher monitors enabled paths with stream coalescing plus manager-side recent-change debouncing.
   - Current timing is roughly **1.0s FSEvents coalescing** with **1.5s normal** and **0.75s pressure** refresh debounce windows.
   - File system activity is used to decide **when** to run a scan so scans feel timely but not spammy.

3. **Scan**  
   - When needed (or on manual request), Prunr performs a **full-path scan** of each monitored folder.  
   - Scanning is done via an actor (`ScanService`) that streams filesystem entries and writes them to SQLite in **batched inserts**.

4. **Compare**  
   - Deltas between **baseline** and **current snapshot** are computed in SQLite using a UNION-of-LEFT-JOINs pattern.  
   - Only paths that actually changed size are kept; results are sorted by **absolute change**, largest first.

5. **Group & show**  
   - A `CategoryDetectionService` groups growth by **category** (10 defined categories such as Homebrew, node, Downloads, Trash, etc.).  
   - The main popover shows:
     - A **drive bar** (“X GB free of Y GB”).  
     - A **category growth list** with per-category totals, severity coloring, and nested big files.  
     - Drill-down views that show the most significant contributing paths and files.

### Bird’s-eye roadmap (conceptual)

This is a high-level, non-phased view of where Prunr is and where it is going.

- **Now (implemented)**  
  - Menu bar–only app with a polished popover UI.  
  - Single explicit **baseline** model per monitored path.  
  - FSEvents-triggered **full-path scans** with progress, cancellation, and batched DB writes.  
  - Category-based growth view with drill-down, plus auto cleanup of old snapshots.  
  - Modern 3-tab settings window (General / Folder Limits / About).

- **Next (short-term direction)**  
  - **Animation performance and smoothness** for push-style drill-down transitions and list updates.  
  - Minor UX refinements based on hands-on use (microcopy, spacing, visual balance).

- **Later (conceptual future)**  
  - **Consecutive-scan comparison model** (“since I last checked”) that replaces explicit baselines with automatic rolling comparisons.  
  - Simpler snapshot retention (e.g. keep last two snapshots per path) and a more compact database.  
  - Potential export/sharing features or integrations once the core growth journal is battle-tested.

### Key design principles

- **Explain, don’t just clean**: Prunr focuses on clear explanations of what changed, not one-click cleaning.
- **Be a good menu bar citizen**: Small, fast, unobtrusive, visually aligned with native macOS patterns.
- **Favor clarity over knobs**: Hardcoded thresholds (like the 70% drill-down heuristic and ≥100MB “big files”) keep the initial UX simple.
