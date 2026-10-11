# R4 Communication model: how Prunr tells a user what ate their storage

Inputs: r1-product, r1-current-ui, r1-patterns, r2-designer-a/b, r3-critic, PDN (product-definition-notes-2026-09-06), GF, PRD, Swift sources (GrowthJournalService, DatabaseManager schema, GrowthCategory, BoundaryConfig, BaselineService), and the owner's screenshot of the live popover.

Real numbers from the screenshot (used throughout): Other 521.4, Audio Production 452.8, Caches & System 229.2, Developer 182.8, Media & Documents 140.0, Applications 32.8, Downloads 27.2, Outside Scan Scope 122.3 (GB). Tracked ~1.59 TB, used ~1.71 TB, so a 2 TB disk with roughly 250-300 GB free. "7-day change 0 MB" shown while scanning. Seen directly in the image: an 8-segment colour bar with no legend and no free-space number (the grey tail is roughly 15% of the bar, consistent with ~300 GB free of 2 TB); the free-space figure is nowhere on the screen; a 200 pt empty gap between Downloads and "Outside Scan Scope"; footer "Scanning..." is the only state text; nothing on screen names a time, an app, a project or a folder. The screen is a size list by classifier bucket, i.e. a legend-less DaisyDisk.

---

## 1. Why the six mockups missed

Shared assumption: all six take the existing pipeline's output (8 category buckets x one fixed 7-day net) as given and argue only about what sits on top of it: a sentence, a culprit, a runway, a size list, a glyph, two sentences. They are six headlines for the same table. The screenshot shows what that table says on a real Mac: "Other 521 GB", "Caches & System 229 GB", "7-day change 0 MB". No layout can turn those labels into an answer, because the words are the problem, not the arrangement.

Three contributing mistakes, all downstream of that assumption:
- Wrong unit. Category is a classifier's unit, not a person's. "Other" is 33% of tracked bytes and means "the rule table gave up". "Caches & System" is where the app's own vocabulary leaks out. Nobody remembers doing something "in Caches & System".
- No time on screen. The product's one claim is change over time, and the only time word in any mockup is the constant label "last 7 days". A net number over a window says *how much*, never *when*. The owner's question "what ate my storage" is answered by an event ("Tuesday, Docker, 31 GB"), and none of the six has a slot for an event.
- Two jobs collapsed into one list. "What grew" (diagnosis) and "what is big" (where to free space; PDN: you delete old things, not the thing that grew) were forced into one ranking, so every mockup had to choose a sort order and lost half the audience. M1 added a sort toggle; M4 added badges; both are symptoms.

Most convincing single explanation: the mockups were answers to "which number goes in the headline" (the critic's D-A), but the open question was "in what words does a user recognise their own past". Until the unit is something a user can recognise (an app, an artifact, a project folder, a download), the headline is decoration on an unreadable list. The critic sensed it ("'Xcode' is only honest if classified") and then designed around the limitation instead of naming it as the blocker.

---

## 2. The user's mental model

What people remember when storage disappears is episodic, not categorical. They remember:
- an action: "I pulled a Docker image", "I built that app", "I downloaded a season", "I exported the final cut", "Photoshop crashed";
- an actor: the app that did it (Xcode, Docker, Ableton, a browser) or the project it was for;
- a place, vaguely: "Downloads", "that project folder", "somewhere in Library";
- a time, roughly: "Tuesday", "last week before the holiday", "when I was working on X".

They do not remember file types, categories, or exact paths. Memory is indexed by (what I was doing, when). The cue that makes recognition fire (the unanswered PDN question) is a *name they would have typed or clicked* plus a *date*: "Prunr DerivedData, Tue" or "ubuntu-24.iso in Downloads, Mon".

Candidate units, judged on recognisability, attributability from path data, and size of the long tail:
- Category: never recognisable (see Other/Caches). Only honest as a colour, not as a row. Reject as unit.
- File: too fine; growth of one unit is thousands of files (DerivedData, node_modules). A file is a leaf the user reaches on the way to Finder, not the explanation. Reject as unit, keep as drill target.
- Folder/location: recognisable when it is a named place (~/Downloads, ~/Movies/Footage 2026, ~/dev/prunr) and unrecognisable when it is a path under Library. Good fallback, bad primary.
- App: recognisable for caches and artifacts (Xcode, Docker, Chrome, Spotify). Already partly inferable (cache bundle-id table, Docker.raw, DerivedData). Not applicable to user documents.
- Project: the best cue for developers (DerivedData/Prunr-abc, ~/dev/prunr/node_modules) and audio people (an .als project folder). Inferable for artifacts under a boundary folder; not for loose documents.
- Episode/event: (when, which unit, how many bytes). This is the memory index itself.

Right unit: the **episode**, named by a **recognisable unit** (app or artifact + project where known, else a named folder). Why: the user's own memory is stored that way; it carries time (Prunr's only differentiator) for free; it is the only unit under which the 7-day net stops lying (a +8/-8 cache shows as two episodes or none, never as a silent zero); and it degrades gracefully (an unnamed episode is still "Tue, +6 GB in ~/Documents/Archive"). Categories survive only as icon/colour and as a drill group when nothing better is known.

