Prunr 0.1.5-alpha.11
Static audit · 21 Aug 2026
Branch claude/app-performance-feature-review-odern6
Prunr Depth Audit
Six areas, read end to end against the source: drilldown caching, general responsiveness, scan correctness, the feedback funnel, the settings surface, and the refresh/autoscan machinery. Thirty-eight findings. Two of them explain most of what the app feels like.

5
 critical
13
 high
13
 medium
7
 low
The short version
The drilldown does not reload because loading is slow — it reloads because the cache is invalidated on every single inventory refresh, and the retention branch that was written to prevent exactly that is dead code. One counter is doing two jobs (CACHE-01). Compounding it, the panel throws away its entire SwiftUI tree on close and rebuilds it on open (CACHE-02), so every menu open re-runs the full bootstrap.

On the scan side, there are two genuine data-integrity bugs: a case-collation mismatch that can make full scans fail permanently after an ordinary file rename (SCAN-02), and an unbounded producer buffer that lets a large scan accumulate the whole traversal in RAM (SCAN-01). SCAN-02 is a strong candidate for the infinite full-scan retry loop documented in docs/session/handoff.md.

The feedback path is well-built but rests on an endpoint the repo's own notes last recorded as 404, and it hard-fails the whole submission when diagnostics can't be written. Settings is missing its single most consequential knob — the rescan interval — and the footer Refresh button does nothing at all in the common case.

01 · Drilldown
Why every navigation reloads
Traced from selectCategory through loadSubcategoryBreakdown down to the SQL. The caching layer is correctly designed and then defeated by a one-line ordering mistake.

CACHE-01
Critical
One generation counter guards two unrelated caches, so the retain path never retains
MenuBarManager.swift:1653 decides whether a category's breakdown is still usable by comparing subcategoryBreakdownCacheGenerationByCategory[category] against growthContributorCacheGeneration. But applyInventory calls invalidateGrowthContributorCache() unconditionally at MenuBarManager.swift:2151 — outside the if shouldInvalidateSubcategoryCache branch — and that bumps the counter.

// applyInventory, lines 2130–2151
if shouldInvalidateSubcategoryCache {
    subcategoryGroupsByCategory = [:]              // wipe
} else {
    subcategoryGroupsByCategory = ...filter { ... } // carefully retained…
    subcategoryBreakdownCacheGenerationByCategory = ...filter { ... }
}
invalidateGrowthContributorCache()               // …and instantly stale-marked
The dictionary entries survive; isSubcategoryBreakdownReady returns false for every one of them. invalidateSubcategoryCache: false is therefore a no-op at every call site.

The trigger rate is the real problem. performRecentChangeRefresh ends with invalidateGrowthContributorCache() and then loadInventoryFromLatestSnapshot(invalidateSubcategoryCache: false) (MenuBarManager.swift:3169–3175), so the counter advances twice per FSEvents-driven refresh. Since the watcher covers ~, that is roughly every 1.5 s of filesystem activity.

Give the subcategory breakdown its own counter (subcategoryCacheGeneration), bumped only inside the if shouldInvalidateSubcategoryCache branch. Leave growthContributorCacheGeneration where it is — contributors genuinely are snapshot-relative and should invalidate on every delta. Drop the redundant bump at line 3169.
CACHE-02
Critical
Closing the panel destroys the whole view tree; opening it rebuilds from zero
togglePopover calls uninstallPanelHostingView() on close (MenuBarManager.swift:2376–2382) and constructs a fresh NSHostingView(rootView: MenuBarView(manager: self)) on the next open. Every piece of SwiftUI @State dies with it: ExpandableList.visibleCount, resolved app icons, growthContributors, drilldown transition state, scroll position.

It also re-arms MenuBarView's .task (MenuBarView.swift:441), which on every open runs a permission probe, loadQuickInventory(), checkBaseline(), updatePathSize() and loadInventoryFromLatestSnapshotIfStale() — several DB round-trips per tracked path before anything paints.

The comment above it explains the motivation (idle CA layout passes at ~17% CPU with a SwiftUI App scene), and that motivation is sound — but the fix overshoots. The pure-AppKit entry point in PrunrMenuBar.swift already solves the scene-graph problem.

