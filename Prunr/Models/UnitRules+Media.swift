import Foundation

// Media and audio unit rules (slice s7): <X>.photoslibrary, iCloud Drive
// (~/Library/Mobile Documents), Final Cut Pro libraries (<X>.fcpbundle) and
// Ableton projects ("<X> Project" folders or the parent of an .als) plus the
// Ableton User Library.
//
// How to add a rule:
// - Declare its kind here: `extension UnitKind { static let photosLibrary = UnitKind(rawValue: "photos-library") }`.
//   The raw value is persisted in keys; never rename it after release.
// - Append a `UnitRule(kind:resolve:name:)` to `media`. Bundle units take the
//   bundle itself as root (`UnitPath.root(depth:)` up to the bundle component).
// - Names pass through `UnitNamer.sanitize`; test them with
//   `UnitNamer.containsForbiddenToken`.
//
// Order: this pack resolves after the developer pack, before the app pack.

extension UnitRules {
    static let media: [UnitRule] = []
}
