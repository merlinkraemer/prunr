# Roadmap: Prunr

## Overview

Prunr is a filesystem growth journal that answers "What filled my disk?" Unlike DaisyDisk (shows current state) or CleanMyMac (blind cleanup), Prunr shows what grew over time and groups scattered files logically for actionable cleanup.

**How It Works:**
1. **SCAN** → Store directory sizes in SQLite (~500KB/snapshot)
2. **COMPARE** → Query growth: "What grew >100MB in last 7d?"
3. **GROUP** → Detect Homebrew/npm/apps → link scattered paths

Build in phases: project setup → scanner → delta engine → UI → smart grouping → cleanup actions.

## Domain Expertise

None

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

- [x] **Phase 1: Foundation** - Xcode project setup with GRDB dependency
- [x] **Phase 2: Scanner & Storage** - Disk scanner + SQLite snapshot storage
- [x] **Phase 3: Delta Engine** - Compare snapshots to show growth/shrinkage
- [x] **Phase 4: UI & Polish** - SwiftUI main window displaying growth data
- [ ] **Phase 5: Finder-Style Redesign** - Complete UX overhaul with sidebar, column view, and simplified comparison
- [ ] **Phase 6: Cleanup Actions** - Add delete/move functionality for freeing space (future)

## Phase Details

### Phase 1: Foundation
**Goal**: Working Xcode project with GRDB.swift integrated and basic app structure
**Depends on**: Nothing (first phase)
**Research**: Unlikely (standard project setup)
**Plans**: TBD

Plans:
- [x] 01-01: Xcode project + GRDB integration

### Phase 2: Scanner & Storage
**Goal**: Scan disk recursively, store directory sizes with timestamps in SQLite (~500KB/snapshot)
**Depends on**: Phase 1
**Research**: Unlikely (GRDB decided, FileManager APIs standard)
**Plans**: TBD

**Note:** Directory-level snapshots are sufficient for "what grew" questions. Individual file tracking deferred until needed for delete operations.

Plans:
- [x] 02-01: Disk scanner implementation
- [x] 02-02: SQLite schema + snapshot storage

### Phase 3: Delta Engine
**Goal**: Compare two snapshots and calculate what grew/shrank between them
**Depends on**: Phase 2
**Research**: Unlikely (internal calculation logic)
**Plans**: TBD

Plans:
- [x] 03-01: Delta calculation + sorting by change

### Phase 4: UI & Polish
**Goal**: SwiftUI window showing growth data sorted by change, ready to ship
**Depends on**: Phase 3
**Research**: Unlikely (SwiftUI patterns)
**Plans**: TBD

Plans:
- [x] 04-01: Main window UI
- [x] 04-02: App chrome + build for distribution

### Phase 5: DaisyDisk-Style Scan Results
**Goal**: Simple 2-screen UX: select path → scan results with category growth bars → drill down to file list
**Depends on**: Phase 4
**Research**: Complete (RESEARCH.md created)

**User Requirements:**
1. **Screen 1 - Sidebar**: Select path/drive to scan (like DaisyDisk)
2. **Screen 2 - Scan Results**:
   - Categories with growth bars (apps, packages, projects, homebrew, docker, npm, media)
   - Smart grouping by source (detects: homebrew? docker? npm? app? media files?)
   - Click category → drill down to file list
3. **File List Detail**:
   - Finder-like view of all files in category
   - Shows size, change amount, "NEW" badge for added files
   - Sorted by current size (largest first)
4. **Comparison**: Since last scan (auto-scan on path selection)

**Technical Approach:**
- NavigationSplitView for sidebar + main layout (already built)
- DaisyDisk-style category cards (replaces 3-column view)
- Pattern detection for smart grouping (Homebrew, docker, npm, media files)

Plans:
- [x] 05-01: TrackedPath and PathManager models
- [x] 05-02: Sidebar View with NavigationSplitView
- [x] 05-03: Three-Column View (categories → items → details) - superseded
- [x] 05-04: Simplified Comparison
- [ ] 05-05: DaisyDisk-Style Scan Results (replaces 3-column view)

### Phase 6: Cleanup Actions
**Goal**: Add delete/move functionality to free disk space directly from Prunr
**Depends on**: Phase 5
**Research**: Likely (file operations, undo/redo patterns, safety measures)
**Plans**: TBD

**Future Considerations:**
- Move to Trash vs permanent delete
- Batch operations
- Undo/redo support
- Safety confirmations
- Preview before delete

Plans:
- [ ] TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 1/1 | Complete | 2026-01-10 |
| 2. Scanner & Storage | 2/2 | Complete | 2026-01-10 |
| 3. Delta Engine | 1/1 | Complete | 2026-01-10 |
| 4. UI & Polish | 2/2 | Complete | 2026-01-10 |
| 5. DaisyDisk-Style Scan Results | 4/5 | In progress | — |
| 6. Cleanup Actions | 0/0 | Future | — |

## Key Differentiators

| Feature | DaisyDisk | CleanMyMac | Prunr |
|---------|-----------|------------|-------|
| Shows | Current sizes | Junk detection | Growth over time |
| Question answered | What's big? | What's safe to clean? | What filled my disk? |
| History | No | No | 30/90d history |
| Grouping | No | No | Scattered → logical |
| Time windows | N/A | N/A | 1d / 7d / 30d |