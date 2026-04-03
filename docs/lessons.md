# Lessons

- Audit fixes must include the integration path, not just the lower-level service behavior. If a service can return an escalation signal like `needsFullScan`, verify the caller actually handles it end-to-end.