Keep the hosting view installed and instead stop feeding it: the panel is ordered out, so it receives no display cycle. If idle invalidation is still measurable, gate the observable writes on isPopoverShown rather than destroying the view. If teardown must stay, hoist the per-open work out of .task and behind a manager-owned "already bootstrapped this launch" flag — loadQuickInventory, checkBaseline and updatePathSize currently have no such guard.
CACHE-03
High
hasIncrementalDeltasSinceSnapshot latches on and forces the slow query path
shouldUseWorkingSetForSubcategoryDetails (MenuBarManager.swift:2182) returns true whenever any incremental delta has landed since the last full snapshot. The flag is set on the first successful incremental refresh and only cleared by a new snapshot, an accept, or a reset.

From that moment every drilldown goes through getSubcategoryBreakdownFromWorkingSet → fetchWorkingSetSubcategoryGroupsByClassification, which has no precomputed equivalent of subcategorySnapshot and must aggregate and top-N sort live. In practice the app spends nearly all of its life in this mode.

Track the flag per category (liveWorkingSetDrillDownCategories already exists and is populated — it is simply not consulted here), and maintain a workingSetSubcategoryTotal table alongside workingSetCategoryTotal so the live path has the same precomputed shortcut the snapshot path enjoys.
CACHE-04
High
Entering a category fires one full-table-scan query per subcategory group, sequentially
prefetchGrowthContributors (CategoryGrowthListView.swift:733) loops every group and awaits loadGrowthContributors for each. Each call runs fetchGrowthContributors (DatabaseManager.swift:2620), which scans workingSetEntry for the whole tracked path, LEFT JOINs snapshotEntry, and sorts by a computed growthBytes expression — unindexable by construction.

For cachesAndSystem it additionally applies p.path LIKE '%/Library/Caches/key%', a leading-wildcard LIKE that forces a scan even if an index existed.

Prefetch only the group the user is about to see, and only after the breakdown renders. Replace the LIKE filter by persisting the cache-owner key as a column on pathClassification at classification time — the value is already computed during the scan. Then a composite index on (category, subcategory, cacheOwner, pathId) makes the query sargable.
CACHE-05
High
The Caches drilldown never uses the precomputed summaries and reads every cache row
getSubcategoryBreakdown(for:snapshotId:) (BaselineService.swift:500) short-circuits cachesAndSystem straight to fetchCacheApplicationGroups, skipping the subcategorySnapshot fast path the scan already populated. That query has no LIMIT — it pulls every cache-classified path and size for the snapshot into memory (DatabaseManager.swift:1148–1180).

Persist per-owner cache groups into subcategorySnapshot during the scan (the scan already builds per-subcategory accumulators; extend the key to include the owner), and read them back the same way every other category does.
CACHE-06
High
Cache grouping re-sorts a 50-element array once per row, with a locale-aware comparator
makeCacheApplicationGroups appends each row to its owner's topFiles, then calls .sort on the whole array and drops the last element — for every row (DatabaseManager.swift:1233–1246). The tie-break uses localizedStandardCompare, one of the most expensive string comparisons in Foundation.

At topLimit = 50 that is roughly n × 50 log 50 comparisons plus two copy-on-write array copies per row (the accumulator is read out of and written back into the dictionary). On a cache tree of a few hundred thousand files this alone is seconds.

Keep an unsorted bounded min-heap, or simply append and sort once per owner at the end. Compare by sizeBytes first and fall back to a plain < on the path — locale ordering is not meaningful for filesystem paths.
CACHE-07
Medium
No index supports the top-N-by-size drilldown queries
fetchWorkingSetEntriesByClassification and fetchSnapshotEntriesByClassification both end in ORDER BY sizeBytes DESC, path ASC LIMIT ?. The available indexes cover (trackedPathId, pathId), (snapshotId, pathId) and (category, subcategory, pathId) — none carries sizeBytes, so SQLite materialises and sorts the entire matching set to return 50 rows.

Precomputed top-N (CACHE-03/CACHE-05) removes the need entirely. If you want a cheaper interim win, add workingSetEntry(trackedPathId, sizeBytes DESC, pathId) so at least the outer sort is served by the index.
CACHE-08
Medium
"Load more" re-fetches everything already loaded, on every click
The multi-path loadMoreSubcategoryFiles (BaselineService.swift:796) requests offset + limit rows from each snapshot, concatenates, sorts the union, then dropFirst(offset). At the 500-file ceiling the final click fetches 500 rows per path to show 50. With a single tracked path — the common case — it also discards SQLite's own OFFSET pushdown for no benefit.