Consequence for the two jobs: episodes answer "what ate it". "What is big" stays a separate, size-ranked list of the same recognisable units (not categories). The two lists share names, so the user learns one vocabulary.

---

## 3. Timeframe

Options and how each behaves:

| Option | Day one | After 2-week holiday | After a cleanup | Flaw |
|---|---|---|---|---|
| Fixed 7 days (current) | 0 MB for 7 days; looks broken (screenshot) | the jump 12 days ago is gone; "nothing changed" is false to the user | -40 GB nets against growth; headline reads as "nothing" | window chosen for reporting, not for where the answer is |
| Since last opened | same as day one | correct (holiday growth shows) | correct | opened twice a day = empty; passive glancer sees nothing; unbounded if never opened; two users' screens disagree |
| Since disk was last fine | needs a "fine" threshold; undefined on day one | works if threshold set | resets itself | threshold is a guess (critic on B4); "fine" is a judgement |
| Anchored on the big jump | nothing to anchor | correct | shows the cleanup as the biggest jump (useful) | needs a jump detector; fails when growth is a slow drip (then a window total is right) |
| Adaptive (grow window until there is something to say) | sizes | correct | correct | invisible logic; the label changes every open; the critic rejected this class |

Recommendation: **episodes over the full retention window (30 days), newest first, plus one fixed 7-day net total as the summary number.** Not a window choice but a lookback: the window answers "how much", the episode list answers "when and what". Concretely:
- Lookback for episodes = retention (30 d). Shown with a relative day ("Tue", "12 days ago"). The holiday case is solved because the jump is simply in the list with its date; nothing adaptive is needed.
- Summary number stays "last 7 days: +X GB" (PRD contract, constant label). If the only large episode is older than 7 days, the summary says so in the same line: "+0.4 GB in 7 days. Biggest recent change: 12 days ago, Docker +31 GB."
- Day one: no episodes, no total. Line: "Watching since today. Changes show from tomorrow." Then the size list. Never "0 MB"; never a greyed category list (issue #32).
- After a cleanup: shrink episodes are listed in grey ("Yesterday, -38 GB, Trash emptied"); the 7-day net is still signed and sums. The user sees why the net is small.
- No user-set anchor, no period picker, no "since last opened". A new scan or an app restart must not move any anchor.

---

## 4. Detail

Principle: the screen states facts that sum, and it states them in the order the user would ask. It never asks the user to interpret a threshold, so every threshold is a presentation rule applied silently and consistently.

- How many: at most 3 episodes on the first screen, then one collapsed line. Three is the limit of what a 5-second read retains and what 320 pt holds with names and dates.
- Mention threshold for an episode: max(1 GB, 2% of the 7-day gross change). Below that, it is tail. (1 GB on a 2 TB disk is 0.05% of capacity; a lower floor produces churn noise from caches.) The 1 MiB floor stays as the floor for rows in drill views only.
- Long tail: one line, always present if non-zero: "and 2.3 GB in 14 smaller changes". It carries the remainder so the three episodes plus the tail equal the window net.
- Noise: minute buckets are grouped into episodes by (unit, gap < 30 min); episodes of the same unit on the same calendar day merge. Spotify/browser caches then become one small daily episode each and fall under the threshold.
- Shrinkage: shown as episodes only when they pass the same threshold, in grey, no arrow celebration. Small shrinkage is tail. The net is signed everywhere (PRD).
- Caches that grow and shrink (net vs gross): per unit, report **net over the window**. Report gross only in one case: when a unit's gross exceeds 5x its net and the gross alone would have ranked it in the top 3. Then one line, in the tail position: "Xcode build files moved 30 GB back and forth (net +1 GB)". This is the only place churn is mentioned; it exists so a developer whose disk filled and emptied twice does not see "nothing changed".
- Unattributed bytes, two kinds, two lines, both muted, both only when non-zero:
  1. Outside the watched folders: "Not watched: 122 GB" (today's "Outside Scan Scope"). Never "system", never "reclaimable".
  2. Free-space change the journal did not see: if |free-space delta over 7 d| differs from the tracked net by more than 15%, one line "Free space moved 9 GB more than the folders Prunr watches". This is the honest version of M3's two-line reconciliation; it appears only when it matters.
- Never on the first screen: percentages of the total, rates, forecasts, "stable"/"healthy" adjectives, counts of files, the scan's current path, pending-change narration.
- Honest-without-thinking rules: (a) every number on screen is either a size, a signed change, or a date; (b) the three episodes + tail = the 7-day net, and the size list + Not watched = used bytes; (c) unknown is "--" or a sentence, never 0; (d) during a scan, the last known answer stays on screen with "Updating..." in the footer, instead of "0 MB" replacing the answer.

---

## 5. Grouping

Order of preference for a unit's name:
1. **App or artifact + project** when a rule knows both: "Xcode build files - Prunr", "node_modules - acme-dashboard", "Docker images", "Chrome cache", "Ableton project - Live Set 12".
2. **App or artifact alone**: "Xcode build files", "Python environment", "Homebrew".
3. **Named place**: the folder under home that a user would recognise: "Downloads", "Movies/Footage 2026", "Documents/Archive". Two path components below home, more only if the top one is Library (then show the app folder: "Library/Application Support/Slack").
4. **Category** only as an icon/colour and as the grouping in the size drill; never as a row label on the first screen. "Other" as a label is retired; its contents are shown as named places.

File type is never a unit: users do not remember "I made 40 GB of .mov"; they remember the export. Types are a filter at most.

What path rules can infer honestly (all from existing classify/boundary logic plus one parent lookup):
- Artifact kind from a boundary folder name: DerivedData, node_modules, .git, .venv/venv/.conda, target, build/.build/dist, .cache, vendor, Docker.raw/.colima, Caches/<bundle id>. All already in BoundaryConfig/GrowthCategory.
- App from a bundle id under Library (table exists, ~35 entries; the fallback "last dotted component, de-hyphenated" is already there).
- Project from the parent of a boundary folder (node_modules, .venv, target, build): parent folder name. For DerivedData: the child folder name before the hash ("Prunr-abcdef" -> "Prunr"). For Docker: no project; say "Docker".
- Download name: the largest single file in the episode when it is >50% of the episode ("ubuntu-24.iso").
- Audio: a folder containing an .als/.logicx/.ptx is a project; name = folder.
- Photos library / iMovie library bundles: name = bundle name.

What rules cannot infer and must not claim: which project a loose document belongs to; whether anything is unused, abandoned, safe, or regenerable; cause ("because you installed"). Wording stays "grew in / appeared in / emptied".

How far a rule table goes: on a developer Mac the artifact rules cover most of the growth bytes because growth clusters in a few boundary folders; on the screenshot's Mac the *size* side is dominated by Audio (453 GB) and Other (521 GB), which the fallback (named places) handles without any rule. Estimated: a table of ~40 artifact rules + bundle ids + the named-place fallback leaves nothing labelled "Other"; what remains unexplained is a path the user can at least read. That is the bar: every row is a name the user could type into Finder.

Fallback naming rules: never a category word; never a hash; never a path longer than two components (middle-truncate the start, keep the last component whole); for a folder with no better name, show the folder name and its parent ("Archive in Documents"). If a unit is a boundary folder of an unknown kind, name it by its folder ("target in rust-playground").

Dedup: a unit is the boundary folder; bytes are counted once at the boundary (RM:62). A project row is a sum of its artifact units and is only shown in the size drill, not on the first screen.

---

## 6. The time primitive

Candidates, judged on "conveys change over time" with the fewest elements:
- Window total ("+14 GB, last 7 days"): one number; conveys *how much* only. Zero sense of when. Insufficient alone.
- List of jumps ("Tue 14:20, +31 GB, Docker"): three fields per line, each a thing the user remembers (when, how much, what). Conveys change over time by construction, sorts by time or size, degrades to one line, fits in text. This is the memory index rendered.
- Free-space line with markers: needs a chart, an axis, hover, and the free-space history is sampled per scan (24 h) so the markers would be coarse and the line would swing with purgeable space. More elements, less honesty.
- Short story ("Mostly Docker on Tuesday, then Xcode yesterday"): the jump list in prose. Reads well, but prose hides the arithmetic and invites causal words. Use only as the single summary line above the list.

Simplest form that still conveys change over time: **one summary line + up to three dated jumps + one tail line**, where each jump is `relative day, signed GB, name`. Time of day only when within the last 48 h ("Tue 14:20"), otherwise the day ("12 days ago"). No chart. The size list underneath is undated (sizes are "now").

---

## 7. Exact wording

Illustrative figures on the screenshot's Mac (2 TB disk; free-space value is invented).

(a) Developer whose disk just filled up (7-day net +48 GB, 19 GB free):

```
19 GB free of 2 TB
Last 7 days: 48 GB more used.

Tue 14:20   +31 GB   Docker images
Yesterday    +9 GB   Xcode build files - Prunr
Mon          +5 GB   Downloads (ubuntu-24.iso)
             +3 GB   in 11 smaller changes

Free space moved 6 GB more than the folders Prunr watches.
[Show Docker images in Finder]      Biggest places >
```
Sentence form of the same (for the menu bar tooltip or a notification later): "48 GB more used this week. Most of it Docker images on Tuesday (+31 GB)."

(b) Calm week (net +0.4 GB, 290 GB free):

```
290 GB free of 2 TB
Last 7 days: nothing notable changed (+0.4 GB).

Biggest places right now
Ableton projects          453 GB
Movies / Footage 2026     310 GB
Documents / Archive       120 GB
Xcode build files          95 GB
... and 6 more
Not watched: 122 GB
```
No "stable", no check mark, no green. The calm line is the whole verdict; the size list fills the space so the screen is never empty and the second job is one glance away.

(c) Day one, no history (first scan finished):

```
290 GB free of 2 TB
Watching your home folder since today. Changes will show here from tomorrow.

Biggest places right now
Ableton projects          453 GB
Movies / Footage 2026     310 GB
...
Not watched: 122 GB
```
While the first scan runs: "Scanning your home folder (about 5 minutes left). Biggest places so far:" with the partial list, never "0 MB". No "Tracking changes" footer vocabulary; the sentence carries the state.

Common wording rules: verbs are "more used / less used / grew in / appeared in / emptied"; never "because", "safe", "junk", "reclaimable", "stable", "healthy". Numbers: whole GB above 10, one decimal below, MB below 1 GB. Dates: "Today 14:20", "Yesterday", weekday within 7 days, "12 days ago" beyond.

---

## 8. Data: has vs needs

Has (view-only or light query):
- `growthJournalBucket`: per-minute signed deltaBytes per (trackedPath, category, subcategory). Gives the 7-day net, per-subcategory nets, and the *time* of change at minute resolution. Enough for "when" at category/subcategory grain; not enough to name a unit.
- `workingSetEntry` / `paths` / `pathClassification`: current size per path, category per path. Enough for the size list by named place with a parent-aggregation query (roadmap s3; not built).
- `snapshot.freeBytes`: free-space history per scan (24 h grain). Enough for the reconciliation line, too coarse for anything finer.
- `BoundaryConfig`, `GrowthCategory.classify`, cache bundle-id table, `cacheApplicationKey`: the naming rules exist for artifacts and app caches.
- `GrowthItem(path, growthBytes)` via BaselineService: per-file growth within a category, so a top-grower by path is derivable for a window, at a cost (it walks files).
- Retention 30 d (journal and category snapshots).

Needs:
- Cheap (schema add + query): a **unit id on the journal bucket** (the boundary folder or named place the path resolved to at write time). One extra column, resolved by the same classifier that already runs on the write path. Without it, episodes can only be named at subcategory grain ("build artifacts", not "Xcode build files - Prunr"). This is the single most valuable change and is small.
- Cheap: **episode grouping** = one query over buckets by (unit, gap < 30 min, same day). No new storage.
- Cheap: **project name from parent** for boundary folders and the DerivedData name split. Pure string rules.
- Cheap: **hourly statfs sample** stored with a timestamp (a timer and one small table), so the free-space comparison is 7-day aligned and not per-scan.
- Medium: **size list by named place** (aggregate workingSetEntry by boundary/named-place ancestor, dedup at boundary). Roadmap s3; needed for day one and for retiring "Other".
- Medium: **largest file in an episode** (for "Downloads (ubuntu-24.iso)"); needs the per-path deltas of that episode, which the bucket table does not keep; either derive from working set diffs at episode close or skip the parenthesis for v1.
- Expensive / out: per-file growth history, install/last-used/causal data, app-level attribution for loose documents, notifications, forecasts. None are needed for the model above.

Trust prerequisites (NW "fix the number first"): the double-counted journal, partial scans rendered as complete, and failures rendered as empty lists must be fixed before any episode is printed in prose; a wrong sentence costs more than a wrong bar.

---

## 9. Recommendation

1. Unit: the episode (when, how much, which recognisable unit); categories demoted to icons.
2. Names: app/artifact + project from path rules; else a named place under home; "Other" and "Caches & System" never appear as labels.
3. Timeframe: episodes over the 30-day retention, newest first, with a relative date; one fixed "last 7 days" signed net as the summary line. No picker, no anchor, no "since opened".
4. Detail: max 3 episodes, threshold max(1 GB, 2% of gross), one tail line that makes the sum exact, shrinkage in grey under the same rule, churn mentioned only when gross > 5x net and top-3-worthy.
5. Unattributed: "Not watched: X GB" and, only when >15% apart, "Free space moved X GB more than the watched folders". Both muted, both exact.
6. Time primitive: summary line + dated jump list. No chart, no rate, no runway.
7. The second job (what is big) is the same vocabulary, size-ranked, under the episodes; on calm weeks and on day one it is the body of the screen.
8. Fallbacks: day one = "Watching since today" + sizes; calm = "nothing notable (+0.4 GB)" + sizes; scanning = last answer stays, footer says updating; unknown = "--".
9. Action: one Finder reveal on the top episode; drill = the unit's folder, not a 500-file list.
10. Data: add a unit id to the journal buckets and an episode query first; size-by-named-place second; everything else is wording.

Questions only the owner can decide:

Q1. Do categories survive at all, or are they replaced by named places?
  a. Replace: first screen and drill use named units only; categories become icons/colours. (rec; retires "Other 521 GB")
  b. Keep as the drill grouping: first screen uses units, the size drill groups them by category.
  c. Keep as today, add units only to the episode list.

Q2. Lookback for episodes: 30 days (retention) or the fixed 7 days?
  a. 30 days for episodes, 7-day net as the summary. (rec; solves the holiday case, keeps the PRD number)
  b. 7 days everywhere, accept "nothing changed" after a holiday.
  c. 7 days, but extend to 30 only when the 7-day list is empty (adaptive; rejected by the critic for invisible logic).

Q3. What fills the screen on a calm week and on day one?
  a. The size-ranked named-place list, under the one-line verdict. (rec; one screen, two jobs, never empty)
  b. Only the verdict line and free space; sizes behind a "Biggest places" link. (quietest; day one is nearly empty)
  c. The size list only, with the verdict as a small badge (M4 style; loses the time story on first view).
