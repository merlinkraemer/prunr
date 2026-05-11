# Lessons

- Audit fixes must include the integration path, not just the lower-level service behavior. If a service can return an escalation signal like `needsFullScan`, verify the caller actually handles it end-to-end.
- Permission gating for macOS scanning must be validated against the protected locations the product actually touches, not a single surrogate probe like the TCC database. If scan-time prompts still appear, the onboarding permission state is wrong.
- On macOS, removing explicit permission probes is not enough. Startup watchers and any background filesystem monitors must also stay disabled until onboarding is complete and a real baseline exists, or the app will still trigger protected-folder prompts on launch.
- For UI affordance fixes, verify the exact user-triggered runtime path. Removing one trigger is not enough if the shared downstream path can still escalate into the old behavior, and shape-level gestures are less reliable than explicit button interactions in dense SwiftUI layouts.
- A stable soak is not enough for scan-pipeline validation. Always include a functional freshness check that creates or modifies a file after the baseline and proves the working set, category totals, and UI update.
