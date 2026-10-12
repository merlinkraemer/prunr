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

extension UnitKind {
    static let photosLibrary = UnitKind(rawValue: "photos-library")
    static let icloudDrive = UnitKind(rawValue: "icloud-drive")
    static let icloudContainer = UnitKind(rawValue: "icloud-container")
    static let fcpLibrary = UnitKind(rawValue: "fcp-library")
    static let fcpRender = UnitKind(rawValue: "fcp-render")
    static let abletonProject = UnitKind(rawValue: "ableton-project")
    static let abletonLibrary = UnitKind(rawValue: "ableton-library")
}

extension UnitRules {
    /// Order matters: the first rule that resolves a path wins.
    static let media: [UnitRule] = [
        photosLibraryRule,
        fcpRenderRule,
        fcpLibraryRule,
        icloudDriveRule,
        icloudContainerRule,
        abletonLibraryRule,
        abletonProjectFolderRule,
        abletonProjectFileRule
    ]

    // MARK: Photos

    /// `<X>.photoslibrary` (bundle, anywhere) → "Photos library", "Photos library · X" for custom names.
    static let photosLibraryRule = UnitRule(
        kind: .photosLibrary,
        resolve: { path in
            mediaBundleRoot(path, suffix: ".photoslibrary")
        },
        name: { root in
            let stem = mediaStem(root.components.last, suffix: ".photoslibrary")
            guard let stem, !["photos library", "photos"].contains(stem.lowercased()) else {
                return UnitName(title: "Photos library", category: .mediaAndDocuments, icon: .photos)
            }
            return UnitName(title: "Photos library · \(stem)", category: .mediaAndDocuments, icon: .photos)
        }
    )

    // MARK: Final Cut Pro

    /// Render and cache folders inside a library are their own unit so the
    /// disposable part reads as "render files". Root: the folder itself.
    static let fcpRenderRule = UnitRule(
        kind: .fcpRender,
        resolve: { path in
            let lower = path.components.map { $0.lowercased() }
            guard let bundle = lower.firstIndex(where: { $0.hasSuffix(".fcpbundle") }) else { return nil }
            guard let folder = lower[(bundle + 1)...].firstIndex(where: { $0 == "render files" || $0 == "cache" }) else {
                return nil
            }
            return path.root(depth: folder + 1)
        },
        name: { root in
            let lower = root.components.map { $0.lowercased() }
            guard let bundle = lower.firstIndex(where: { $0.hasSuffix(".fcpbundle") }),
                  let library = mediaStem(root.components[bundle], suffix: ".fcpbundle") else { return nil }
            let event = root.components.count - bundle >= 3 ? UnitNamer.displayComponent(root.components[bundle + 1]) : nil
            return UnitName(
                title: "Final Cut Pro render files · \(library)", detail: event, category: .mediaAndDocuments, icon: .finalCutPro
            )
        }
    )

    /// `<X>.fcpbundle` → "Final Cut Pro library · X", bundle as root.
    static let fcpLibraryRule = UnitRule(
        kind: .fcpLibrary,
        resolve: { path in
            mediaBundleRoot(path, suffix: ".fcpbundle")
        },
        name: { root in
            guard let library = mediaStem(root.components.last, suffix: ".fcpbundle") else {
                return UnitName(title: "Final Cut Pro library", category: .mediaAndDocuments, icon: .finalCutPro)
            }
            return UnitName(title: "Final Cut Pro library · \(library)", category: .mediaAndDocuments, icon: .finalCutPro)
        }
    )