Take the single-path fast path when snapshotIdsByPath.count == 1. For the multi-path case, keep a per-path cursor rather than re-reading from zero.
02 · Responsiveness
Where the main thread goes
Separate from the caching problem: work that is correct but is happening on the wrong thread, too often, or too expensively per item.

PERF-01
High
FSEvents batches are filtered and normalised twice, both times on the main thread
FSEventsWatcher.classifyEvents runs on the main dispatch queue and, for every raw event, calls FSEventsNoiseFilter.shouldIgnore (an NSString bridge plus up to nine String.contains checks) and then URL(fileURLWithPath:).standardizedFileURL for up to 1,024 collected paths.

MenuBarManager.filteredRecentChangePaths (MenuBarManager.swift:3247) then repeats both — the same shouldIgnore pass and another .standardizedFileURL map — also on the main actor. During a build or an npm install this runs continuously.

Move classifyEvents onto a utility queue and hand the main actor a finished ChangeBatch. Drop the second filter pass — the paths arriving from the watcher are already filtered and standardized; the duplicate exists only to serve scheduleRecentChangeRefresh, which can filter at its own call site.
PERF-02
High
Per-file classification is the scan's dominant CPU cost
GrowthCategory.classify(path:) runs once per scanned file. Each call does expandingTildeInPath (an NSString bridge and allocation), then .lowercased() — full Unicode case folding, allocating a second String — then walks up to ~62 String.contains(_:) checks. Swift's String.contains performs canonical-equivalence matching, not a byte search, and several helpers build their needle by interpolation on every call:

private static func containsPathComponent(_ lowerPath: String, _ component: String) -> Bool {
    lowerPath.contains("/\(component)/") || lowerPath.hasSuffix("/\(component)")
}
At the 2.25M-file scale recorded in docs/session/handoff.md this is tens of millions of allocations and hundreds of millions of Unicode-aware comparisons — a very plausible share of the ~70% CPU documented there.

Classify over the path's UTF-8 bytes with ASCII-lowercased comparison (paths are overwhelmingly ASCII; a non-ASCII fallback to the current logic is cheap and rare). Hoist every interpolated needle into a static let. Match on path components once rather than re-scanning the whole string per predicate. Skip expandingTildeInPath entirely on the scan path — FTS never produces tilde paths.
PERF-03
High
App icons are resolved through Launch Services on the main actor, uncached
CacheApplicationIconResolver.icon is @MainActor and calls NSWorkspace.shared.urlForApplication(withBundleIdentifier:) followed by icon(forFile:) (CategoryGrowthListView.swift:1231–1249). Both are synchronous, both can hit disk and the Launch Services database. It runs from .task(id:) on every visible cache row, with no memoisation — and because of CACHE-02, again from scratch on every panel open.

Resolve off the main actor and memoise by bundle identifier in a static dictionary that outlives the view tree. Cache negative results too — unknown owners currently pay the full lookup every time.
PERF-04
Medium
Broken string interpolation disables five of the six browser icon fallbacks
knownApplicationPaths is missing the backslash on every user-Applications entry (CategoryGrowthListView.swift:1268, 1272, 1276, 1280, 1284):

"com.google.Chrome": [
    "/Applications/Google Chrome.app",
    "(NSHomeDirectory())/Applications/Google Chrome.app"  // literal text
],
FileManager.fileExists is checked against the literal string "(NSHomeDirectory())/Applications/…", which never exists. Chrome, Chrome Canary/Beta/Dev and Firefox installed under ~/Applications silently fall back to the generic SF Symbol — the exact case this table was added to cover.

Add the backslashes, and note that a dictionary literal can't capture NSHomeDirectory() at type-initialisation time in a way you'd want anyway — build these paths in a static var computed once, or append the home directory at lookup time.
PERF-05
Medium
The scan's top-N accumulator does a linear scan per file
SubcategoryAccumulator.add (ScanService.swift:242) finds the smallest retained item with topItems.indices.min(by:) — an O(50) pass — for every file once the list is full, across every subcategory. Combined with PERF-02 this is the inner loop of the entire scan.

Track the running minimum index alongside the array, or use a fixed-size binary min-heap. Both are O(1) / O(log k) per insert.
PERF-06
Low
Small allocation and animation churn in the list views
ExpandableList materialises Array(items.prefix(visibleCount)) on every body evaluation (ExpandableList.swift:32). SkeletonBlock starts a repeatForever animation per instance with no prefers-reduced-motion equivalent — SwiftUI's accessibilityReduceMotion is not consulted anywhere in the file.

