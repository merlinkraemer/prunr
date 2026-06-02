---
name: ship-alpha
description: Ship a new signed, notarized alpha release of Prunr to testers. Use when the user says "push this as a new alpha", "ship a new alpha", "release alpha", "cut an alpha build", or similar. Triggers the GitHub Actions Release workflow which does everything on GitHub's runners.
---

# Ship a new Prunr alpha to testers

Releases run **entirely on GitHub's runners** via the `Release` workflow
(`.github/workflows/release.yml`). This skill just computes the next version,
kicks off that workflow, and watches it. No local build, signing, or notarizing.

## Steps

1. **Read the current version/build** from `project.yml`:
   - `MARKETING_VERSION` (e.g. `0.1.5-alpha.5`)
   - `CURRENT_PROJECT_VERSION` (e.g. `6`)

2. **Compute the next values** (unless the user gave an explicit version):
   - **build** = current build + 1 (must strictly increase — Sparkle requires it).
   - **version**: bump the trailing `alpha.N` → `alpha.N+1`
     (e.g. `0.1.5-alpha.5` → `0.1.5-alpha.6`). If the user names a version, use theirs.

3. **Confirm with the user**: show the version + build you're about to ship and
   the fact that it will push a commit + tag to `main` and publish a GitHub
   Release that all testers' updaters will pick up. Wait for go-ahead.

4. **Preflight** (catch problems before burning a CI run):
   - `git status --porcelain` — warn if the working tree is dirty; the workflow
     releases from `origin/main` HEAD, so uncommitted local work won't be included.
   - Confirm `main` is pushed: `git rev-list --left-right --count origin/main...HEAD`.
     If local is ahead, tell the user to push first (the runner builds what's on
     `origin/main`, not local).
   - `gh auth status` — must be authenticated.

5. **Dispatch the workflow**:
   ```
   gh workflow run release.yml -f version=<VERSION> -f build=<BUILD>
   ```

6. **Watch it** until it finishes:
   ```
   sleep 5
   gh run list --workflow=release.yml --limit 1
   gh run watch <run-id> --exit-status
   ```
   (Use `run_in_background` for the long `gh run watch`, or poll with
   `gh run view <run-id>`.)

7. **Report the result**:
   - On success: confirm the new version is live — the GitHub Release exists and
     `docs/appcast.xml` on `main` now advertises it. Optionally verify:
     `gh release view v<VERSION>` and check the hosted appcast
     `https://merlinkraemer.github.io/prunr/appcast.xml`.
   - On failure: pull the failing step's log with
     `gh run view <run-id> --log-failed` and surface the actual error. The most
     likely first-run failure is code-signing (missing/incorrect
     `MACOS_CERT_P12_BASE64`) — see `docs/release-ci.md`.

## Notes

- The workflow is **manual-dispatch only** — it never auto-fires on push, so
  there is no risk of accidental releases. This skill is the trigger.
- One-time setup (secrets) is documented in `docs/release-ci.md`. If the workflow
  fails on the very first run with an auth/signing error, point the user there.
- The workflow must exist on `main` for `gh workflow run` to find it. If
  dispatch errors with "workflow not found", the release workflow hasn't been
  pushed to `main` yet.
