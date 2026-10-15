# Prunr category / naming review (live data, 2026-10-15)

Read-only. Code: `feat/s26-drill-polish`. Data: `mbp` `prunr.db` (read-only), journal window 16 Sep – 15 Oct (Mac TZ = WITA).
Row model simulated per `EpisodeBuilder` (per-unit running count, row at ≥1 GB, Trash growth ignored). Names/icons/categories derived by hand from `UnitNamer` + rule packs + `GrowthCategory.categorize(rootPath)`.

**Headline numbers**
- 16,005 unit keys in 30 days, but only **37 units ever reach a row** (72 rows over 30 days).
- 14,922 of the keys are single `~/Library/Preferences/PadEntitlementTests-<UUID>.plist` files: one unit per test plist (key explosion, see P1).
- History source `files` = 23,215 buckets, **0 negative**. Only `watch` has shrinks (−0.03 GB). So the 30-day list currently can never show a "−" row from history.

Legend for flags: **N** bad name · **I** wrong/generic icon · **G** wrong grouping/category · **D** duplicate/overlap with another unit · **C** catch-all · **T** truncates (> ~26 chars).

---

## 1. Mapping table (every unit that produces a row)

Category = what the row is grouped under (namer's `categorize(root)`, not the journal's per-file category).

| Category (group) | Title as shown | Icon | Root (`~` = home) | What's inside (top children) | 30d growth | Flags |
|---|---|---|---|---|---|---|
| Developer | Build files · dev | hammer | `~/dev/build` | `pad-dd`, `bounce-dd`, `pad-l1-dd`, `bounce-l1-dd`, `pad-l1-logs` (mac-queue DerivedData + logs) | +26.9 GB (7 rows) | **N** "dev" is the dev root, not a project; this is Xcode DerivedData |
| Developer | Xcode simulators | Xcode | `~/Library/Developer/CoreSimulator` | `Devices` 41 GB | +24.4 GB (8 rows) | ok |
| Developer | Build files · pad | hammer | `~/dev/projects/pad/build` | build output | +16.9 GB (2) | ok |
| Developer | Xcode device support | Xcode | `~/Library/Developer/Xcode/iOS DeviceSupport` | iOS symbol caches | +13.9 GB (2) | ok |
| Developer | Build files · herdr | hammer | `~/dev/projects/herdr/target` | Rust target | +9.6 GB (3) | ok (could say "Rust build files") |
| Developer | uv cache | hammer | `~/.cache/uv` | Python packages | +5.0 GB (4) | ok |
| Developer | torch cache | hammer | `~/.cache/torch` | model weights | +1.3 GB (1) | **N** lowercase; really "PyTorch models" (→ model-store) |
| Developer | codex-runtimes cache | hammer | `~/.cache/codex-runtimes` | `codex-primary-runtime` | +1.4 GB (1) | **N** **D** Codex spread over 3 units/3 categories |
| Developer | Python env · transcription | hammer | `~/Library/Application Support/Clips/transcription/venv` | venv | +1.4 GB (1) | **D** split off "Clips data"; "transcription" isn't the app |
| Developer | node_modules · clips | hammer | `~/dev/projects/clips/node_modules` | deps | +1.2 GB (1) | ok |
| Developer | node_modules · backend | hammer | `~/dev/sav/skydive_events/dev/.claude/worktrees/agent-afff…/backend/node_modules` | deps of an agent worktree | +1.2 GB (1) | **N** "backend" of what? worktree not recognised |
| Caches & System | Google data · Application Support | gear | `~/Library/Application Support/Google` | `Chrome` 21.4 GB, `GoogleUpdater` 0.8 | +9.2 GB (4) | **N I G D T** it is Chrome; Chrome icon available |
| Caches & System | Google cache · Caches | gear | `~/Library/Caches/Google` | `Chrome` 6.3 GB | +4.7 GB (4) | **N I D** same app as above, shown as 2 rows on 7 Oct and 13 Oct |
| Caches & System | Shared data · Group Containers | gear | `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared` | `Message` 5.9 GB (WhatsApp media) | +5.1 GB (1) | **N I G D T** bundle-id last segment "shared" used as app name |
| Caches & System | Celeste · Steam / Cuphead · Steam / Hollow Knight · Steam | Steam | `~/Library/Application Support/Steam/steamapps/common/<Game>` | game installs | +12.3 GB (1 row each, 18 Sep → one "Caches & System" group) | **G** games filed as Caches & System |
| Caches & System | Clips data · Application Support | gear | `~/Library/Application Support/Clips` | `transcription` 3.0 GB | +3.1 GB (2) | **I T D** Clips.app installed (`dev.local.clips`) |
| Caches & System | Prunr-backup-20261014-1331 data · Application Support | gear | `~/Library/Application Support/Prunr-backup-20261014-1331` | `prunr.db` 2.7 GB | +2.7 GB (1) | **N I G T** two units, one per backup |
| Caches & System | Prunr-backup-20261014-1439 data · Application Support | gear | `…/Prunr-backup-20261014-1439` | `prunr.db` 2.8 GB | +2.8 GB (1) | **N I G T** (same) |
| Caches & System | Spotify cache · Caches | Spotify | `~/Library/Caches/com.spotify.client` | cache | +1.6 GB (1) | ok |
| Caches & System | Claude data · Application Support | gear | `~/Library/Application Support/Claude` | `vm_bundles` 9.3 GB, `Cache` 1.3 | +1.5 GB (1) | **I T** Claude.app installed |
| Caches & System | Cursor data · Application Support | gear | `~/Library/Application Support/Cursor` | `User` 4.5 GB | +1.4 GB (1) | **I T** Cursor.app installed (id is `com.todesktop.…`) |
| Caches & System | Wallpaper data · Application Support | gear | `~/Library/Application Support/com.apple.wallpaper` | `aerials` 4.0 GB | +1.4 GB (1) | **N I G T** it's Aerial wallpaper videos |
| Caches & System | Ableton cache · Caches | gear | `~/Library/Caches/Ableton` | cache | +1.3 GB (1) | **I G** Live icon exists; Audio category exists |
| Caches & System | Codexbar data · WebKit | CodexBar | `~/Library/WebKit/com.steipete.codexbar` | WebsiteDataStore | +1.1 GB (1) | **N** "CodexBar" casing; "WebKit" is jargon |
| Applications | Homebrew cache · Caches | indigo app square | `~/Library/Caches/Homebrew` | `downloads` 2.1 GB | +2.1 GB (1) | **I G** only Caches entry *not* in Caches & System; generic app icon |
| Media & Documents | WhatsApp in iCloud | photo (fallback) | `~/Library/Mobile Documents/57T9237FN3~net~whatsapp~WhatsApp` | `Accounts` 4.9 GB (chat backup) | +4.9 GB (1, today) | **I D** WhatsApp.app installed but id is `me.paolino.fastsapp`, so lookup fails |
| Media & Documents | Codex · Documents | photo | `~/Documents/Codex` | `2026-09-30` 1.9 GB | +1.9 GB (1) | **D** third Codex unit |
| Downloads | Downloads · _archives | folder | `~/Downloads/_archives` | zips/rars | +11.4 GB (3) | ok (underscore reads odd) |
| Downloads | Downloads · _installers | folder | `~/Downloads/_installers` | installers | +1.7 GB (1) | ok |
| Other | 2-Areas · local | grey ••• | `~/local/2-Areas` | `1-Mukke` 259 GB, `2-Merlin` 81 GB | +13.2 GB (1) | **N G C** whole PARA area = one bucket |
| Other | 3-Resources · local | grey ••• | `~/local/3-Resources` | `Installer` 238 GB, Audiobooks, Assets, Movies… | +3.0 GB (1, today) | **N G C** |
| Other | 1-Projects · local | grey ••• | `~/local/1-Projects` | merlinsroom, Gruuvkitchen, ALBUM_3… | +1.0 GB (1) | **N G C** |
| Other | agent-astra · .pi | grey ••• | `~/.pi/agent-astra` | `runs` 8.9 GB, `worktrees` 0.8 | +9.6 GB (3) | **N G** dev tool data |
| Other | packages · .codex | grey ••• | `~/.codex/packages` | `app-server-daemon` 3.7 GB | +3.7 GB (3) | **N G D** |
| Other | share · .local | grey ••• | `~/.local/share` | claude 1.9, opencode 0.9, uv 0.9 | +1.7 GB (1) | **N G C** XDG catch-all for many tools |
| Other | toolchains · .rustup | grey ••• | `~/.rustup/toolchains` | 2 Rust toolchains | +1.4 GB (1) | **N G** |
| Trash | (no row) | – | `~/.Trash` | – | +1.9 GB growth, ignored by design | ok |