Iterate the slice directly with ForEach(items.prefix(visibleCount), id: \.id). Gate the skeleton shimmer on @Environment(\.accessibilityReduceMotion).
03 · Scan
Correctness, leaks and failure modes
The FTS traversal itself is solid — good error policy, a working stall watchdog, correct cleanup of the C allocations. The problems are at the boundary between the producer and the database.

SCAN-01
Critical
Unbounded stream buffer lets a full scan accumulate the entire traversal in memory
FileScanner.scan returns AsyncThrowingStream<ScanResult, Error> { continuation in … } (FileScanner.swift:94). That initialiser defaults to .unbounded buffering, so continuation.yield never applies backpressure.

The consumer in ScanService.scanBody awaits a database write every 10,000 results, and those writes are chunked into 20 separate transactions. FTS traversal is far faster than SQLite inserts, so the producer runs ahead and the buffer grows for the whole scan. Each buffered ScanResult holds a heap-allocated path String; at 2.25M files that is hundreds of megabytes of resident memory that serves no purpose.

Note that .bufferingNewest/.bufferingOldest are not the fix here — both silently drop results, which would corrupt the inventory.

Give the producer real backpressure. The lightest change that preserves the current shape: have the producer await a CheckedContinuation that the consumer resumes after each batch write, resuming immediately whenever fewer than N results are outstanding. The cleaner change: drop the AsyncStream entirely and run the FTS loop with a batching callback — the traversal is already a tight synchronous loop and gains nothing from being a stream.
SCAN-02
Critical
A case-only rename can make every subsequent full scan fail permanently
paths.path is declared UNIQUE … COLLATE NOCASE (migration v10, DatabaseManager.swift:230–233). Inside fetchPathIds (DatabaseManager.swift:2519) the lookup is case-insensitive but the result dictionary is keyed by the stored spelling:

// SQLite compares with the column's NOCASE collation…
let sql = "SELECT id, path FROM paths WHERE path IN (\(placeholders))"
for row in rows { result[storedPath] = pathId }   // …but we key by what's on disk

// addEntriesCore, line ~727 — Swift Dictionary lookup is case-SENSITIVE
guard let pathId = pathIdByPath[scanResult.path] else {
    throw DatabaseError.pathLookupFailed(scanResult.path)
}
On a case-insensitive APFS volume, renaming Report.pdf → report.pdf leaves the old spelling in paths. INSERT OR IGNORE won't add the new one; the SELECT returns the old one; the dictionary lookup misses; the scan throws, the snapshot is deleted, and the working set is restored. The stale row persists, so the next scan fails identically.

This matches the failure shape in docs/session/handoff.md exactly: a full traversal that completes and then dies in the DB-write phase, never advancing lastFullScanCompletedAt, leaving the cooldown gate permanently open and the retry loop spinning. The reported code=0 doesn't line up with pathLookupFailed (enum index 2), so this may not be that exact instance — but it is an independent, reproducible permanent-failure path and worth closing regardless.

Key the result dictionary case-insensitively, or normalise both sides. The minimal change is to build result keyed on a lowercased path and look up the same way; the more correct change is to make the paths uniqueness match the volume's actual semantics and update the stored spelling on conflict (ON CONFLICT(path) DO UPDATE SET path = excluded.path). Add a regression that scans, renames a file changing only case, and rescans.
SCAN-03
High
A duplicate path in one batch is a hard crash, not a handled error
DatabaseManager.swift:711–715 builds the classification map with Dictionary(uniqueKeysWithValues:) over exactly the collection that the very next line de-duplicates with Set:

let uniquePaths = Array(Set(normalizedBatch.map(\.path)))          // dupes expected here…
let classificationsByPath = Dictionary(
    uniqueKeysWithValues: normalizedBatch.map { ($0.path, …) }  // …but a trap here
)
Dictionary(uniqueKeysWithValues:) calls fatalError on a duplicate key — an uncatchable crash mid-scan, in a code path that is otherwise carefully error-handled. Swift String equality is canonical-equivalence-based, so two paths differing only in Unicode normalisation would collide here even though they are distinct byte sequences.

