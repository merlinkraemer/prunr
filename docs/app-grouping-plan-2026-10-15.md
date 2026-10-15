# Prunr: group app-owned places by app — plan (2026-10-15)

Read-only planning. Code: `feat/s26-drill-polish`. Inputs: `category-review.md`, live DB (read-only) for name shapes only.
Decisions taken as given: A2 (group by app), B1 (dotfolders → Developer, user folders → Media & Documents), C3 (no depth rules for user folders), and the hard constraint: **every rule derives from macOS/tool conventions, never from one user's folder layout.**

---

## 1. The model in plain words

- **Place** (unchanged): the thing with a stable key `kind|root`. A journal change belongs to exactly one place. Keys never carry names.
- **Owner** (new): who a place belongs to, computed at read time from the key. An owner is either an **app** (identified by a canonical bundle id, or by a name when no id is known) or a **category** (Developer, Media & Documents, Downloads, …). Every `~/Library` place that macOS files under an app (Application Support, Caches, Containers, Group Containers, Mobile Documents, WebKit, HTTPStorages, Logs, Saved Application State) gets an app owner. Places outside `~/Library` keep a category owner, except Docker/Colima (already Developer) and the media pack (Photos, Final Cut, Ableton projects → their category, as today).
- **Row** (main list): one owner per day: "Chrome +9 GB", "Developer +25 GB", "Downloads +11 GB". Today it is one *category* per day; the category stays the owner for non-app places, so those rows look as they do now.
- **Category** stays what the categories view and the stored per-file classification use. The list of categories stays at eight; "Caches & System" is renamed to **"Apps & System"** (same raw value, no data change), because that is what it already holds (everything under `~/Library` that is not Developer/Media). "Other" ends up near-empty: hidden home dotfolders → Developer, visible home folders → Media & Documents.

So: a category groups *sizes* (categories view), an owner groups *changes* (the 30-day list). An app owner is a finer grouping inside "Apps & System"; the two views still add up because owners never move bytes across categories.

---

## 2. Resolution rules, priority order

### 2a. Place resolution (the key; pure, path-only). Changes to today marked ★ (key change).
1. Trash, Downloads item (as today).
2. Developer pack, as today, plus:
   - ★ **DerivedData anywhere**: a component matching `<Name>-[a-z]{28}` followed by `Build|Index.noindex|Logs|info.plist|SourcePackages` → `xcode-build|…/<Name>-hash`. Generic: Xcode writes this shape wherever `-derivedDataPath` or the custom-location preference points. Replaces nothing user-specific in code, but makes "Build files · dev" read "Xcode build files · Pad".
   - ★ **Hidden home dotfolders** `~/.<tool>` → `tool|~/.<tool>` (one unit), except XDG dirs which go one deeper: `~/.cache/<x>` (today), `~/.local/share/<x>`, `~/.local/state/<x>`, `~/.config/<x>`. Name "<Tool> data" (`.rustup` → "Rustup data", `.codex` → "Codex data"), category Developer, icon: installed app with that name, else terminal symbol. Generic: a hidden top-level home folder is tool state by Unix convention; `~/.Trash`, `~/.docker`, `~/.colima`, package caches keep their own rules (they resolve first).
3. Media pack, as today. Fix: iCloud container app name derived from the canonical id (see 2b), not the last `~` segment.
4. Apps pack:
   - Steam game (as today) but category `.applications`, owner app Steam.
   - ★ **Vendor folders**: `~/Library/<Area>/<Vendor>/<App>` goes one level deeper when `<Vendor>` is in a small vendor set (`Google`, `Adobe`, `Microsoft`, `Mozilla`, `JetBrains`, `Epic`, `Unity`) → unit `…/Google/Chrome`, owner by name "Chrome". Generic: these vendors nest their apps; the set is of vendors, not of anyone's paths.
   - ★ **Flat areas collapse**: a path whose item sits directly in the area (`~/Library/<Area>/<file>`, i.e. the item is the file itself) → unit `library|~/Library/<Area>`, named by the area ("Preferences", "Logs"). `~/Library/Preferences` (incl. `ByHost`) is always one unit: 15k per-plist keys become one place, owner System. Same for `Saved Application State`, `Cookies`, `HTTPStorages` when flat. Generic: Apple's own layout.
   - `library` rule depth 3 otherwise (as today).
