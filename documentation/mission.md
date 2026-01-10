# Product Mission

## Pitch

**Prunr** is a macOS app that tracks what's eating your disk space *over time* and helps you reclaim it fast.

Unlike tools that show what's big (DaisyDisk) or blindly clean caches (CleanMyMac), Prunr answers the question: *"What grew recently?"* – whether it's 10,000 small npm packages, forgotten downloads, or runaway app caches.

For developers and power users on storage-constrained Macs, Prunr turns a 30-minute scavenger hunt into a 1-minute fix.

## Users

### Primary Customers
- **Developers** – juggling multiple package managers, build caches, Docker images on limited SSDs
- **Creative professionals** – photographers, video editors, designers with large project files and app caches
- **Power users** – anyone on a 256-512GB Mac who actively manages their storage

### User Personas

**Dev Dana** (Software Developer)
- Role: Full-stack developer with multiple active projects
- Pain Points: node_modules sprawl, Xcode caches, Docker images, forgotten cloned repos – hard to track what's accumulating
- Goals: Quickly identify what's bloating storage without manual `du` commands or guessing

**Creative Casey** (Video Editor / Designer)
- Role: Works with large media files, multiple Adobe apps
- Pain Points: Scratch disks fill up, render caches grow silently, old project files forgotten
- Goals: Know *what changed* when storage suddenly drops, not just what's big

## The Problem

**When storage suddenly drops, users have no good way to find out *what* consumed it.**

Current tools fall short:

| Tool | What it does | What's missing |
|------|--------------|----------------|
| DaisyDisk | Shows what's big | Doesn't track *change* over time |
| CleanMyMac | Clears known caches | Blind cleanup – doesn't show what grew |
| `du` commands | Manual folder analysis | Slow, tedious, no history to compare |
| Finder | File browsing | No size aggregation, no change tracking |

**The result:** Users either waste 30+ minutes hunting manually, or blindly delete things hoping it helps.

Prunr fills the gap: **accurate size tracking + time-based deltas + clear answers.**

## Key Features

### MVP (v1.0)

**Snapshot-based monitoring**
- Periodic snapshots of folder sizes (hourly default)
- 7 days of history stored locally
- Lightweight database (~50-200MB)

**Time-based delta view**
- "What grew in the last 24h / 7 days / custom range"
- Sortable list: folder, current size, change (+/-), when
- Drill-down from category to specific folders

**Smart defaults**
- Scans home folder + /opt/homebrew (or /usr/local)
- User can add/exclude paths in settings

**Low-space alerts**
- Threshold warning when free space drops below X GB
- Opens directly to "what grew" view

**Menu bar companion**
- Shows current free space
- Quick access to full app

**Full app window**
- Detailed list view of growth
- Manual scan trigger
- Settings for paths, thresholds, snapshot frequency

### Post-MVP (v2.0+)

- Smart cleanup suggestions (knows what's safe to delete)
- Category grouping ("All npm packages: +8GB across 12 projects")
- One-click actions (clear cache, remove node_modules, uninstall packages)
- Visual treemap showing growth
- Selective cleanup UI (like CleanMyMac's scan-and-select flow)
