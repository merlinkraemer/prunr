import Foundation

// MARK: - Unit keys
//
// A "unit" is a place the user recognises: an app, a project, a library, a
// download or a named folder. Every journal change is stored under the key of
// the unit its path belongs to, and the screen lists one row per unit and day.
//
// Key format (persisted in the database, so it must stay stable across releases):
//
//     <kind>|<rootPath>
//
// - `kind` is a short lowercase identifier (`UnitKind.rawValue`, e.g. "download").
//   It never contains "|". Kinds are never renamed once released.
// - `rootPath` is the absolute path of the unit's root folder or file, with the
//   case of the incoming path preserved, "~" expanded, no trailing slash and no
//   empty or "." components. Everything after the first "|" is the root, so a
//   root may itself contain "|".
//
// Examples:
//     download|/Users/m/Downloads/ubuntu.iso
//     trash|/Users/m/.Trash
//     library|/Users/m/Library/Application Support/Google
//     place|/Users/m/Documents/Archive
//
// Names are NOT part of the key. `UnitNamer` computes them from the key at read
// time, so rule wording can change freely. Changing which root or kind a rule
// returns for an existing path does change keys: history inside the 30-day window
// then splits into two rows until the old key ages out. Treat that as a data change.

/// The kind part of a unit key. Rule packs add their own kinds in their own files
/// (`extension UnitKind { static let docker = UnitKind(rawValue: "docker") }`).
struct UnitKind: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The user's Trash (`~/.Trash`), one unit.
    static let trash = UnitKind(rawValue: "trash")
    /// One item directly inside `~/Downloads`.
    static let download = UnitKind(rawValue: "download")
    /// `~/Library/<Area>/<X>`, named "X data".
    static let library = UnitKind(rawValue: "library")
    /// Named-place fallback: the first two folders below home (or below `/`).
    static let place = UnitKind(rawValue: "place")
}

/// A parsed unit key. `rawValue` is the string stored in the database.
struct UnitKey: Hashable, Sendable {
    let kind: UnitKind
    let rootPath: String

    init(kind: UnitKind, rootPath: String) {
        self.kind = kind
        self.rootPath = rootPath
    }

    /// Parses `"<kind>|<rootPath>"`. Returns nil for strings without a kind,
    /// including the legacy empty key.
    init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: "|"), separator != rawValue.startIndex else {
            return nil
        }
        kind = UnitKind(rawValue: String(rawValue[..<separator]))
        rootPath = String(rawValue[rawValue.index(after: separator)...])
    }

    var rawValue: String {
        kind.rawValue + "|" + rootPath
    }
}

/// A path split once into components, relative to a home folder when it lies
/// inside it. Rules match on this and build their unit root from it.
struct UnitPath: Sendable {
    /// Normalised absolute path, case preserved.
    let path: String
    /// Components of `path` without the leading "/".
    let components: [String]
    /// Number of leading components that make up the home folder, or nil when
    /// the path is outside home.
    let homeDepth: Int?

    init(_ rawPath: String, home: String) {
        let parts = UnitPath.split(rawPath, home: home)
        components = parts
        path = "/" + parts.joined(separator: "/")

        let homeParts = UnitPath.split(home, home: home)
        let isUnderHome = parts.count >= homeParts.count
            && zip(parts, homeParts).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
        homeDepth = isUnderHome ? homeParts.count : nil
    }

    /// Components below home, case preserved; nil when outside home.
    var relative: [String]? {
        guard let homeDepth else { return nil }
        return Array(components[homeDepth...])
    }

    /// Lowercased components below home, for case-insensitive matching.
    var lowercasedRelative: [String]? {
        relative?.map { $0.lowercased() }
    }

    /// Path of home plus the first `depth` components below it (clamped).
    /// Only meaningful when the path is under home.
    func homeRoot(depth: Int) -> String {
        let base = homeDepth ?? 0
        return root(depth: base + depth)
    }

    /// Path made of the first `depth` absolute components (clamped).
    func root(depth: Int) -> String {
        let count = min(max(depth, 0), components.count)
        return "/" + components.prefix(count).joined(separator: "/")
    }

    private static func split(_ rawPath: String, home: String) -> [String] {
        var expanded = rawPath
        if expanded == "~" {
            expanded = home
        } else if expanded.hasPrefix("~/") {
            expanded = home + expanded.dropFirst()
        }
        return expanded.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
    }
}

/// One naming rule. A rule may resolve paths to unit roots, name roots of its
/// kind, or both.
struct UnitRule: Sendable {
    let kind: UnitKind
    /// Returns the unit root path for a path this rule owns, or nil.
    let resolve: (@Sendable (UnitPath) -> String?)?
    /// Returns the name for a root of this rule's kind, or nil to let the next
    /// rule of the same kind (and finally the place fallback) name it.
    let name: (@Sendable (UnitPath) -> UnitName?)?

    init(
        kind: UnitKind,
        resolve: (@Sendable (UnitPath) -> String?)? = nil,
        name: (@Sendable (UnitPath) -> UnitName?)? = nil
    ) {
        self.kind = kind
        self.resolve = resolve
        self.name = name
    }
}

/// The rule registry. Each pack lives in its own file so slices can edit them
/// independently:
/// - `UnitRules+Developer.swift` → `developer`
/// - `UnitRules+Media.swift` → `media`
/// - `UnitRules+Apps.swift` → `apps`
/// Core rules (Trash, Downloads, Library, place) live in `UnitNamer.swift`.
enum UnitRules {
    /// Resolution order: the first rule whose `resolve` returns a root wins.
    /// Trash and Downloads first, then the specific packs, then the generic
    /// Library and place fallbacks. Naming uses the same order, filtered by kind.
    static let all: [UnitRule] = coreLeading + developer + media + apps + coreTrailing
}

/// Turns any path into a stable unit key. Pure: no I/O, no database, no actor.
enum UnitResolver {
    static let defaultHome: String = FileManager.default.homeDirectoryForCurrentUser.path

    /// The persisted key `"<kind>|<rootPath>"` for a path.
    nonisolated static func resolve(path: String) -> String {
        resolveKey(path: path, home: defaultHome).rawValue
    }

    /// Same as `resolve(path:)` with an explicit home folder (for tests).
    nonisolated static func resolve(path: String, home: String) -> String {
        resolveKey(path: path, home: home).rawValue
    }

    nonisolated static func resolveKey(path: String, home: String = defaultHome) -> UnitKey {
        let unitPath = UnitPath(path, home: home)
        for rule in UnitRules.all {
            if let resolve = rule.resolve, let root = resolve(unitPath) {
                return UnitKey(kind: rule.kind, rootPath: root)
            }
        }
        // `coreTrailing` ends with the place fallback, which always resolves.
        return UnitKey(kind: .place, rootPath: UnitRules.placeRoot(for: unitPath))
    }
}
