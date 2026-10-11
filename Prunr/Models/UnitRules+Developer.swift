import Foundation

// Developer unit rules (slice s5): Xcode DerivedData / Archives / DeviceSupport /
// CoreSimulator, Docker and Colima, the outermost node_modules, Python envs,
// build output, .git, package caches (~/.npm, ~/.gradle, ~/.cargo, ~/.m2,
// ~/.cache/<tool>) and model stores (~/.ollama/models, ~/.cache/huggingface).
//
// How to add a rule:
// - Declare its kind here: `extension UnitKind { static let xcodeBuild = UnitKind(rawValue: "xcode-build") }`.
//   The raw value is persisted in keys; never rename it after release.
// - Append a `UnitRule(kind:resolve:name:)` to `developer`. `resolve` returns the
//   unit root (build it with `UnitPath.homeRoot(depth:)` / `root(depth:)` so the
//   path's case is preserved) or nil. `name` names a root of that kind.
// - Names pass through `UnitNamer.sanitize`; test them with
//   `UnitNamer.containsForbiddenToken`.
//
// Order: this pack resolves after Trash and Downloads, before media and app rules.

extension UnitRules {
    static let developer: [UnitRule] = []
}
