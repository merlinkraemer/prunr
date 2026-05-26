# Todo: Release And Update Plan

## Execution

- [x] Confirm what is already implemented from `docs/release-and-update-plan.md`
- [x] Verify the Settings-close termination fix already exists in `Prunr/PrunrMenuBar.swift`
- [x] Add release pipeline artifacts:
  - `scripts/release.sh`
  - `scripts/ExportOptions.plist`
  - `Makefile` `release` target
- [x] Add Sparkle scaffolding:
  - package dependency in `project.yml`
  - updater wiring in AppKit entry point / menu bar manager
  - updater trigger in menu UI
  - appcast scaffold in `docs/appcast.xml`
- [x] Regenerate `Prunr.xcodeproj`
- [x] Verify with `make build`
- [x] Verify with `make test`
- [x] Review resulting behavior and note remaining manual release prerequisites

## Review

- `make build` succeeded after adding Sparkle 2.9.2 through XcodeGen-generated package wiring.
- `make test` succeeded with 64 tests passing.
- `bash -n scripts/release.sh` passed, and `make release` correctly rejects missing `VERSION` / `BUILD`.
- Full release notarization was not run here because the working tree is intentionally dirty and the script enforces a clean tree before touching version numbers or notarization.
- Sparkle is wired but intentionally dormant until `SUPublicEDKey` is populated; the updater button stays hidden and the context-menu action stays disabled until that key exists at runtime.
- `scripts/release.sh` keeps remote mutation opt-in via `CREATE_RELEASE_COMMIT=1`, `CREATE_RELEASE_TAG=1`, and `PUBLISH_GITHUB_RELEASE=1` to match the repo rule against automatic pushes.

## Public Repo Readiness

- [x] Add minimal alpha-period source-visible license
- [x] Confirm no tracked secrets or private keys in current tree
- [x] Confirm no tracked env files, signing exports, or local app bundles in current tree
- [x] Note public-history caveat for old bundled app artifacts
- [x] Flip repository visibility to public with `gh`

## Public Repo Review

- Added `LICENSE` with an all-rights-reserved alpha source-visibility notice and linked it from `README.md`.
- Current-tree scan found no tracked `.env`, signing keys, provisioning profiles, notarization passwords, or other credential material.
- Historical commits still contain `Prunr.app` bundle artifacts from prior alpha packaging work. No secrets were found in those revisions, but the artifacts themselves will be publicly visible unless history is rewritten later.
- `gh repo view` now reports `isPrivate: false` for `https://github.com/merlinkraemer/prunr`.

## Merge And Test

- [x] Confirm `main` is an ancestor of `feat/beta-polish-7-10-11`
- [x] Fast-forward `main` to the feature branch
- [x] Push `main`
- [x] Move GitHub Pages source from `feat/beta-polish-7-10-11:/docs` to `main:/docs`
- [x] Verify Pages build and public appcast URL from `main`
- [x] Run post-merge verification on the codebase

## Merge And Test Review

- `origin/main` had advanced independently with merge commit `1de48a8`, so the updater work was rebased onto that head before push instead of overwriting remote history.
- `main` now includes the missing updater commits at `3632c3c`, with `cb75401` carrying the actual release/update-path implementation on top of current remote main.
- `make test` passed after the rebase with `65` tests green.
- `bash -n scripts/release.sh` passed after the rebase.
- GitHub Pages now serves from `main:/docs`, and `https://merlinkraemer.github.io/prunr/appcast.xml` returns `HTTP 200`.
- Current limitation remains unchanged: the appcast is live, but in-app updating stays dormant until `SUPublicEDKey` is populated and the appcast includes a signed Sparkle enclosure for a published release.

## Sparkle Activation (2026-05-26)

- [x] s1: Fix Sparkle Info.plist embedding via xcodegen `info.properties`
- [x] s2: Generate ed25519 keys; public key in `project.yml`
- [x] s3: Updater UI active (panel ↓, context menu, Settings section)
- [x] s4: Settings “Check for Updates…” button
- [x] s5: Release artifacts for `0.1.5-alpha.0` and `0.1.5-alpha.1` (Developer ID signed; **not notarized** — `prunr-notary` profile missing on this machine)
- [x] s6: Pushed to `main`, tags + GitHub Releases published, appcast at `raw.githubusercontent.com/merlinkraemer/prunr/main/docs/appcast.xml`
- [ ] s7: Manual E2E — install `0.1.5-alpha.0`, run app, “Check for Updates…” → should offer `0.1.5-alpha.1`
- [ ] Fix GitHub Pages deploy (added `docs/.nojekyll`; build still errored — feed moved to raw URL)
- [ ] Configure `prunr-notary` and re-run `make release` for notarized builds before external testers
