# Roadmap: Prunr

## Overview

Build a macOS disk space tracker that shows what grew recently. Start with project setup, add scanning and storage, implement delta calculations, then wrap it in a SwiftUI interface. Four phases to deliver the core "what grew in the last 24h" value.

## Domain Expertise

None

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

- [ ] **Phase 1: Foundation** - Xcode project setup with GRDB dependency
- [ ] **Phase 2: Scanner & Storage** - Disk scanner + SQLite snapshot storage
- [ ] **Phase 3: Delta Engine** - Compare snapshots to show growth/shrinkage
- [ ] **Phase 4: UI & Polish** - SwiftUI main window displaying growth data

## Phase Details

### Phase 1: Foundation
**Goal**: Working Xcode project with GRDB.swift integrated and basic app structure
**Depends on**: Nothing (first phase)
**Research**: Unlikely (standard project setup)
**Plans**: TBD

Plans:
- [ ] 01-01: Xcode project + GRDB integration

### Phase 2: Scanner & Storage
**Goal**: Scan disk recursively, store folder sizes with timestamps in SQLite
**Depends on**: Phase 1
**Research**: Unlikely (GRDB decided, FileManager APIs standard)
**Plans**: TBD

Plans:
- [ ] 02-01: Disk scanner implementation
- [ ] 02-02: SQLite schema + snapshot storage

### Phase 3: Delta Engine
**Goal**: Compare two snapshots and calculate what grew/shrank between them
**Depends on**: Phase 2
**Research**: Unlikely (internal calculation logic)
**Plans**: TBD

Plans:
- [ ] 03-01: Delta calculation + sorting by change

### Phase 4: UI & Polish
**Goal**: SwiftUI window showing growth data sorted by change, ready to ship
**Depends on**: Phase 3
**Research**: Unlikely (SwiftUI patterns)
**Plans**: TBD

Plans:
- [ ] 04-01: Main window UI
- [ ] 04-02: App chrome + build for distribution

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 0/1 | Not started | - |
| 2. Scanner & Storage | 0/2 | Not started | - |
| 3. Delta Engine | 0/1 | Not started | - |
| 4. UI & Polish | 0/2 | Not started | - |