    // MARK: iCloud

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/<top>` → "iCloud Drive · top".
    static let icloudDriveRule = UnitRule(
        kind: .icloudDrive,
        resolve: { path in
            guard let relative = path.lowercasedRelative, mobileDocumentsContainer(relative) == "com~apple~clouddocs" else {
                return nil
            }
            return path.homeRoot(depth: relative.count >= 4 ? 4 : 3)
        },
        name: { root in
            guard let relative = root.relative, relative.count >= 4,
                  let top = UnitNamer.displayComponent(relative[3]) else {
                return UnitName(title: "iCloud Drive", category: .mediaAndDocuments)
            }
            return UnitName(title: "iCloud Drive · \(top)", category: .mediaAndDocuments)
        }
    )

    /// Any other `~/Library/Mobile Documents/<container>` → "<App> in iCloud".
    static let icloudContainerRule = UnitRule(
        kind: .icloudContainer,
        resolve: { path in
            guard let relative = path.lowercasedRelative, let container = mobileDocumentsContainer(relative),
                  container != "com~apple~clouddocs" else { return nil }
            return path.homeRoot(depth: 3)
        },
        name: { root in
            guard let relative = root.relative, relative.count >= 3 else { return nil }
            return UnitName(
                title: "\(icloudContainerAppName(relative[2])) in iCloud",
                category: .mediaAndDocuments,
                icon: .icloudContainer(relative[2])
            )
        }
    )

    // MARK: Ableton

    /// `.../Ableton/User Library` (and Factory Packs) → "Ableton library".
    static let abletonLibraryRule = UnitRule(
        kind: .abletonLibrary,
        resolve: { path in
            let lower = path.components.map { $0.lowercased() }
            guard let index = lower.indices.dropFirst().first(where: {
                (lower[$0] == "user library" || lower[$0] == "factory packs") && lower[$0 - 1] == "ableton"
            }) else { return nil }
            return path.root(depth: index + 1)
        },
        name: { root in
            let isPacks = root.components.last?.lowercased() == "factory packs"
            return UnitName(
                title: "Ableton library",
                detail: isPacks ? "factory packs" : nil,
                category: .audioProduction,
                icon: .abletonLive
            )
        }
    )

    /// A folder named "<X> Project" → "Ableton project · X".
    static let abletonProjectFolderRule = UnitRule(
        kind: .abletonProject,
        resolve: { path in
            guard let index = path.components.indices.first(where: { index in
                guard let home = path.homeDepth, index >= home || path.homeDepth == nil else { return false }
                return abletonProjectName(path.components[index]) != nil
            }) else { return nil }
            return path.root(depth: index + 1)
        },
        name: abletonProjectName(for:)
    )

    /// The parent folder of a `.als` set → the same unit as its project folder.
    static let abletonProjectFileRule = UnitRule(
        kind: .abletonProject,
        resolve: { path in
            guard path.components.last?.lowercased().hasSuffix(".als") == true,
                  path.components.count - 1 > (path.homeDepth ?? 0) else { return nil }
            return path.root(depth: path.components.count - 1)
        },
        name: abletonProjectName(for:)
    )

    private static func abletonProjectName(for root: UnitPath) -> UnitName? {
        guard let last = root.components.last else { return nil }
        let name = abletonProjectName(last) ?? UnitNamer.displayComponent(last)
        guard let name else { return nil }
        return UnitName(title: "Ableton project · \(name)", category: .audioProduction, icon: .abletonLive)
    }

    /// "Song Project" → "Song"; nil when the component is not a project folder.
    private static func abletonProjectName(_ component: String) -> String? {
        guard component.lowercased().hasSuffix(" project") else { return nil }
        let stem = String(component.dropLast(" project".count))
        return UnitNamer.displayComponent(stem)
    }

    // MARK: Helpers

    /// Root of the first component ending in `suffix` (bundle directory, anywhere).
    private static func mediaBundleRoot(_ path: UnitPath, suffix: String) -> String? {
        guard let index = path.components.firstIndex(where: { $0.lowercased().hasSuffix(suffix) }) else { return nil }
        return path.root(depth: index + 1)
    }

    private static func mediaStem(_ component: String?, suffix: String) -> String? {
        guard let component, component.lowercased().hasSuffix(suffix) else { return nil }
        return UnitNamer.displayComponent(String(component.dropLast(suffix.count)))
    }

    /// Lowercased container folder name when `relative` is inside `Library/Mobile Documents/<container>`.
    private static func mobileDocumentsContainer(_ relative: [String]) -> String? {
        guard relative.count >= 3, relative[0] == "library", relative[1] == "mobile documents" else { return nil }
        return relative[2]
    }

    /// `iCloud~com~culturedcode~ThingsMac` → "ThingsMac", `com~apple~Pages` → "Pages",
    /// `27N4MQEA55~pro~writer` → "Writer".
    private static func icloudContainerAppName(_ container: String) -> String {
        let last = container.split(separator: "~").last.map(String.init) ?? container
        let cleaned = UnitNamer.displayComponent(last) ?? "App"
        return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }
}
