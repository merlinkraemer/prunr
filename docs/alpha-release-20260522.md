# Prunr Alpha Release Prep - 2026-05-22

## Candidate

- Version: `0.1.3`
- Build: `2`
- Commit: `cac7668`
- Branch: `feat/beta-polish-7-10-11`
- Bundle id: `com.prunr.app`
- Minimum macOS: `14.0`
- Architectures: universal `arm64` + `x86_64`

## Artifacts

- App zip: `dist/alpha-20260522/Prunr-0.1.3-alpha.1-build2-cac7668-macos-unnotarized.zip`
- dSYM zip: `dist/alpha-20260522/Prunr-0.1.3-alpha.1-build2-cac7668-dSYM.zip`
- Checksums: `dist/alpha-20260522/SHA256SUMS.txt`

SHA-256:

```text
329452de044243ab562ddaeca1bf133fbb8f52d6c4ea5cd9b354e3e677f3071d  Prunr-0.1.3-alpha.1-build2-cac7668-macos-unnotarized.zip
9e900114597d733723a18520758bae220f299974636cca854027674631d46c32  Prunr-0.1.3-alpha.1-build2-cac7668-dSYM.zip
```

## Verification

- `make test` passed: 64 tests, 0 failures.
- Final monitor sample after relaunch: process alive, CPU `0.2%`, RSS `66.9 MB`, category-vs-working-set delta `0.00 B`, status `OK`.
- Freshness probe passed against the live app in 20s:
  - working delta: `8,409,088 B`
  - category delta: `8,409,088 B`
- Clean Release build passed.
- Packaged app was re-signed locally with hardened runtime enabled:
  - code-sign flags: `adhoc,runtime`
  - entitlements: `com.apple.security.app-sandbox = false`
  - no `get-task-allow` entitlement in the packaged app.
- `codesign --verify --deep --strict` passed for the staged packaged app.

## Shipping Blocker

The current artifact is not Gatekeeper-clean for external testers:

- Machine has only `Apple Development: Merlin Krämer (R9PT23U593)`.
- No `Developer ID Application` identity is installed.
- `spctl --assess --type execute` rejects the app.
- Notarization was not attempted because a Developer ID signed artifact is not available.

Before sending to non-technical alpha testers, produce a Developer ID signed and notarized package.

## Manual Alpha Smoke

- Install the notarized package on a clean macOS user account or clean test machine.
- Confirm first launch opens from Finder without Gatekeeper override.
- Grant required disk access permission.
- Run an init scan and confirm it completes.
- Open the menu bar panel several times:
  - categories should appear immediately after initial load
  - no full visible category reload on each open
  - no disappearing categories
  - growth/stable labels should make sense
- Create or modify a large test file under the tracked root and confirm the UI/monitor picks up growth.
- Quit/relaunch and confirm state reloads without a full panel refresh.

## Tester Notes

- First scan can take a long time on large home folders.
- Prunr currently stores scan state under `~/Library/Application Support/Prunr`.
- Known harmless log noise: repeated `CacheDelete/GetAPFSVolumeRole` messages.
- Useful bug report details:
  - macOS version
  - whether Full Disk Access was granted
  - approximate home-folder size
  - screenshot of the panel if categories disappear or reload visibly
  - any crash report from `~/Library/Logs/DiagnosticReports`
