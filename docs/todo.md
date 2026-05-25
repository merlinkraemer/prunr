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