Dictionary(normalizedBatch.map { … }, uniquingKeysWith: { _, latest in latest }). One-line change, removes a crash class.
SCAN-04
High
An FSEvents batch can trigger an uncancellable recursive scan of an arbitrary subtree
RecentChangeService.applySubtreeRefresh calls scanner.scan(root, ignoredNames: ignoredNames) with no cancellation token (RecentChangeService.swift:154) and no size bound. A single directory event on something like ~/Library or ~/Movies walks that entire subtree inside the 1.5-second debounce cycle.

The guards that exist stop short of this: changedPaths.count > 25_000 and targets.count > 192 both bound the number of targets, and a target equal to the tracked root escalates to a full scan — but a single large non-root subtree passes all three.

refreshTargets also runs up to 25,000 serial fileExists stats on the actor before any of that.

Pass a ScanCancellationToken through and cancel it when a newer batch arrives or the app goes idle. Add a per-target entry budget: if a subtree exceeds it mid-walk, abandon the incremental path and mark the root dirty instead. Move the fileExists sweep off the actor.
SCAN-05
Medium
Hard links are counted once per link
The traversal uses FTS_PHYSICAL and sums st_blocks × DEV_BSIZE for every FTS_F entry. A file with several hard links contributes its full allocated size once per path. Time Machine local snapshots, some package managers, and Xcode's clonefile-heavy caches all produce these, so sizes can overstate real disk usage.

Skip entries where st_nlink > 1 and (st_dev, st_ino) has already been seen this scan. A Bloom filter or a bounded hash set keeps the memory cost negligible, since multi-link files are a small minority.
SCAN-06
Medium
The active-scan counter is decremented from an unordered detached task
ScanService.scan increments activeScanCount via await MainActor.run but decrements it from a fire-and-forget Task { @MainActor in activeScanCount -= 1 } inside defer (ScanService.swift:130–136). The decrement is unordered with respect to a subsequent scan's increment, and unobserved by the caller.

isScanning drives the Settings scope lock and the scan banner, so a lost or reordered decrement leaves scope controls disabled with no way to recover short of a relaunch.

Make the whole counter an actor-isolated property of ScanService and publish a derived @MainActor mirror, or await the decrement before scan returns.
SCAN-07
Low
FSEventsWatcher.deinit is unreachable by construction
start() does Unmanaged.passRetained(self) to build the callback context. That +1 means the object's refcount can never reach zero while a stream exists, so the cleanup in deinit is dead code and correctness rests entirely on every path calling stop(). Today they do — but the invariant is invisible and easy to break.

Pass a small final class Box { weak var watcher: FSEventsWatcher? } as the context instead, so the stream never owns the watcher and deinit becomes a real backstop.
SCAN-08
Low
Directory-skip checks rebuild a URL and split the path per directory
shouldSkipDirectory does URL(fileURLWithPath: path).standardizedFileURL.path and then path.split(separator: "/").map { $0.lowercased() } for every directory entered (FileScanner.swift:253–299). FTS paths are already absolute and standardized; the round-trip through URL buys nothing.

Compare against the raw C-string-derived path and check the last component only, which is all the predicates actually need.
04 · Feedback
Is the funnel sound?
Structurally, yes. The relay validates input properly, bounds the payload, escapes HTML, sets replyTo, and never echoes the Brevo key. The client maps transport failures to a useful message and its 200 KB attachment cap sits correctly under the server's. The problems are operational, plus one hard-fail path.

FB-01
Critical
The endpoint is a single point of failure and its liveness is unverified
FeedbackService.endpoint is hardcoded to https://prunr-web.vercel.app/api/feedback. The repo's own docs/todo.md records the last live check as "Vercel 404; feedback is currently broken." I could not re-verify from this environment — the sandbox proxy refuses the host (CONNECT tunnel failed, 403), so this is unconfirmed either way.

It matters more than a normal outage would, because there is no fallback: a user who hits a 404 gets "Could not send feedback: The feedback service returned an unexpected response" and a Reveal Diagnostics Report in Finder button, with no address to send it to. The mailto address only appears in the offline branch.

