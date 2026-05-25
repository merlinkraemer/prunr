# Plan: Fix Settings-Close Crash + Build a Real Update Pipeline

## Context

Prunr shipped its first notarized alpha (`v0.1.3-alpha.1`, build 2) on 2026-05-22 to external testers. First bug back from testing: **opening Settings and then closing it terminates the entire app.**

Root cause: `AppDelegate` in `Prunr/PrunrMenuBar.swift` does not implement `applicationShouldTerminateAfterLastWindowClosed(_:)`. The app uses a pure-AppKit entry point with `.accessory` activation policy (no SwiftUI `App` scene, no `Settings` scene). The settings window is created on demand as a standalone `NSWindow`. When the user closes it, macOS' default behavior — "terminate after last window closed" — kicks in. The menu-bar panel does not count as a regular window.

The fix is one line. The bigger problem the user surfaced: shipping that one line currently means manually archiving in Xcode, notarizing, stapling, zipping, uploading to GitHub Releases, and telling testers to redownload. That friction repeats for every alpha bug.

**Intended outcome:**

1. Settings-close crash fixed.
2. `make release VERSION=x.y.z BUILD=N` produces a notarized, stapled, signed zip + dSYM + checksums and creates a GitHub Release in one command.
3. App self-updates via Sparkle from an appcast hosted on GitHub Pages — future fixes reach testers without manual redownload.

---

## Phase 1 — Settings-close fix (ship today)

### Critical file
- `Prunr/PrunrMenuBar.swift` (lines 20–51)

### Change
Add one method to `AppDelegate`:

```swift
func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
```

This is a menu-bar app — closing any user window must never terminate it. The `.accessory` activation policy alone does not change this default; the delegate method does.

### Why no other change is needed
- `MenuBarManager.openSettings()` (lines 661–697) already guards against duplicate windows via `NSApp.windows.first(where:)`.
- `isReleasedWhenClosed = true` is fine — the window can deallocate on close; we just need the app to stay alive.
- No strong window reference is required.

### Tasks
- [ ] Edit `Prunr/PrunrMenuBar.swift` — add the delegate method.
- [ ] `make build` — confirm compiles.
- [ ] Manual: launch app → open Settings → close window → app stays running → menu bar still responsive → reopen Settings → new window appears.
- [ ] Edge case: close via `Cmd+W` AND via the red close button — both must leave the app alive.

---

## Phase 2 — `make release` script (ship this week)

### Goal
One command produces a release-ready, notarized, signed artifact bundle and uploads it to GitHub Releases. Replaces the manual Xcode-archive workflow used for alpha.1.

### New files
- `scripts/release.sh` — the actual release pipeline (bash, `set -euo pipefail`).
- `scripts/ExportOptions.plist` — `developer-id` distribution, team `PM5QWB5426`, manual signing.
- `Makefile` — add `release` target that invokes the script with `$(VERSION)` and `$(BUILD)`.

### Script flow (`scripts/release.sh`)

1. **Preflight**
   - Require `VERSION` and `BUILD` args.
   - Refuse if working tree is dirty (`git diff --quiet`).
   - Smoke-test that keychain notary profile `prunr-notary` exists (`xcrun notarytool history --keychain-profile prunr-notary`).
   - Confirm `gh` CLI is authenticated.
