# Sparkle Update Activation

**Date:** 2026-05-26
**Status:** in-progress

## Problem

The update pipeline scaffolding is on `main` (Sparkle SPM, release script, GitHub Pages appcast shell), but auto-update is not live:

- Installed builds may predate Sparkle or lack working plist keys — `SUFeedURL` / `SUPublicEDKey` are in `project.yml` but do not appear in the built `Info.plist`, so `configureUpdaterIfPossible()` always calls `disableUpdater()`.
- `SUPublicEDKey` is empty — even if plist keys worked, update UI stays hidden/disabled by design.
- `docs/appcast.xml` is an empty RSS shell — no signed `<item>` entries.
- Only `v0.1.3-alpha.1` exists on GitHub Releases; no Sparkle-enabled baseline has shipped.
- Settings has no “Check for Updates” action (panel icon + context menu only).

## Solution

Activate Sparkle end-to-end in thin vertical slices: fix plist embedding → generate keys → verify local updater UI → ship first signed release → publish → prove incremental update. Optional Settings entry in parallel once keys work.

Version scheme for this work: **`0.1.5-alpha.0` build 1** = first Sparkle-enabled manual download; **`0.1.5-alpha.1` build 1** = trivial bump to prove in-app update.

## Out of scope

- Rewriting `scripts/release.sh` flow (already done).
- Automatic `git push` from release script (stays opt-in).
- Sparkle delta updates / custom update UI skinning.
- Git history rewrite for old bundled `.app` artifacts in public repo.
- Beta channel / multiple appcast feeds.

## Slices

### s1: Fix Sparkle Info.plist embedding

- **outcome:** Debug and Release builds include `SUFeedURL`, `SUEnableInstallerLauncherService`, and `SUPublicEDKey` in the app bundle’s `Info.plist`.
- **depends_on:** none
- **likely_files:** `project.yml`, `Prunr/Info.plist` (new, if needed), `Prunr.xcodeproj/project.pbxproj`
- **acceptance:**
  - [ ] `npm run reset` then `plutil -p /Applications/Prunr.app/Contents/Info.plist` shows `SUFeedURL` = `https://merlinkraemer.github.io/prunr/appcast.xml`
  - [ ] `SUEnableInstallerLauncherService` = true
  - [ ] `SUPublicEDKey` key is present (value may still be empty until s2)
  - [ ] `make test` passes

**Implementation hint:** `GENERATE_INFOPLIST_FILE` + `INFOPLIST_KEY_SU*` appears to drop Sparkle keys in current Xcode. Prefer an explicit `info:` path / `INFOPLIST_FILE` merge in `project.yml`, or a dedicated `Prunr/Info.plist` with `GENERATE_INFOPLIST_FILE = YES` and `INFOPLIST_KEY_*` for the rest.

### s2: Generate Sparkle signing keys

- **outcome:** ed25519 keypair exists; public key is wired into the project; private key lives only in login keychain.
- **depends_on:** none
- **likely_files:** `project.yml`, `Prunr.xcodeproj/project.pbxproj`, `docs/sparkle-update-activation-2026-05-26.md` (notes section only)
- **acceptance:**
  - [ ] Sparkle `bin/generate_keys` run once; public key copied into `INFOPLIST_KEY_SUPublicEDKey`
  - [ ] Private key **not** committed (verify `git diff` / `git status`)
  - [ ] Document `SPARKLE_BIN_DIR` path in Notes below (machine-local)
  - [ ] `security find-generic-password -a "Sparkle"` or Sparkle docs confirm private key in keychain

**One-time commands:**

```bash
# Download Sparkle release binaries or build from source, then:
/path/to/Sparkle/bin/generate_keys
# Paste printed public key into project.yml → xcodegen generate
```

### s3: Verify updater UI locally

- **outcome:** Fresh install shows active update affordances; manual check opens Sparkle (up-to-date or error), not silent no-op.
- **depends_on:** s1, s2
- **likely_files:** (verify only — may touch none)
- **acceptance:**
  - [ ] `npm run reset` installs build with non-empty `SUPublicEDKey`
  - [ ] Panel header shows ↓ (update) button beside settings gear
  - [ ] Right-click menu bar icon → “Check for Updates…” is **enabled**
  - [ ] Triggering check opens Sparkle dialog (likely “up to date” against empty appcast — that is OK)
  - [ ] App does not crash; menu bar stays responsive after dialog dismiss

### s4: Add Settings “Check for Updates”

- **outcome:** General settings tab offers the same update action as the panel/menu.
- **depends_on:** s3
- **likely_files:** `Prunr/Views/SettingsView.swift`
- **acceptance:**
  - [ ] Button visible in General tab when `MenuBarManager.shared?.isUpdaterAvailable == true`
  - [ ] Hidden or disabled when updater unavailable (matches panel behavior)
  - [ ] Click invokes `MenuBarManager.shared?.checkForUpdates()` and opens Sparkle dialog
  - [ ] Version footer still shows `Version x (y)`