Verify with curl -X POST …/api/feedback -d '{"token":"bad"}' — a healthy deployment returns 401 {"error":"Unauthorized."}, a missing route returns 404. Also confirm BREVO_API_KEY and BREVO_SENDER_EMAIL are set, since without them the handler returns a 500 that reads to the user as a generic failure. Then add the mailto fallback to every error branch, not just .networkUnavailable, and put a live probe into the release checklist alongside the notarization step.
FB-02
High
Feedback can't be sent at all if diagnostics can't be written
sendFeedback (SettingsView.swift:301–307) begins with a guard let diagnostics = MenuBarManager.shared?.prepareDiagnosticsAttachment() else { return }. If the log directory can't be created, the log is unreadable, or MenuBarManager.shared is nil, the user's typed message is discarded and they are told to send a report manually — one that, by definition, doesn't exist.

The server treats diagnosticsBase64 as optional (value == null → attachment: null). The hard requirement is purely client-side.

Make the attachment optional: send the message with diagnostics: nil and surface "Sent — diagnostics could not be attached" rather than refusing. This is the exact population whose feedback is most valuable.
FB-03
Medium
The shared token ships in the binary and there is no rate limit
sharedToken = "prunr-alpha-feedback-v1" is a plain constant in a distributed app, and the same value is the server default. Anyone who runs strings on the bundle gets an unauthenticated relay into your inbox and your Brevo send quota. The handler's own comment acknowledges the token is only a deterrent, but no second layer was added.

Add per-installId and per-IP rate limiting (Vercel KV or Upstash; a few sends per hour is generous), set FEEDBACK_SHARED_TOKEN to something other than the committed default, and cap total daily sends so a flood degrades to dropped requests rather than a quota bill.
FB-04
Medium
Over-long messages fail after typing, and the outermost size limit returns the wrong error shape
The server caps message at 10,000 characters and returns 400 "Feedback message is required." when exceeded — misleading, since the message was very much supplied. The client imposes no limit and gives no counter, so a long bug report is lost on submit.

Separately, config.api.bodyParser.sizeLimit: "350kb" is enforced by Vercel before the handler runs, so an oversized body never reaches the MAX_BODY_BYTES check and comes back as a platform error page. JSONDecoder().decode(FeedbackErrorResponse.self, …) fails to parse it and the user gets the generic fallback string.

Enforce the 10,000-character cap in the TextEditor with a visible counter, and split the server's message validation into "missing" and "too long" so the error is honest. Have the client treat a non-JSON error body as a distinct, explainable case.
FB-05
Low
Post-send state is half-cleared
On success the message clears but feedbackEmail and feedbackNotice persist indefinitely — reopening Settings still shows "Feedback sent. Thank you." from an earlier session, which reads as though a new send just succeeded.

Clear the notice on a timer or when the editor regains focus. Keeping the email is reasonable — keeping a stale success message is not.
Verified as sound: the diagnostics redaction regex covers ~, /Users and /Volumes prefixes; redaction happens on write and again on attach; scopeSummary emits counts only, never location names; newestCompleteRecords drops the leading partial record so the cap can't split a UTF-8 scalar; installID is a random v4 UUID that satisfies the server's UUID_RE; and the base64 round-trip check correctly rejects malformed attachments.

05 · Settings
What's exposed, what isn't, what's wired to nothing
The Scan Rules tab was removed in the 2026-08-19 simplification, but the store behind it was left intact. Several settings are fully implemented, persisted, and read by the engine — with no way to reach them.

Setting	Read by	In UI	Notes
automaticFullScanIntervalHours	Reconciliation backstop	No	Presets [24,48,72,168,336] defined; markAutomaticFullScanIntervalChosenByUser() never called
categoryHistoryRetentionDays	Growth journal, cleanup	No	Defines what "growth since baseline" means; default 30d
customScanIgnores	Scanner + noise filter	No	addScanIgnore/removeScanIgnore have no caller
customBoundaries	Nothing	No	allBoundaries/enabledBoundaries computed, never consumed
customTrackedPaths	Path aggregation	No	Only presets + one base folder are reachable
launchAtLogin	SMAppService	Yes	Reads UserDefaults, not SMAppService.mainApp.status
mainBasePath	All scans	Yes	Correct, with a proper apply/reset confirmation
selectedCommonPathIDs	All scans	Partly	Settings only; the onboarding first scan ignores them (REF-03)
SET-01
High
The rescan interval — the app's biggest CPU lever — has no control
automaticFullScanInterval drives reconciliationBackstopDelay and therefore how often Prunr re-walks the entire scope. It is the difference between a 24-hour and a weekly full traversal on a 2M-file machine. Everything for a picker exists — automaticFullScanIntervalPresetHours, the persistence, the automaticFullScanIntervalUserTouched guard — except a control.

