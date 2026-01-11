# Prunr

## What This Is

Prunr is a filesystem growth journal for macOS. It answers: *"What filled my disk?"*

Unlike DaisyDisk (shows what's big) or CleanMyMac (blind cleanup), Prunr shows what grew over time and groups scattered files logically for actionable cleanup.

**Problem:** Disk is full. User forgot what filled it.
**Solution:** Snapshot directory sizes over time → show what grew → group scattered files → delete.

## How It Works

1. **SCAN** → Store directory sizes in SQLite (~500KB/snapshot)
2. **COMPARE** → Query growth: "What grew >100MB in last 7d?"
3. **GROUP** → Detect Homebrew/npm/apps → link scattered paths

## Core Value

**When storage suddenly drops, users can immediately see what consumed it.**

The growth journal view is the core—everything else supports finding and removing the space hogs.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Disk scanner core — recursively scan folders and calculate sizes
- [ ] Snapshot storage — SQLite database to store folder sizes with timestamps
- [ ] Delta calculation — compare snapshots to show what grew/shrank
- [ ] Main app window — SwiftUI list view showing growth data sorted by change

### Out of Scope

- App Store distribution — direct distribution only for v1, avoids sandbox complexity
- Menu bar companion — nice-to-have but not core for first ship
- Low-space alerts — deferred until core value is validated
- Settings UI — hardcode sensible defaults for v1
- Onboarding flow — defer polish until core works

## Context

**Target users:**
- Developers juggling node_modules sprawl, Xcode caches, Docker images
- Creative professionals with large project files and app caches
- Anyone on a 256-512GB Mac who actively manages storage

**Existing landscape:**
| Tool | What it shows | Limitation |
|------|---------------|------------|
| DaisyDisk | Current disk usage | No history, no change tracking |
| CleanMyMac | "Junk" detection | Blind cleanup, no insight into what grew |
| `du` commands | Directory sizes | Slow, tedious, no history |

**Key insight:** Users waste 30+ minutes hunting manually or blindly delete hoping it helps. Prunr provides: time-based growth tracking + smart grouping for scattered files + clear answers.

## Constraints

- **Platform**: macOS 14+ (Sonoma) — no need to support older versions
- **Distribution**: Direct download (.dmg), notarized with Developer ID — no App Store for v1
- **Permission**: Full Disk Access required for scanning outside user home

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Directory-level snapshots | ~500KB/snapshot vs 50MB for file-level. Sufficient for "what grew" questions. | — Pending |
| Smart grouping is core | Homebrew, npm, apps scatter files. Grouping makes results actionable. | — Pending |
| Time windows: 1d/7d/30d | Covers "yesterday", "last week", "last month" use cases | — Pending |
| Growth bars in UI | Visual feedback makes big changes obvious at a glance | — Pending |
| Direct distribution | Avoids sandbox restrictions, simpler for v1 | — Pending |
| GRDB.swift for SQLite | Robust, type-safe, well-documented Swift wrapper | ✅ Complete |
| SwiftUI + MVVM | Native, declarative, clean separation | ✅ Complete |

---
*Last updated: 2026-01-11 — clarified growth journal vision*
