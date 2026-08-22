# Lessons

## Xcode toolchain gap: local 26.4 vs CI/runner 16.4 (2026-06-02)

**Symptom:** Code builds and ships fine locally but the GitHub `macos-15` runner
(Xcode 16.4) fails to compile it. CI (`ci.yml`) had been red on *every* run since
May 26 for this reason, masked because releases were cut locally.

**Root cause:** Returning a non-`Sendable` type (e.g. GRDB `[Row]`) directly out
of an `async` `dbPool.read { ... }` closure. The async `read` requires its result
be `Sendable`. Xcode 26.4's checker tolerates it; 16.4 rejects the overload and
infers the closure result as `()`, surfacing as cascade errors like
`value of tuple type '()' has no member 'count'`.

**Fix / rule:** Never hand a `Row` (or any non-`Sendable` value) across an async
`read`/`write` boundary. Map to a `Sendable` tuple/struct *inside* the closure:
`...read { db in try Row.fetchAll(...).map { (a: $0["a"] ?? "", b: $0["b"] ?? 0) } }`.
Every other read in `DatabaseManager.swift` already did this — the two that
didn't (plus one test) are what broke.

**Verify-on-26.4 caveat:** A clean local build on 26.4 does NOT prove CI passes.
For anything that must build on the runner, treat 16.4 as the target. Production
releases are built on the runner (Xcode 16.4) too — so this is also a shipped-
binary concern, not just CI.

## CI build/test must not require signing (2026-06-02)

The `ci.yml` Build And Test job ran `make build`/`make test` with automatic
signing, which fails on a runner with no certs ("No Mac Development signing
certificate"). A plain build/test needs no signed binary. The Makefile now takes
`XCODE_EXTRA_FLAGS`; CI sets `CODE_SIGNING_ALLOWED=NO`. Only the release workflow
imports signing certs.

## Remote-tester diagnostics must be self-serve, not `log show` (2026-06-03)

**Correction:** I first shipped CPU instrumentation as os_signpost + `Logger`
notices on a `com.prunr.perf` subsystem, with instructions to read it via
`log show`/`log stream`. The user rejected it: there's no way to pull logs off an
alpha tester's machine without hand-holding them through Terminal.

**Rule:** For a distributed app with non-technical testers, telemetry has to reach
you *without touching their machine*. Lowest-friction option that fits a handful
of testers: an in-app button that appends a snapshot to an on-disk file and
reveals it in Finder so they can send it (WhatsApp/email). No backend, no
Terminal. See `DiagnosticsReporter` (PerfSignpost.swift) → Settings →
Troubleshooting → "Generate Diagnostics Report"; file at
`~/Library/Logs/Prunr/diagnostics.log`. The file is dense/structured (pasted into
Claude), not human-pretty. Periodic 30-min window lines + a manual full snapshot
on button hit. CPU sampled via mach `thread_basic_info` every 20s.

## Hidden SwiftUI views are live views (2026-08-22)

**Symptom:** Hovering empty space highlighted an unrelated category, and the app
could keep doing unnecessary UI work while the panel was open.

**Root cause:** A zero-sized, transparent background used to pre-warm drilldown
branches permanently instantiated a second list tree. Its `onHover` handlers
shared state with the visible list, and hiding it did not remove its tracking
areas or rendering work.

**Rule:** Do not retain invisible duplicate SwiftUI trees for pre-warming. Any
warmup must be one-shot and removed before interaction; treat transparent or
zero-sized views as live until proven otherwise.
