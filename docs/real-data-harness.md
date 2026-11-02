# Real-data replay and headless snapshots

Reproduce "the row says +X but the drilldown does not show what grew" from real data, and check visuals without a window.

## Pieces

| What | Where |
|------|-------|
| Replay harness (feed + per-row drilldown, text and JSON dump) | `PrunrTests/TestSupport/ReplayHarness.swift` |
| Synthetic fixture library (no personal data) | `PrunrTests/TestSupport/FixtureLibrary.swift` |
| Headless panel renderer (ImageRenderer, no window) | `PrunrTests/TestSupport/PanelSnapshot.swift` |
| Tests | `ReplayHarnessTests`, `PanelSnapshotTests` |
| Fetch PNGs and dumps to dev, build the review page | `scripts/snapshots-fetch.sh` (`make snapshots-fetch`) |

The harness runs the app's real reads: `GrowthJournalService.changeFeed` for the list, `DatabaseManager.fetchPlaceContents` for each row's drilldown (what the app shows when a place is opened). Each dumped row also lists the journal slots behind it, so you can compare what the journal says grew with what the drilldown shows. The drilldown is sizes by total, not growth.

## Real snapshot

Snapshots live on dev, outside git: `~/dev/projects/prunr-data/` (read-only files, never the live DB).

Take a new one (does not lock the running app; reads through WAL):

```
ssh mbp 'cd ~/dev/build/prunr-snap && rm -f snap.db slim.db && sqlite3 -readonly "$HOME/Library/Application Support/Prunr/prunr.db" "VACUUM INTO \"$HOME/dev/build/prunr-snap/snap.db\"" && cp snap.db slim.db && sqlite3 slim.db "PRAGMA foreign_keys=OFF; DROP TABLE snapshotEntry; DROP TABLE workingSetEntry; DROP TABLE workingSetRefreshStaging; DROP TABLE pathClassification; DELETE FROM paths WHERE id NOT IN (SELECT pathId FROM workingSetTopEntry); VACUUM;"'
scp mbp:dev/build/prunr-snap/slim.db ~/dev/projects/prunr-data/prunr-$(date +%F).db
```

The full copy is about 2.7 GB (slow over the tailnet); the slim copy (about 33 MB) keeps what the feed and drilldown read: the journal, snapshots and the place and group indexes.

`ReplayHarnessTests.testRealSnapshotReplayWhenAvailable` uses `$PRUNR_REPLAY_DB`, else `~/dev/build/prunr-snap/slim.db` on the Mac, and skips when neither exists (CI). It works on a copy in a temp dir. The same DB file must be on the Mac, so copy the slim DB there when it is not.

## Run

- `make test` (or a `mac-queue ... test Prunr` job) runs everything. On the Mac, with the slim DB in place, it also replays the real snapshot.
- Replay one DB: `make replay DB=/path/to/slim.db`.
- Output goes to `/tmp/PrunrSnapshots` on the Mac (`PRUNR_SNAPSHOT_DIR` overrides): `replay/fixture.{txt,json}`, `fixture/*.png`, `real/replay.{txt,json}`, `real/*.png`.
- `make snapshots-fetch` copies that folder to `~/dev/projects/prunr-data/review/` on dev and writes `index.html`. The review page serves that folder: `preview start prunr snapshots` (port 4181).

## Fixtures

`FixtureLibrary` seeds a temp DB for the user `/Users/tester`: a game project whose 32 GB of new build output sits next to a bigger, older asset folder, a multi-day build folder, a photo library, a shrinking package cache, a Chrome cache owned by an app, a Steam game and a download. Add a case there when real data shows a new pattern; keep names and paths synthetic.
