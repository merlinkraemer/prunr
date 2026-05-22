<p align="center">
  <img src="Prunr/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Prunr app icon">
</p>

# Prunr

Prunr is a macOS menu bar utility for understanding what is growing on disk. It scans tracked folders, groups storage by category, and keeps a live working set updated so recent growth can be reviewed without rerunning a full scan every time the panel opens.

## Alpha

Current alpha: `v0.1.3-alpha.1`

Download the notarized macOS build from the GitHub release:

- `Prunr-0.1.3-alpha.1-build2-macos.zip`
- `SHA256SUMS.txt`
- `Prunr-0.1.3-alpha.1-build2-dSYM.zip` for crash symbolication

The alpha build is Developer ID signed, notarized, and stapled. It targets macOS 14 or newer and ships as a universal `arm64` + `x86_64` app.

## Install

1. Download the release zip.
2. Unzip `Prunr.app`.
3. Move `Prunr.app` to `/Applications`.
4. Launch Prunr.
5. Grant the requested disk access permission.
6. Let the initial scan finish before judging category totals or growth state.

First scans can take a while on large home folders. After the baseline exists, Prunr should update recent growth incrementally and opening the panel should not visibly rebuild the full category list.

## Tester Notes

Useful bug reports include:

- macOS version
- whether Full Disk Access was granted
- approximate tracked-folder size
- what the panel showed before and after the issue
- screenshots for category reloads, missing categories, or confusing growth/stable states
- crash reports from `~/Library/Logs/DiagnosticReports`

Known harmless log noise during the alpha: repeated `CacheDelete/GetAPFSVolumeRole` messages.

## Development

```bash
make build
make test
npm run monitor -- --samples 20 --interval 5
```

Packaging notes and verification for the current alpha are in `docs/alpha-release-20260522.md`.