5. Place fallback (two folders below home) as today; category: Media & Documents for visible home folders, Developer for hidden ones (B1). Icon `.file(path: root)` so Finder's folder icon (custom icons included) shows.

### 2b. Owner resolution (read time; pure canonicalisation + an installed-app catalog)
Given a place key, in this order:
1. **Kind-owned**: `xcode-*` → Developer (see Q1), `docker|colima|package-cache|model-store|node-modules|python-env|build-output|git|tool` → Developer; `download` → Downloads; `trash` → Trash; `photos-library|fcp-*|icloud-drive` → Media & Documents; `ableton-*` → Audio Production; `mail-attachments|messages-attachments` → app (`com.apple.mail`, `com.apple.MobileSMS`); `cloud-storage` → app by provider name ("Google Drive", "Dropbox").
2. **Library item → canonical app id** (pure, `AppIdentity.canonical(_:)`):
   - strip `group.` prefix; strip a `[A-Z0-9]{10}.` team-id prefix; iCloud form `iCloud~a~b~C` / `TEAMID~a~b~C` → `a.b.C`;
   - strip file extensions from the identifier file list (`.plist`, `.binarycookies`, …);
   - strip trailing helper segments while the id keeps ≥3 segments: `helper`, `Helper`, `ShipIt`, `shared`, `group`, `ServiceExtension`, `WidgetExtension`, `*Extension`, `*Widget`, `*Agent`, `launcher`, `renderer`, `gpu`, `plugin`, `xpc`, `mac`, `desktop`, `app`;
   - result with ≥3 dotted segments → `app(id:)`; else `name(folder)` (e.g. "Claude", "Cursor", "Steam", "Office").
3. **Catalog lookup** (`AppCatalog`, built on the main actor from Launch Services, passed into the builder as a Sendable snapshot; tests inject a fake):
   - `app(id)` → `NSWorkspace.urlForApplication(withBundleIdentifier:)`; miss → try the id with its last segment dropped (helper bundles like `com.google.Chrome.helper`, `com.apple.Safari.SafeBrowsing`); miss → keep the id as owner key, display name from the pure fallback (last segment, `cacheApplicationDisplayName` map stays as offline table).
   - `name(x)` → exact case-insensitive match on `CFBundleDisplayName`/`CFBundleName`/`.app` stem across `/Applications`, `~/Applications`, `/System/Applications` (one `FileManager` pass, cached, refreshed on `NSWorkspace.didLaunchApplication`/install); then prefix match only when the remainder starts with a separator (`Prunr-backup-…` → Prunr, `Ableton` → "Ableton Live 12 Suite"; never `Go` → "GoLand"). Hit → owner key becomes the app's bundle id (so "Claude" folder and `com.anthropic.claudefordesktop.ShipIt` cache merge).
   - Owner key = canonical bundle id when resolved, else `name:<lowercased>`. Display name = `CFBundleDisplayName` ?? `CFBundleName` ?? fallback. Icon = `NSWorkspace.icon(forFile: appURL)`; uninstalled → category symbol of Apps & System (see Q3).
4. **Apple system daemons** (`com.apple.*` with no app URL: `mediaanalysisd`, `wallpaper.agent`, `CloudKit`): owner **System** (a category owner inside Apps & System) so the list says "System +1.4 GB" and the drill shows "Wallpaper · Aerials". Name-only rule: `com.apple.wallpaper` → "Aerial wallpapers".