Catch-alls that don't row yet but will: `place|~/dev/projects` (all loose source under dev/projects, "projects · dev"), `place|~/dev/sav`, `place|~/.claude/projects`, `place|~/local/#INBOX`, `place|~/Desktop/Spelunky-2-SteamRIP.com`.

### What the main list shows (simulated, newest first)
- **15 Oct**: WhatsApp in iCloud +4.9 · 3-Resources · local +3.0
- **14 Oct**: Developer +5.1 (Build files · dev, Xcode simulators) · Prunr-backup-20261014-1439 data · App… +2.8
- **13 Oct**: Caches & System +6.9 (Google data, Prunr-backup-…1331, Google cache) · Build files · dev +1.3
- **12 Oct**: Developer +9.0 · Google data · App… +2.2
- **11 Oct**: Developer +25.6 · Google cache · Caches +1.2
- **10 Oct**: Developer +13.3 · Homebrew cache · Caches +1.1 · packages · .codex +1.0
- 9 Oct: Developer +3.3 · share · .local +1.2 · Claude data · App… +1.1
- 18 Sep: Caches & System +12.3 = three Steam games; Developer +7.4; agent-astra · .pi +7.0

So "Caches & System" as a group mostly means *Chrome + Steam games + a Prunr backup*, none of which are caches or system.