2. **Version bump**
   - Patch `project.yml`: set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` via `sed` (project.yml lines 25–26).
   - Re-run `xcodegen` to regenerate the Xcode project.
3. **Clean + archive**
   - Wipe `Releases/` and `dist/releases/v$VERSION/`.
   - `xcodebuild archive -scheme Prunr -configuration Release -archivePath Releases/Prunr.xcarchive` with a clean DerivedData under `.build/release-derived/`.
4. **Export**
   - `xcodebuild -exportArchive` using `scripts/ExportOptions.plist`.
5. **Notarize + staple**
   - Zip `Releases/Prunr.app` → `Releases/Prunr-submit.zip`.
   - `xcrun notarytool submit ... --keychain-profile prunr-notary --wait`.
   - On success: `xcrun stapler staple Releases/Prunr.app`.
6. **Verify**
   - `codesign --verify --deep --strict --verbose=2 Releases/Prunr.app`.
   - `spctl --assess --type execute --verbose=4 Releases/Prunr.app` must say `source=Notarized Developer ID`.
   - `xcrun stapler validate Releases/Prunr.app`.
7. **Package**
   - `dist/releases/v$VERSION/Prunr-$VERSION-build$BUILD-macos.zip` (user-facing, created with `ditto -c -k --keepParent` to preserve signature).
   - `dist/releases/v$VERSION/Prunr-$VERSION-build$BUILD-dSYM.zip`.
   - `dist/releases/v$VERSION/SHA256SUMS.txt`.
8. **Sparkle signature (Phase-3 prep)** — emit `ed_signature` via Sparkle's `sign_update`; skipped with a warning if the tool isn't on PATH yet.
9. **Tag + GitHub Release**
   - `git commit -am "release: v$VERSION build $BUILD"` (only `project.yml` + later `docs/appcast.xml` changes).
   - `git tag v$VERSION`.
   - `gh release create v$VERSION dist/releases/v$VERSION/*` with auto-generated notes.
   - **Does not push** — user reviews and pushes manually.

### Makefile target

```makefile
release:
	@test -n "$(VERSION)" || (echo "usage: make release VERSION=x.y.z BUILD=N"; exit 1)
	@test -n "$(BUILD)"   || (echo "usage: make release VERSION=x.y.z BUILD=N"; exit 1)
	bash scripts/release.sh "$(VERSION)" "$(BUILD)"
```

### One-time user setup
- `xcrun notarytool store-credentials prunr-notary --apple-id <id> --team-id PM5QWB5426 --password <app-specific-password>`
- `brew install xcodegen gh` (release.sh checks).

### Tasks
- [ ] Write `scripts/release.sh`.
- [ ] Write `scripts/ExportOptions.plist`.
- [ ] Add `release` target to `Makefile`.
- [ ] Run notarytool one-time credential store.
- [ ] First dry run: `make release VERSION=0.1.4-alpha.0 BUILD=3` with only the Phase-1 fix.
- [ ] Verify the resulting zip launches cleanly from `~/Downloads` with no Gatekeeper warnings.
- [ ] Push the tag + release commit, confirm the GitHub Release renders correctly.

---

## Phase 3 — Sparkle auto-updates (follow-up)

### Goal
Testers stop manually redownloading. App polls an appcast, prompts to install, applies the update in place.

### Dependency
Add Sparkle 2.x via SPM. The project already uses SPM (GRDB is a local SPM package). Add a remote package reference in `project.yml`:

```yaml
packages:
  GRDB:
    path: LocalPackages/GRDB.swift
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: "2.6.0"
```

Then add `Sparkle` to the `Prunr` target's `dependencies` and re-run `xcodegen`.

### Code changes
- `Prunr/PrunrMenuBar.swift` — add `SPUStandardUpdaterController` as an `AppDelegate` property. Instantiate in `applicationDidFinishLaunching` with `startingUpdater: true`. This is the right pattern for non-SwiftUI apps.
- `Prunr/Views/MenuBarView.swift` — add a "Check for Updates…" item that calls `updaterController.checkForUpdates(nil)`. Mirror the existing settings entry around line 320.
- `project.yml` Info.plist keys (via `INFOPLIST_KEY_*`):
  - `SUFeedURL = https://merlinkraemer.github.io/prunr/appcast.xml`
  - `SUEnableInstallerLauncherService = YES`
  - `SUPublicEDKey = <ed25519 pubkey>` (generated by Sparkle's `generate_keys`; private key stays in login keychain).

### Appcast + GitHub Pages
- Enable GitHub Pages on `main` branch, `/docs` folder.
- New file: `docs/appcast.xml` — initial empty `<rss>` shell, no items.
- Release script (Phase 2) extended to:
  - Run Sparkle's `generate_appcast` on `dist/releases/` (or per-asset `sign_update` + XML append) to update `docs/appcast.xml` with version URL, length, `ed_signature`, `sparkle:version`, `sparkle:shortVersionString`.
  - Stage `docs/appcast.xml` into the release commit. Pushing publishes the new feed via Pages.

### Tasks
- [ ] Generate Sparkle ed25519 keypair; store private in keychain.
- [ ] Add Sparkle SPM dependency to `project.yml`, re-run `xcodegen`.
- [ ] Wire `SPUStandardUpdaterController` into `AppDelegate`.
- [ ] Add "Check for Updates…" menu item to `MenuBarView`.
- [ ] Add `SUFeedURL`, `SUEnableInstallerLauncherService`, `SUPublicEDKey` Info.plist keys.
- [ ] Enable GitHub Pages on `main` `/docs`.
- [ ] Commit empty `docs/appcast.xml` shell.
- [ ] Extend `scripts/release.sh` to update + sign the appcast.
- [ ] Ship `0.1.5-alpha.0` with Sparkle enabled — last manual download.
- [ ] Ship `0.1.5-alpha.1` (trivial change), confirm the still-running `alpha.0` finds and applies the update via "Check for Updates…".

---

## Risks and notes

- **Notarization can fail on subtle entitlement/runtime issues.** alpha.1 already passed notarization, so config is known-good — but any new dependency (Sparkle especially, which ships a helper tool) can re-introduce failures. The release script logs `notarytool log` on failure so we can diagnose without re-running.
- **Sparkle on `.accessory` apps:** Sparkle 2 handles installer-relaunch correctly via its installer launcher service — no extra code, just the `SUEnableInstallerLauncherService` plist key. Verify once on first release with Sparkle.
- **Don't bypass hooks or auto-push.** Release script intentionally stops short of `git push`. User always reviews local commit + tag before pushing.
- **Version scheme.** Today's fix is a single bug: `0.1.4-alpha.0` build `3`. Sparkle introduction warrants `0.1.5-alpha.0`. Release script trusts the args; it doesn't enforce semver.

---

## Order of operations

1. Phase 1 fix → `make release VERSION=0.1.4-alpha.0 BUILD=3` (Phase 2 script lands at the same time; first run validates it).
2. Tell testers to download the new zip from the GitHub Release (last manual download).
3. Phase 3: add Sparkle, ship `0.1.5-alpha.0` the same way — that's the last time testers manually download. Every release after flows through Sparkle.