Because markAutomaticFullScanIntervalChosenByUser() has no callers, automaticFullScanIntervalUserTouched is permanently false, so the one-shot adaptive interval always wins and the user has no override.

Add the picker to General with a plain-language footnote ("Prunr re-checks everything on this schedule; more often means fresher numbers and more CPU"), and call markAutomaticFullScanIntervalChosenByUser() from its onChange.
SET-02
Medium
No way to exclude a folder from scanning
customScanIgnores feeds both allScanIgnoreNames (passed to every FileScanner.scan) and FSEventsNoiseFilter's cached custom set. It works — it just can't be edited. A user whose scan stalls or spikes on one directory has no remedy short of changing the whole base path.

A minimal add/remove list in Scan Scope. It is the natural companion to the "Still blocked" list already shown there, and it is the most likely support request an alpha generates.
SET-03
Medium
Boundary configuration is entirely dead
BoundaryConfig.standardBoundaries, customBoundaries, disabledBoundaryNames, addBoundary, removeBoundary and setBoundaryEnabled all exist and persist. Nothing reads enabledBoundaries. BaselineService holds a boundaryConfig = BoundaryConfig.default property that is never referenced either.

Delete it. Persisted keys that no code path consumes are a migration hazard and mislead the next reader into thinking there is a feature here.
SET-04
Medium
"Launch at Login" drifts out of sync with System Settings
The toggle initialises from UserDefaults.standard.bool(forKey:) and only writes to SMAppService in didSet. If the user disables Prunr under System Settings › General › Login Items, or registration throws (the error is logged and swallowed), the switch keeps showing the stale value forever.

Initialise from SMAppService.mainApp.status == .enabled, refresh it on NSApplication.didBecomeActiveNotification, and revert the toggle when register()/unregister() throws instead of only logging.
SET-05
Low
Dead view models still compile into the shipping binary
MainViewModel (516 lines) is referenced only by tests. PathManager (113 lines) has no references at all. Both ship in the release build. autoInitializeIfNeeded (~40 lines in MenuBarManager) is likewise never called — the first scan is entirely onboarding-driven.

Delete PathManager and autoInitializeIfNeeded. For MainViewModel, either move the baseline-selection logic it tests into BaselineService (where the production path already lives) and retarget the tests, or delete both.
SET-06
Low
Reset doesn't clear the failure backoff
refreshAfterBaselineReset (MenuBarManager.swift:1028) clears inventory, pending changes and timestamps, but not consecutiveFailedFullScans / consecutiveFailedReconciliations. A user who resets specifically because scans have been failing inherits the accumulated backoff — up to 30 minutes before anything runs, with no indication why.

Zero both counters and call scheduleReconciliationBackstop() after the reset.
06 · Refresh
Refresh and autoscan
The autoscan machinery — FSEvents → debounce → incremental refresh → escalation → periodic backstop, with cooldowns and exponential backoff at each stage — is genuinely well thought through. The manual control on top of it is not.

REF-01
High
The Refresh button does nothing when there is nothing queued
The footer refresh calls checkGrowth(), which flushes pending FSEvents work via performRecentChangeRefresh(allowFullRefresh: false). That function's first statement is:

guard pendingRecentChangeRequiresFullRefresh || !pendingRecentChangePaths.isEmpty else {
    hasPendingRecentChanges = false
    return
}
With an empty queue — the normal state, since the debounce already drained it 1.5 s after the last event — the button flips isCheckingGrowth on and off and does no work. The user sees a spinner and unchanged numbers, which reads as "the app is stuck", not "nothing changed".

When the queue is empty, do something real and cheap: re-read the working set with loadInventoryFromLatestSnapshot(refreshedAt: Date()). Then report the outcome — "Up to date" beats a spinner that resolves into silence.
REF-02
High
With no watcher, refresh is permanently inert and there is no manual rescan
The watcher is torn down whenever noBaseline is true or enableAutomaticFileWatcher is off, and reconciliation is gated behind isPermissionConfirmedForProtectedTraversal. In those states nothing ever enqueues a pending path, so REF-01's guard always returns early — refresh can never do anything.

The panel offers no way to force a full rescan either. refreshVisibleInventory() exists and does exactly that, correctly (cancels reconciliation, runs loadInventory, reschedules the backstop) — and has no caller anywhere in the view layer.