---

## 2. Truncation

Panel 320 pt. Title space ≈ 320 − paddings 36 − icon 18 − spacing 30 − amount ~55 − chevron ~10 ≈ **170 pt ≈ 24–26 chars** at 13 pt semibold/medium. Rows use `.truncationMode(.tail)`.

Titles that overflow (chars):

| Title | Len | Shown as (approx.) |
|---|---|---|
| Prunr-backup-20261014-1331 data · Application Support | 53 | Prunr-backup-20261014… (date/time lost) |
| Wallpaper data · Application Support | 36 | Wallpaper data · Applic… |
| Google / Claude / Cursor / Clips data · Application Support | 33 | Google data · Application… |
| Shared data · Group Containers | 30 | Shared data · Group Cont… |
| Borderline (23): Homebrew cache · Caches, Downloads · _installers | 23 | fits, barely |

All overflow comes from the `· <Library area>` detail (`detail` from `appLibraryNameRule`/`libraryRule`) or from a raw folder name.

**Proposed rule (rec, option A below):**
1. Never show a `~/Library` area as the title context ("Application Support", "Caches", "Group Containers", "Containers", "WebKit"). The word in the title ("data" / "cache") already says it; move the area to the drill header caption.
2. If still too long, drop any `· context` suffix (keep the name).
3. Then middle-truncate the name (`.truncationMode(.middle)`), so trailing dates/numbers stay readable: "Prunr-backup-2…1439".
4. Rules should produce short names up front: humanise dates (`20261014-1439` → "14 Oct 14:39"), strip `-<UUID>` (36-char UUIDs with dashes slip past the 32-hex sanitiser).

Options:
1. **Drop Library area, then context, then middle-truncate** (rec): one title line, no height change.
2. Two-line row: name on line 1, context as the grey caption line (like the time caption): nothing lost, rows get taller.
3. Keep tail truncation, add `.help(fullTitle)` tooltip: smallest change, hidden info stays hidden.

---

## 3. Suggested edits (prioritised)

### P0: wrong names / wrong groups (small, rule-level)
1. **Group Containers name**: `appDisplayName("group.net.whatsapp.WhatsApp.shared")` → "Shared". Fix: strip `group.` and team prefix, then drop generic trailing segments (`shared`, `group`, `app`, `mac`, `desktop`, `helper`) before taking the name → "WhatsApp data". Same helper should feed `icloudContainerAppName`.
2. **Steam games out of Caches & System**: `steamGameRule` uses `categorize(root)` → cachesAndSystem. Set `.applications` (or a new Games category, see options) explicitly.
3. **`~/Library/Application Support/Google` and `~/Library/Caches/Google`** → name "Chrome data" / "Chrome cache", icon `com.google.Chrome` (name-only rule for library roots whose dominant child is `Chrome`; or a small vendor-folder map: Google→Chrome, Adobe→by child, Microsoft→by child).
4. **"Build files · dev"**: when the marker's parent is a project root (`dev`, `projects`, `code`…), don't use it as project name. `~/dev/build` holds `*-dd` DerivedData → name "Xcode build files · dev/build" with Xcode icon, or "Build folder" + detail "~/dev/build".
5. **Prunr backups**: `Prunr-backup-<date>` should not be "<x> data". Name-only rule for `<App>-backup-<yyyyMMdd>-<HHmm>` → "Prunr backup · 14 Oct 14:39", icon from the app (`Prunr`).
6. **Wallpaper**: `com.apple.wallpaper` → "Aerial wallpapers", Media & Documents (or System), System Settings icon.

### P1: icons
7. `UnitIconSource.libraryItem` returns `.category` for plain names (Claude, Cursor, Clips, Ableton, Spotify). `CacheApplicationIconResolver` already supports `fullPath(forApplication:)` by name but is never reached. Add an `.appNamed(String)` source (or pass the plain name through) → real icons for Claude, Cursor, Clips, Prunr, WhatsApp (installed with a non-standard id), Ableton ("Ableton Live 12 Suite" needs a prefix match).
8. Homebrew: replace generic indigo `app.fill` with `mug.fill` (the existing subcategory symbol) and move it to the same category as other caches.
9. Dotfolder tool units (.codex, .pi, .rustup, .local/share): hammer/terminal instead of grey •••.