### s5: Ship first Sparkle-enabled release (`0.1.5-alpha.0`)

- **outcome:** Notarized release artifacts exist locally; `docs/appcast.xml` contains a signed enclosure for the zip.
- **depends_on:** s1, s2
- **likely_files:** `project.yml`, `docs/appcast.xml`, `dist/releases/v0.1.5-alpha.0/`
- **acceptance:**
  - [ ] Clean working tree on `main`
  - [ ] `SPARKLE_BIN_DIR=/path/to/Sparkle/bin CREATE_RELEASE_COMMIT=1 CREATE_RELEASE_TAG=1 make release VERSION=0.1.5-alpha.0 BUILD=1` succeeds
  - [ ] `dist/releases/v0.1.5-alpha.0/Prunr-0.1.5-alpha.0-build1-macos.zip` exists and passes `spctl --assess`
  - [ ] `docs/appcast.xml` has `<item>` with `sparkle:version`, enclosure URL pointing at GitHub Releases path, and `sparkle:edSignature`
  - [ ] Release commit + tag `v0.1.5-alpha.0` created locally (not pushed yet)

### s6: Publish release and hosted appcast

- **outcome:** GitHub Release and GitHub Pages appcast are public and consistent.
- **depends_on:** s5
- **likely_files:** (remote only — `git push`, `gh release edit`)
- **acceptance:**
  - [ ] `git push origin main && git push origin v0.1.5-alpha.0`
  - [ ] Draft release published: `PUBLISH_GITHUB_RELEASE=1` on s5 **or** `gh release create/edit` with zip + dSYM + checksums
  - [ ] `curl -s https://merlinkraemer.github.io/prunr/appcast.xml` returns appcast with signed item (allow ~1–2 min Pages propagation)
  - [ ] Enclosure URL in appcast resolves (404 check after release assets upload)
  - [ ] Install zip from Release to `/Applications` (or `~/Applications`) — Gatekeeper clean launch

**Suggested publish command (if not done in s5):**

```bash
PUBLISH_GITHUB_RELEASE=1 SPARKLE_BIN_DIR=... CREATE_RELEASE_COMMIT=1 CREATE_RELEASE_TAG=1 \
  make release VERSION=0.1.5-alpha.0 BUILD=1
# then push; gh release edit v0.1.5-alpha.0 --draft=false
```

### s7: Prove incremental auto-update (`0.1.5-alpha.0` → `0.1.5-alpha.1`)

- **outcome:** A running `alpha.0` install updates to `alpha.1` via Sparkle without manual redownload.
- **depends_on:** s6
- **likely_files:** trivial change anywhere (version bump only), `docs/appcast.xml`
- **acceptance:**
  - [ ] `0.1.5-alpha.0` left running (do not quit after s6 install — or reinstall alpha.0 explicitly)
  - [ ] Ship `0.1.5-alpha.1` through same release pipeline; push + publish
  - [ ] On running `alpha.0`: “Check for Updates…” (or Sparkle background check) offers `alpha.1`
  - [ ] Update installs, app relaunches, `About`/Settings shows `0.1.5-alpha.1`
  - [ ] Record result in `docs/todo.md` Merge/Review section

## Dependency graph

```
s1 ──┬──→ s3 ──→ s4
     │      ↑
s2 ──┴──→ s5 ──→ s6 ──→ s7
```

## Parallel batches

- **Batch 1** (independent): **s1**, **s2**
- **Batch 2** (after s1 + s2): **s3**, **s5** (s3 and s5 can run in parallel once keys + plist work)
- **Batch 3** (after s3): **s4**
- **Batch 4** (after s5): **s6**
- **Batch 5** (after s6): **s7**

## Notes

### Prerequisites (already assumed)

- `xcrun notarytool` profile `prunr-notary` configured
- `gh` authenticated for `merlinkraemer/prunr`
- GitHub Pages source: `main` / `docs` (verified 2026-05-26)
- Apple Developer ID signing + notarization working (alpha.1 precedent)

### SPARKLE_BIN_DIR

Set per machine after downloading [Sparkle releases](https://github.com/sparkle-project/Sparkle/releases). Example:

```bash
export SPARKLE_BIN_DIR="$HOME/src/Sparkle/bin"
```

Release script uses `generate_appcast` when available; otherwise warns and skips appcast update.

### Public key in git

Committing `SUPublicEDKey` in `project.yml` is correct — it is the verify-side key. Never commit private key material or `generate_keys` output files.

### Local-only testing shortcut (before s6)

Serve a test appcast on localhost and temporarily override feed URL in a Debug scheme if needed. Production path is s6+ hosted HTTPS feed.

### Existing docs

- `docs/release-and-update-plan.md` — original phased plan (Phases 1–2 largely done; Phase 3 tasks map to this doc)
- `docs/todo.md` — update Review section as slices complete
