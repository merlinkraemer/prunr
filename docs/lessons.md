# Lessons

- Audit fixes must include the integration path, not just the lower-level service behavior. If a service can return an escalation signal like `needsFullScan`, verify the caller actually handles it end-to-end.
- Permission gating for macOS scanning must be validated against the protected locations the product actually touches, not a single surrogate probe like the TCC database. If scan-time prompts still appear, the onboarding permission state is wrong.