### P1: key hygiene (data change, ask first)
10. `~/Library/Preferences/*` → one unit "Preferences" (14,922 keys today, all test plists). Same for other flat-file areas (`Logs`, `HTTPStorages`, `Saved Application State`). Key change → history splits for ≤30 days.

### P2: new rule-pack entries
| Path | Kind / name | Category | Icon |
|---|---|---|---|
| `~/.codex/*`, `~/.cache/codex-runtimes`, `~/Documents/Codex` | one unit or name-only "Codex · packages/runtime/files" | Developer | Codex app if installed |
| `~/.pi/<agent>` | "pi agent runs · agent-astra" | Developer | terminal |
| `~/.claude/projects` | "Claude Code sessions" | Developer | Claude |
| `~/.rustup/toolchains` | "Rust toolchains" | Developer | hammer |
| `~/.local/share/<tool>` | depth 3, "<tool> data" (claude, opencode, uv) | Developer | hammer |
| `~/.cache/torch` | model-store "PyTorch models" | Developer | – |
| `…/.claude/worktrees/<agent>/…` and `~/.pi/*/worktrees` | treat worktree as project: "node_modules · skydive_events (worktree)" | Developer | – |
| `~/dev/projects/<name>` (non-marker files) | "<name> project" instead of "projects · dev" | Developer | folder |
| `~/Library/Application Support/<App>/…/venv` | keep in the app unit or name "Clips · Python env" | Developer | app |

### Choice A: what to do with "Caches & System" (it's really ~/Library app data)
1. **Split into "App data" and "Caches"** (rec): App Support / Containers / Group Containers / WebKit → App data; `~/Library/Caches`, Homebrew, uv/npm/torch caches → Caches; Steam → Applications. Clear meaning, one enum case added.
2. **Group by app instead of category for app-owned places**: Chrome = data + cache, WhatsApp = container + iCloud, Clips = data + venv, Codex = 3 places. Best story ("Chrome ate 9 GB"), largest change.
3. **Keep the 8 categories, just fix filings**: rename "Caches & System" → "Apps & System", move Homebrew in, Steam to Applications. Smallest change, still a catch-all.

### Choice B: the "Other" bucket (user folders and dotfolders via place fallback)
1. **Dotfolders → Developer with rule names; user folders under `~/local`, `~/Music`, `~/Movies`, `~/Desktop` → Media & Documents** (rec): Other ends up near-empty.
2. Treat any non-system home folder as a "My files" category, title = inner folder only ("2-Areas"), Finder folder icon via `.file(path:)`.
3. Let Merlin pin/rename places (e.g. "~/local/2-Areas/1-Mukke" → "Music archive"): most precise, new UI + storage, out of scope for now.

### Choice C: depth of user-folder places (`~/local/2-Areas` = 340 GB in one unit)
1. **Go one level deeper for PARA-style roots** (`~/local/<area>/<item>`, also `~/Documents/<x>/<y>`) (rec): "1-Mukke · 2-Areas". Key change.
2. Keep the key, but name it by its biggest growing child at read time (needs per-child deltas, which the journal doesn't store).
3. Leave as is; rely on the drilldown (place contents) to show `1-Mukke`.

### Renames at a glance
| Now | Proposed |
|---|---|
| Shared data · Group Containers | WhatsApp data |
| WhatsApp in iCloud | WhatsApp backup · iCloud |
| Google data · Application Support | Chrome data |
| Google cache · Caches | Chrome cache |
| Prunr-backup-20261014-1439 data · App… | Prunr backup · 14 Oct 14:39 |
| Wallpaper data · Application Support | Aerial wallpapers |
| Claude / Cursor / Clips data · Application Support | Claude data / Cursor data / Clips data |
| Build files · dev | Xcode build files · dev/build |
| node_modules · backend | node_modules · skydive_events |
| packages · .codex | Codex packages |
| agent-astra · .pi | pi runs · agent-astra |
| share · .local | (split) claude / opencode / uv data |
| toolchains · .rustup | Rust toolchains |
| 2-Areas · local | 2-Areas (or 1-Mukke · 2-Areas with Choice C1) |
| torch cache | PyTorch models |
| Codexbar data · WebKit | CodexBar data |

### Also noticed
- `files` history never has negatives, so "−" rows only come from live watch. If shrinks matter in the 30-day view, the backfill can't provide them.
- Journal stores per-file categories (CoreSimulator rows carry 5 categories), but the row uses `categorize(root)`. The drill's place contents may disagree with the row's category.
- `GrowthCategory.isDevProjectPath` knows `dev/projects/code/repos/src`, the unit packs also know `workspace/developer/xcode/android`. The two lists drift.
