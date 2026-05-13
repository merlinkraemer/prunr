# Manual Test Checklist

Use alongside Console.app filtered to `com.prunr.app` while running the app in Debug mode.

## Scenario 1: Fresh launch → first scan of empty directory
- [ ] App launches without crash
- [ ] Console shows `StateMerge` and `Progress` log entries
- [ ] UI shows "no data" state appropriately

## Scenario 2: Fresh launch → first scan of large directory (~10k files)
- [ ] Scan starts, `Progress` category logs appear every ~2s
- [ ] Categories appear live during scan
- [ ] No `DUPLICATE CATEGORIES` messages in Console
- [ ] `applyPartial done` always shows `growing=0`
- [ ] Scan completes, final state is correct

## Scenario 3: Add 100 files to watched directory → wait for FSEvents refresh
- [ ] FSEvents callback fires within ~1-2s
- [ ] `emitChangeBatch` logged with `running=true`
- [ ] UI refreshes after coalescing window
- [ ] No `DUPLICATE CATEGORIES` messages

## Scenario 4: Delete 50 files → wait for refresh
- [ ] FSEvents callback fires
- [ ] UI updates correctly with reduced sizes
- [ ] No stale data visible

## Scenario 5: Start manual scan → cancel mid-scan
- [ ] Progress updates stop immediately
- [ ] UI returns to clean state
- [ ] No stale progress percentages linger

## Scenario 6: Accept growth → verify categories update
- [ ] Growth stories disappear from UI
- [ ] Category sizes remain stable
- [ ] `normalize` logs show correct counts

## Scenario 7: Background the app → foreground → verify state is consistent
- [ ] State is preserved after foreground
- [ ] No duplicate categories appear
- [ ] FSEvents resume correctly

## Scenario 8: Trigger two scans rapidly back-to-back
- [ ] No crashes
- [ ] No duplicate categories
- [ ] Final state reflects last completed scan
- [ ] No `DUPLICATE CATEGORIES` in Console

## Alpha freshness gate
- [ ] Build current tree: `make build`
- [ ] Run full test suite: `make test`
- [ ] Launch the current Debug app build and wait for an existing baseline
- [ ] Run `npm run monitor -- --freshness-probe`
- [ ] Probe output shows the configured tracked root, working-set byte delta, and category-total byte delta for the same tracked path
- [ ] Run `npm run monitor -- --samples 5 --interval 5`
- [ ] Short monitor run shows no repeated full-scan loop, no unexpected category drift, and low idle CPU/RSS
