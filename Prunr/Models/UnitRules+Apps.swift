import Foundation

// App and cache unit rules (slice s6): ~/Library/Caches/<id> → "<App> cache",
// Containers and Group Containers → "<App> data", Application Support, Steam
// games, Mail, Messages attachments and ~/Library/CloudStorage providers.
//
// How to add a rule:
// - Declare its kind here: `extension UnitKind { static let appCache = UnitKind(rawValue: "app-cache") }`.
//   The raw value is persisted in keys; never rename it after release.
// - Append a `UnitRule(kind:resolve:name:)` to `apps`. `resolve` returns the unit
//   root or nil; `name` names a root of that kind.
// - To only rename an existing core unit without changing its key (so no history
//   splits), add a name-only rule of that core kind, e.g.
//   `UnitRule(kind: .library, name: { root in ... })`, returning nil for roots it
//   does not cover. Pack rules are asked before the core namer.
// - `UnitNamer.appDisplayName(_:)` turns bundle ids into app names (via
//   `GrowthCategory.cacheApplicationDisplayName`).
//
// Order: this pack resolves after the developer and media packs, before the
// generic ~/Library and place fallbacks.

extension UnitRules {
    static let apps: [UnitRule] = []
}
