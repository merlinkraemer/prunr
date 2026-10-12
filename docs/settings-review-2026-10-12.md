# R8 Settings review (main @ 7cd0350, s13 merged; Settings files unchanged by the merge)

Window: AppKit NSWindow + NSToolbar preference style, 520x480, tabs General / Scan Scope / Troubleshooting (SettingsView.swift, SettingsWindowController.swift).

## Every control today -> verdict
| Tab | Control | Verdict |
|---|---|---|
| General | Launch Prunr at Login (switch) | Keep |
| General | Check for Updates... (only if Sparkle on) | Keep; add "Check automatically" switch (SUEnableAutomaticChecks is plist-only today) and show version + last check in the same row |
| General | Version footer | Move into Updates row; Option-click it toggles dev mode |
| Scan Scope | Scan-running lock banner (window-wide) | Keep, but only on the folder tab |
| Scan Scope | Primary Scan Folder + Change | Change: rename "Folder", show "Home" + path; main screen copy says "home folder" (ChangeFeedStateView.dayOneText, "Not watched") so either make that copy use the folder name or warn that a non-home folder breaks it |
| Scan Scope | Scan Coverage ("X outside scan scope") | Change: rename "Not watched", same number as the Categories last row |
| Scan Scope | Scan Access + Open Privacy Settings | Keep; plain "Full Disk Access: Granted / Needed" row |
| Scan Scope | Additional Locations (common path toggles) | Cut: every preset lives under ~ (TrackedPath.swift), so with home as the folder isCoveredByMainScope hides all of them; the box only ever says "already included" |
| Scan Scope | Pending-apply bar + "Apply and Reset Snapshots" dialog | Keep the mechanism, change copy: "Changing the folder starts your history over." (no "snapshots"/"baseline") |
| Troubleshooting | Send Feedback (text, email, send) | Keep; own tab "Feedback" (context menu already deep-links to it) |
| Troubleshooting | Generate Diagnostics Report | Keep in Feedback as a secondary link; auto-attached to feedback anyway |
| Troubleshooting | Compact Database | Move to Developer (auto-maintenance covers users) |
| Troubleshooting | Reset Prunr Data | Move to General > History as "Start Over..." |

Not in UI, store-only (fine, keep hidden):
- categoryHistoryRetentionDays: clamped to >= 30; the 30-day window is fixed by GrowthJournalService. Show it as a fact ("keeps 30 days"), never a picker.
- automaticFullScanIntervalHours: adaptive after first scan. No UI needed; dev tab shows last full scan.
- customBoundaries / customScanIgnores / disabledPaths / customTrackedPaths: dead API with no UI. Candidate for removal later, not now.
- 1 GB row rule: a product constant, not a setting. Do not expose.

## Missing
- Nothing user-critical. Small: "Check for updates automatically", and "Watching since <date>" (HistoryStart) so the 30-day promise is visible.
- No notifications exist, so no notification settings needed.

## Structure
Three tabs is right for a menu bar utility; macOS convention is General first, About usually in the app menu (menu bar apps put version in General). Proposed:
1. General: Startup, Updates (auto-check, version, Check Now), History (30 days, watching since, Start Over...)
2. Watching: Folder (Home + Change...), Full Disk Access, Not watched
3. Feedback: message, email, Send; diagnostics link
4. Developer (hidden unless dev mode)
Marketing renderer (MarketingSettingsPreview) hardcodes the old three tabs and "Prunr alpha · Version 0.1.5"; update it with any tab change.
Also: context menu "Troubleshooting > Send Feedback..." submenu with one item -> flatten to "Send Feedback...". Window width 520 -> keep or widen to 560 for the dev segmented control.

## Developer tab
Enable: UserDefaults bool `devMode` in com.prunr.app. Free routes: `defaults write com.prunr.app devMode -bool YES`, launch arg `-devMode YES` (argument domain), on by default in DEBUG, Option-click the version in General toggles it. Tab item appears/disappears live (toolbar rebuild).
| Item | Exists today? |
|---|---|
| Panel preview: Onboarding | Partly: setupOnboardingView renders when manager.noBaseline; needs a preview override |
| Panel preview: Scanning card | Partly: manualScanLoadingView when isLoading && !isAutoScanning; needs override |
| Panel preview: Day one | Partly: ChangeFeedView .loaded where feed.isDayOne; needs fake feed |
| Panel preview: Error | Partly: ChangeFeedView .failed + manager.errorMessage; needs override |
| Panel preview: Sample data | Yes: MenuBarManager.applyScreenshotPreviewContent() + MarketingSample (used by render-screenshot) |
| Reset history start | Yes: HistoryStart.reset() (GrowthJournalService.swift) |
| Force full scan | Yes: footer refresh / loadInventory(isAutomatic: false) |
| Compact database | Yes: DatabaseCleanupService.compactDatabaseNow() |
| Open database folder | No UI; path is ~/Library/Application Support/Prunr/prunr.db |
| Copy diagnostics | Partly: generateDiagnosticsReport (reveals file) / prepareDiagnosticsAttachment (Data) |
| Perf log toggle | No: DiagnosticsReporter + com.prunr.perf always on; toggle would gate the 60 s window log |
| Force FDA denied | Yes, DEBUG-only key debugForceFDADenied (PermissionsService) |
Preview states should be one segmented "Show in panel" override (Live/Onboarding/Scanning/Day one/Error/Sample), not five buttons; never writes the DB.

Mockups: canvas/project/Z1-settings-general, Z2-settings-watching, Z3-settings-developer (.dc.html), rendered headless OK at 640x480.