### 2c. Title rules and truncation
- Owner row title = owner display name ("Chrome", "Steam", "Developer"). Never a Library area, never "<x> data" at owner level.
- Place titles inside an app: what it is, not where: "App data" (Application Support, Containers), "Cache", "Shared data" (Group Containers), "iCloud" (Mobile Documents), "Website data" (WebKit), "Cookies", "Logs"; Steam games "Celeste". For vendor-deep units the app folder name is the context: "App data · Chrome" only if the owner is the vendor itself (uninstalled).
- Place titles elsewhere stay ("Xcode build files · Pad", "Downloads · ubuntu.iso", "Archive · Documents").
- `UnitName` gains `context` (today's `detail` semantics) and loses Library-area details.
- Truncation, widest first, with `ViewThatFits(in: .horizontal)` over three `Text`s: (1) "name · context", (2) "name", (3) name with `.truncationMode(.middle)`. Date-like tails survive ("Prunr-backup-2…14-1439"). Rows keep one line and today's height. No char counting in code; the ~25-char budget is the design check, not the rule.
- Sanitiser: also strip 36-char dashed UUIDs (`-[0-9a-f]{8}-[0-9a-f]{4}-…`) the way 32-hex runs are stripped.

---

## 3. What changes on screen

### Main list (one owner per day; sort by |net|)
```
Wed 15 Oct
  [Chrome icon]   Chrome                          +9.2 GB  ›
  [Slack icon]    Slack                           +1.1 GB  ›
Tue 14 Oct
  [hammer]        Developer                      +25.6 GB  ›
  [folder]        Downloads · ubuntu-24.04.iso    +4.7 GB  ›
Mon 13 Oct
  [Steam icon]    Steam                          +12.3 GB  ›
  [gear]          System                          +1.4 GB  ›
```
Click rules: owner with one place that day → straight to place contents (today's `soloPlace`); several → places page.

### Drilldown level 2: an owner's places that day
```
‹ Chrome · Wed 15 Oct                            +9.2 GB
  App data                       14:20            +7.1 GB  ›
  Cache                          14:25            +2.1 GB  ›

‹ Steam · Mon 13 Oct                            +12.3 GB
  Hollow Knight                  21:02            +5.3 GB  ›
  Cuphead                        20:40            +5.8 GB  ›
  Celeste                        20:31            +1.2 GB  ›

‹ Developer · Tue 14 Oct                        +25.6 GB
  [Xcode] Xcode simulators       09:12           +13.9 GB  ›
  [Xcode] Xcode build files · Pad 09:40           +9.6 GB  ›
  [hammer] npm cache             a little each day +2.1 GB ›
```
Caption and chevron as today; the place row's icon is the app icon when the owner is a category (Developer rows showing Xcode) and the category symbol / nothing distinct when the owner is already that app.

### Drilldown level 3: place contents (unchanged)
```
‹ Chrome · App data                              21.4 GB
  Default                                         18.2 GB  ›
  Profile 1                                        2.9 GB  ›
  GrowthSDK…                                       0.3 GB
```
Header caption shows the Library area ("Application Support · Google/Chrome") so the location is not lost.

### Categories view (header click)
- "Caches & System" reads "Apps & System"; Steam games, Homebrew refile there (classification change → index rebuild in the same migration).
- Later slice: inside Apps & System, replace the subcategory groups (App Caches / Browser Caches / System Support) by owner groups (per app) using the existing `cache:<app>` group-key mechanism generalised to `owner:<id>`. Not needed for the list.

---

## 4. User-specific things in code/review and their generic replacement

| Where | User-specific | Generic replacement |
|---|---|---|
| `GrowthCategory.isDevProjectPath` + `UnitRules+Developer.projectRoots` (`dev, projects, code, repos, src, workspace, …`) | Folder-name convention; Merlin's `~/dev` happens to match | Keep as convention list (common, not personal) but unify into one list. Later: `build/dist/target` only count when a `.git` sibling was seen in the same scan (needs scan-time state; out of scope). |
| Review P0.4 "`~/dev/build` holds DerivedData" | Merlin's mac-queue layout | DerivedData-shape rule (2a.2): `<Name>-[a-z]{28}/Build` anywhere. |
| Review P0.5 `<App>-backup-<date>` rule | Merlin's backup script naming | No rule. Prefix-with-separator name match gives owner Prunr; middle truncation keeps the date. |
| Review P2 `~/.pi/<agent>`, `~/.codex/*`, `~/Documents/Codex`, `.claude/worktrees` | Merlin's tools and layout | Generic dotfolder rule (2a.2) covers `.pi`, `.codex`, `.claude`; `~/Documents/Codex` is a plain Documents folder (C3). Worktrees: no rule. |
| Review Choice C "PARA roots `~/local/<area>/<item>`" | Merlin's PARA | Dropped (C3). |
| `CacheApplicationIconResolver.aliases` `Google→Chrome`, `Adobe→Creative Cloud`, `Steam` | Guesses what a vendor folder means | Vendor-depth rule + catalog name match. `Steam` resolves by name. Delete the aliases. |
| `GrowthCategory.cacheApplicationDisplayName` 30-entry map | Hand list | Catalog display names; map stays only as the offline fallback for uninstalled apps. |
| `knownApplicationPaths` (browsers, CC, Steam) | Fine (generic paths) | Keep as last fallback. |
| `UnitIconSource.libraryItem` returning `.category` for plain names (Claude, Cursor, Clips) | Misses installed apps | Catalog name match (2b.3). |
| Review "Clips data" / "Python env · transcription" split | Merlin's app | Already generic: `venv` marker inside App Support stays Developer (a venv is a venv). Owner stays Developer; acceptable. |
| Journal per-file categories vs `categorize(root)` | n/a | Owner is computed from the key; category of the owner row = category of the place's root (as today). |

---

## 5. Stored keys: what changes and what it means
Key changes: vendor depth (`…/Google` → `…/Google/Chrome`), flat-area collapse (`…/Preferences/<x>.plist` → `…/Preferences`), dotfolders (`place|~/.codex/packages` → `tool|~/.codex`), XDG one-deeper (`place|~/.local/share` → `tool|~/.local/share/<x>`), DerivedData-anywhere (`build-output|~/dev/build` → `xcode-build|~/dev/build/pad-dd`), Steam category. `workingSetPlaceChild` is keyed by unit root, so it must be rebuilt.
No migration: app not live. Land as migration `v24_owner_units`: `DELETE FROM growthJournalBucket`, mark every tracked path's index `building` (same shape as v23), `HistoryStart.restart`. Fresh start, watch continues.

---

## 6. Edge cases
- **App uninstalled, data left**: owner key stays the bundle id; name from fallback table/last segment; icon = Apps & System symbol. See Q3.
- **Helper bundle ids** (`com.google.Chrome.helper`, `com.anthropic.claudefordesktop.ShipIt`, `com.apple.WebKit.Networking`): helper-segment strip, then "drop last segment and retry" in the catalog. Apple WebKit/Safari aliases stay in the fallback table.
- **Group Containers with team ids** (`UBF8T346G9.Office`, `6N38VWS5BX.ru.keepcoder.Telegram`): team prefix stripped → `ru.keepcoder.Telegram` resolves; `Office` → name match fails → owner `name:office` "Office data" under Apps & System. Later option: the catalog records each app's team id (`SecCodeCopySigningInformation`) and maps a team-only container to the vendor's apps.
- **iCloud containers** (`iCloud~net~whatsapp~WhatsApp`, `57T9237FN3~net~whatsapp~WhatsApp`): canonical `net.whatsapp.WhatsApp` → merges with the Containers and Group Containers places of the same app. If a different app occupies `/Applications/WhatsApp.app` (Merlin's `me.paolino.fastsapp`), name match still yields a WhatsApp icon; the owner key stays the real id.
- **Steam games**: owner Steam, place per game, category Applications. Steam uninstalled → name fallback "Steam".
- **Browser profiles**: no rule; place contents show `Default`, `Profile 1`, `<rand>.default-release`. Sanitiser already handles hex/UUID tails.
- **Xcode DerivedData / simulators / device support**: category owner Developer with the Xcode icon on the place rows (Q1).
- **Vendor folder with one child only** (`Adobe/Lightroom`): depth-4 unit, owner Lightroom; the vendor folder itself never shows as a place.
- **Two apps, same display name** (`Google Chrome` vs `Google Chrome Beta`): different bundle ids → different owners; names from the catalog differ.
- **`~/Library/Application Support/<file>`** lone files (`default.store`, `.ACCC_Lock`): one "Application Support" place, owner System.

---

## 7. Slice plan (small branches; every slice green via `mac-queue … test Prunr`)

| Slice | Branch | Content | Lands unattended? |
|---|---|---|---|
| O1 Owner identity (pure) | `feat/o1-owner-identity` | `AppIdentity.canonical`, `UnitOwner` enum (`app(id)`, `name`, `category`), `UnitName.owner`/`context`, all kind→owner mappings, iCloud name fix, UUID sanitiser. Tests: canonicalisation table (group/team/helper/iCloud forms), every existing rule yields the expected owner, forbidden-token guard, a test that no rule source file contains a home-specific token (`/local/`, `dev/build`, `merlin`, `PARA`). | yes (non-UI) |
| O2 App catalog | `feat/o2-app-catalog` | `AppCatalog` (main actor, cached, Sendable snapshot: id → name/URL; name → id; drop-last-segment retry; prefix-with-separator match). `UnitIconResolver` consumes it; delete `aliases`. Tests with an injected fake catalog; no dependence on installed apps. | yes |
| O3 Key changes | `feat/o3-owner-units` | Vendor depth, flat-area collapse, dotfolder/XDG `tool` kind, DerivedData-anywhere, Steam category, `com.apple.wallpaper` name; migration `v24_owner_units`. Tests: resolver table on a generic fixture home (`/Users/alex`), place-child rebuild, migration test. | yes (scan/storage logic → ask first per AGENTS.md; this is the one slice Merlin must green-light before landing) |
| O4 List grouped by owner | `feat/o4-owner-rows` | `ChangeGroup` keyed by owner (`ChangeFeedDay.groups`), `FeedPage`/titles, owner header on level 2, `ViewThatFits` truncation, Library area in the contents header caption. `EpisodeBuilder.build(slots:…, catalog:)`. Tests: grouping on a fixture feed with a fake catalog (Chrome 2 places → 1 row; uninstalled app; Developer unchanged), title fallback order. | no (UI; Merlin reviews) |
| O5 Categories view | `feat/o5-apps-and-system` | Rename "Caches & System" → "Apps & System"; owner groups inside it (`owner:<id>` group keys). | no (UI) |

Order: O1 → O2 → O3 → O4 → O5. O1/O2 are independent of O3; O4 needs all three. Worker runs as capped `claude -p` per slice; fixture data uses a made-up home, never Merlin's paths.

---

## 8. Open questions for Merlin (product level)

**Q1 Xcode: app or Developer?**
1. Developer owns builds, simulators, device support; Xcode icon on the place rows (rec: the user thinks "my builds", and one "Xcode +25 GB" row would hide that builds and simulators are different levers)
2. Xcode is an app owner like Chrome: "Xcode +25 GB" → simulators / build files / device support
3. Split: build files per project stay Developer, simulators and device support go to an "Xcode" app row

**Q2 The categories list**
1. Keep eight, rename "Caches & System" → "Apps & System", inside it one group per app (rec: no data change for the rename, matches the list)
2. Split into "Apps" and "System" (ninth category, classification change, Apple daemons separate)
3. Drop the categories view's subcategory drill and show owners everywhere (bigger UI change)

**Q3 An app's leftovers when the app is gone**
1. Show it under its name with the generic app symbol, nothing else (rec: honest, cheap, name still recognisable)
2. Add a caption "not installed" so the user sees it is deletable data
3. Fold all of them into one "Removed apps" owner row

**Q4 Row title when an app has one place that day**
1. Always the app name: "Chrome +9 GB", click goes straight to contents (rec: short, stable, same look whether 1 or 2 places)
2. The place title when solo: "Chrome cache +2 GB", app name only when several
3. App name plus context: "Chrome · cache"

**Q5 Audio and creative apps' Library data (Ableton cache, Adobe caches)**
1. App owner like any other app: "Ableton Live +1.3 GB" (rec: one rule, real icon)
2. Audio Production / Media category owner, so creative work and its caches sit together
3. App owner, but the category list files them under Audio Production (owner and category differ)

## 9. Decisions (Merlin, 2026-10-15)
- Q1–Q5: all recommended options (Xcode under Developer; eight categories, "Caches & System" → "Apps & System" with per-app groups; uninstalled apps by name + generic symbol; app rows always titled by app name; creative apps own their Library data).
- Mockups approved: canvas page r20 "Group by app" (A1–A6), https://claude.ai/artifact/UGa7vWtZTh1LmtKvLEVfMX
- Names short by construction (A6): rows say who or what, never where — app name · kind word ("Cache", "App data", "Website data", "Shared data", "iCloud") · stem in plain words (dates/ids/UUIDs/versions dropped: "Prunr-backup-20261014-1439" → "Prunr backup"; dated files grouped: "Meeting recordings"; "Xcode installer") · project name, not the tool ("Weatherly" for DerivedData, project name for node_modules). Location context goes to the drilldown header caption. Middle-truncate only names the user chose.
- Every rule generic across users; no user-specific paths.
- Build order: logic slices (O1–O3) first, then UI (O4–O5).