Wire refreshVisibleInventory() to a long-press or ⌥-click on the refresh button, or a "Rescan now" item in the right-click menu. Users who hit the not-tracking footer state currently have no path forward at all.
REF-03
Medium
The onboarding first scan covers only the main path
startOnboardingFirstScan (MenuBarView.swift:1789) passes trackedPathsOverride: [settingsStore.mainTrackedPath]. In a clean first run this is fine — onboarding only configures the base folder. But onboarding also reappears whenever noBaseline becomes true, including after Reset Prunr Data, and at that point the user may already have additional locations selected in Settings. Those get silently skipped and stay without a baseline until a later reconciliation picks them up.

Use SettingsStore.shared.enabledTrackedPaths and let effectiveTrackedPaths deduplicate, as every other scan entry point already does.
REF-04
Medium
Stacked cooldowns can leave growth stale for hours with only a quiet label
Three independent gates compound on a busy machine:

An escalation to full refresh hits requiresFullRescanCooldown — 30 min
The dirty-root retry backs off 15s × 2ⁿ, capped at dirtyRootMaxDelay — 30 min
The periodic backstop waits automaticFullScanInterval — 24 h by default
A machine generating dirty batches faster than they clear can sit for a long stretch showing "Changes detected" while the numbers behind it don't move. Each individual gate is defensible; the combination is invisible to the user.

Surface the reason in the footer — "Next full check in 24 min" — using reconciliationBackstopDelay(), which already computes exactly this. Pair it with the manual rescan from REF-02 so the answer to "why is this stale" is always one click from a fix.
REF-05
Low
A 60-second timer re-checks the watcher forever
startRealtimeUpdates schedules a repeating 60s Timer that calls updateFreeSpace() and configureFileWatcherIfNeeded(), and the latter spawns a Task just to read watcher.isRunning. Cheap individually, but it keeps a menu-bar app waking once a minute for work that is almost always a no-op.

Re-check the watcher on the events that can actually invalidate it — scope change, wake from sleep, didBecomeActive — and let the free-space read happen when the panel opens, where updateFreeSpaceIfNeeded() already has a 2-second cache.
Sequence
Suggested order
Ordered by user-visible impact per unit of risk. The first two are small diffs that change how the app feels; the correctness fixes follow because they need regression coverage.

Split the cache generation counter
A separate subcategoryCacheGeneration, bumped only inside the invalidation branch. This alone stops the drilldown reloading on every navigation, and it is roughly a ten-line change.

CACHE-01

Stop tearing down the panel's view tree
Keep the hosting view installed, or at minimum move the per-open bootstrap behind a launch-scoped flag. Removes the second half of the reload, plus the icon and scroll-state churn.

CACHE-02, PERF-03

Fix the path-lookup collation mismatch
With a regression that scans, renames a file changing only its case, and rescans. This is a permanent-failure path and the best lead on the documented retry loop.

SCAN-02, SCAN-03

Verify the feedback endpoint, then make it degrade gracefully
Probe it, add the mailto fallback to every error branch, and stop requiring diagnostics. Cheap, and it is how every other finding on this list reaches you from real testers.

FB-01, FB-02

Bound the scan producer
Real backpressure between FTS and the DB writer. Independent of the rest and testable with the existing headless stress harness.

SCAN-01

Make refresh mean something
Give the empty-queue case real work and an outcome, expose refreshVisibleInventory(), and show the next-check countdown in the footer.

REF-01, REF-02, REF-04

Optimise the hot loops
Byte-wise classification, the top-N heap, off-main FSEvents classification, and the cache-group sort. The largest CPU win, but also the largest diff — worth doing after the structural fixes land.

PERF-01, PERF-02, PERF-05, CACHE-06

Precompute the working-set drilldown
A workingSetSubcategoryTotal table with per-owner cache groups, so the live path stops being the slow path. Removes CACHE-03, CACHE-05 and CACHE-07 together.

CACHE-03, CACHE-05, CACHE-07

Settle the settings surface
Add the rescan-interval picker and an ignore list, fix the login-item state, and delete the boundary config and dead view models.

SET-01 – SET-06

Static review — no build or test run was performed (this environment is Linux; Prunr requires Xcode).
All line references are against c7fb29f on claude/app-performance-feature-review-odern6.
FB-01 liveness is unconfirmed: outbound HTTPS to prunr-web.vercel.app is blocked here.
