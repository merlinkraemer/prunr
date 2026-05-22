# Prunr Alpha Release Prep - 2026-05-22

## Candidate

- Version: `0.1.3`
- Build: `2`
- Release tag: `v0.1.3-alpha.1`
- Branch: `feat/beta-polish-7-10-11`
- Bundle id: `com.prunr.app`
- Minimum macOS: `14.0`
- Architectures: universal `arm64` + `x86_64`

## Artifacts

- Final app zip: `dist/releases/v0.1.3-alpha.1/Prunr-0.1.3-alpha.1-build2-macos.zip`
- dSYM zip: `dist/releases/v0.1.3-alpha.1/Prunr-0.1.3-alpha.1-build2-dSYM.zip`
- Checksums: `dist/releases/v0.1.3-alpha.1/SHA256SUMS.txt`
- Xcode export source: `Releases/Prunr.app`

SHA-256:

```text
c85c146a3e8489d55345e1342493daad4aaf326d0de06f237adfb1705d3206ca  Prunr-0.1.3-alpha.1-build2-macos.zip
c8c84017da8b3ca21578d69eb4b95baa7bb9f5df9b485bd25a12e27919931c01  Prunr-0.1.3-alpha.1-build2-dSYM.zip
```

## Verification

- `make test` passed: 64 tests, 0 failures.
- Final monitor sample after relaunch: process alive, CPU `0.2%`, RSS `66.9 MB`, category-vs-working-set delta `0.00 B`, status `OK`.
- Freshness probe passed against the live app in 20s:
  - working delta: `8,409,088 B`
  - category delta: `8,409,088 B`
- Clean Release build passed.
- Xcode-exported app is Developer ID signed:
  - authority: `Developer ID Application: Merlin Krämer (PM5QWB5426)`
  - code-sign flags: `runtime`
  - team id: `PM5QWB5426`
  - notarization ticket: stapled
  - entitlements: `com.apple.security.app-sandbox = false`
- `codesign --verify --deep --strict Releases/Prunr.app` passed.
- `spctl --assess --type execute --verbose=4 Releases/Prunr.app` returned `accepted` with `source=Notarized Developer ID`.
- `xcrun stapler validate Releases/Prunr.app` passed.
- The tracked root `Prunr.app` bundle was replaced with the notarized export for repo-local release parity.
- Final monitor sample before tagging: process alive, CPU `0.2%`, RSS `37.3 MB`, category-vs-working-set delta `0.00 B`, status `OK`.

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
