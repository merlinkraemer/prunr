import Foundation

/// What the change list shows for a unit.
struct UnitName: Equatable, Sendable {
    /// Recognisable name, e.g. "Downloads · ubuntu.iso" or "Archive · Documents".
    let title: String
    /// Optional muted detail for the caption, e.g. "Application Support".
    let detail: String?
    /// Category whose icon the row uses.
    let category: GrowthCategory

    init(title: String, detail: String? = nil, category: GrowthCategory) {
        self.title = title
        self.detail = detail
        self.category = category
    }
}

/// Turns a unit key into a display name. Pure; computed at read time.
enum UnitNamer {
    /// Name for a persisted key. Keys without a kind (the legacy `''`) are named
    /// as a place; callers that group legacy rows coarsely handle `''` themselves.
    nonisolated static func name(forKey rawKey: String, home: String = UnitResolver.defaultHome) -> UnitName {
        let key = UnitKey(rawValue: rawKey) ?? UnitKey(kind: .place, rootPath: rawKey)
        return name(for: key, home: home)
    }

    nonisolated static func name(for key: UnitKey, home: String = UnitResolver.defaultHome) -> UnitName {
        let root = UnitPath(key.rootPath, home: home)
        var resolved: UnitName?
        for rule in UnitRules.all where rule.kind == key.kind {
            if let namer = rule.name, let candidate = namer(root) {
                resolved = candidate
                break
            }
        }
        // Unknown kinds (a rule removed in a later release) still read as a place.
        let raw = resolved ?? UnitRules.placeName(for: root)

        let title = sanitize(raw.title)
        let detail = raw.detail.map { sanitize($0) }.flatMap { $0.isEmpty ? nil : $0 }
        return UnitName(title: title.isEmpty ? "Files" : title, detail: detail, category: raw.category)
    }

    /// Resolves and names a path in one step.
    nonisolated static func name(path: String, home: String = UnitResolver.defaultHome) -> UnitName {
        name(for: UnitResolver.resolveKey(path: path, home: home), home: home)
    }

    // MARK: - Display helpers for rules

    /// A path component as the user would read it, or nil if nothing readable
    /// is left (for example a bare hash, or a hash with only its extension left).
    static func displayComponent(_ component: String) -> String? {
        let cleaned = sanitize(component)
        guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        if cleaned.hasPrefix("."), !component.hasPrefix(".") { return nil }
        return cleaned
    }

    /// An app-owned folder or file name inside `~/Library` as the app's name:
    /// `com.apple.Safari` → "Safari", `UBF8T346G9.Office` → "Office",
    /// `com.apple.finder.plist` → "Finder". Other names go through
    /// `displayComponent`. Do not use for user files (`ubuntu.iso` stays as is there).
    static func appDisplayName(_ component: String) -> String? {
        guard looksLikeIdentifier(component) else { return displayComponent(component) }
        var identifier = component
        if let dot = identifier.lastIndex(of: "."),
           identifierFileExtensions.contains(identifier[identifier.index(after: dot)...].lowercased()) {
            identifier = String(identifier[..<dot])
        }
        var text = identifier.contains(".")
            ? GrowthCategory.cacheApplicationDisplayName(for: identifier)
            : identifier
        if let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        return displayComponent(text)
    }

    /// Removes anything a name must never show: 32+ character hex runs and dotted
    /// bundle ids (replaced by the app's name). Applied to every name.
    static func sanitize(_ text: String) -> String {
        var result = text
        for match in bundleIdRegex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: GrowthCategory.cacheApplicationDisplayName(for: String(result[range])))
        }
        result = hexRunRegex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: ""
        )
        result = result.replacingOccurrences(of: "  ", with: " ")
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ·-"))
    }

    /// True if text contains a 32+ hex run or a dotted bundle id. Rule-pack tests
    /// use this as their guard.
    static func containsForbiddenToken(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return hexRunRegex.firstMatch(in: text, range: range) != nil
            || bundleIdRegex.firstMatch(in: text, range: range) != nil
    }

    // MARK: - Private

    /// Reverse-DNS ids with at least three segments, e.g. `com.apple.Safari`,
    /// `group.com.apple.notes`. File names like `archive.tar.gz` do not match.
    private static let bundleIdRegex = try! NSRegularExpression(
        pattern: "(?i)\\b(?:com|org|net|io|group|us|de|co|app|dev|me|company|uk|eu|ch|at|nl|fr|jp|tv|ai)\\.[a-z0-9_-]+(?:\\.[a-z0-9_-]+)+"
    )

    /// 32 or more hex characters, with one leading separator.
    private static let hexRunRegex = try! NSRegularExpression(pattern: "[-_.]?[0-9A-Fa-f]{32,}")

    private static let identifierFileExtensions: Set<String> = [
        "plist", "savedstate", "binarycookies", "log", "db", "sqlite", "json", "lock"
    ]

    /// A single dotted token without spaces, e.g. `com.apple.Safari` or
    /// `UBF8T346G9.Office`.
    private static func looksLikeIdentifier(_ text: String) -> Bool {
        let segments = text.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2, !text.contains(" ") else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }
}

// MARK: - Core rules: Trash, Downloads, Library, named place

extension UnitRules {
    /// Rules that run before the packs.
    static let coreLeading: [UnitRule] = [trashRule, downloadRule]

    /// Generic fallbacks that run after the packs. The place rule always resolves.
    static let coreTrailing: [UnitRule] = [libraryRule, placeRule]

    /// `~/.Trash/...` → one unit "Trash".
    static let trashRule = UnitRule(
        kind: .trash,
        resolve: { path in
            guard let relative = path.lowercasedRelative, relative.first == ".trash" else { return nil }
            return path.homeRoot(depth: 1)
        },
        name: { _ in UnitName(title: "Trash", category: .trash) }
    )

    /// `~/Downloads/<item>/...` → "Downloads · <item>"; `~/Downloads` itself → "Downloads".
    static let downloadRule = UnitRule(
        kind: .download,
        resolve: { path in
            guard let relative = path.lowercasedRelative, relative.first == "downloads" else { return nil }
            return path.homeRoot(depth: 2)
        },
        name: { root in
            guard let relative = root.relative, relative.count >= 2,
                  let item = UnitNamer.displayComponent(UnitRules.strippingPartialDownloadSuffix(relative[1])) else {
                return UnitName(title: "Downloads", category: .downloads)
            }
            return UnitName(title: "Downloads · \(item)", category: .downloads)
        }
    )

    /// `~/Library/<Area>/<X>/...` → "X data", caption "<Area>".
    static let libraryRule = UnitRule(
        kind: .library,
        resolve: { path in
            guard let relative = path.lowercasedRelative, relative.first == "library" else { return nil }
            return path.homeRoot(depth: 3)
        },
        name: { root in
            guard let relative = root.relative, relative.first?.caseInsensitiveCompare("Library") == .orderedSame else {
                return nil
            }
            let category = GrowthCategory.categorize(path: root.path)
            guard relative.count >= 2 else {
                return UnitName(title: "Library files", category: category)
            }
            let area = UnitNamer.displayComponent(relative[1]) ?? "Library files"
            guard relative.count >= 3, let item = UnitNamer.appDisplayName(relative[2]) else {
                return UnitName(title: area, category: category)
            }
            return UnitName(title: "\(item) data", detail: area, category: category)
        }
    )

    /// Named-place fallback: the first two folders below home, e.g.
    /// `~/Documents/Archive/...` → "Archive · Documents". Outside home, the first
    /// two folders below `/`.
    static let placeRule = UnitRule(
        kind: .place,
        resolve: { path in UnitRules.placeRoot(for: path) },
        name: { root in UnitRules.placeName(for: root) }
    )

    static func placeRoot(for path: UnitPath) -> String {
        path.homeDepth != nil ? path.homeRoot(depth: 2) : path.root(depth: 2)
    }

    /// Names any root by its last two parts, "<inner> · <outer>". Also used for
    /// keys whose kind no rule knows.
    static func placeName(for root: UnitPath) -> UnitName {
        let parts = root.relative ?? root.components
        let category = GrowthCategory.categorize(path: root.path)
        let readable = parts.suffix(2).compactMap(UnitNamer.displayComponent)
        switch readable.count {
        case 2:
            return UnitName(title: "\(readable[1]) · \(readable[0])", category: category)
        case 1:
            return UnitName(title: readable[0], category: category)
        default:
            return UnitName(title: root.relative != nil ? "Home folder" : "Disk", category: category)
        }
    }

    private static func strippingPartialDownloadSuffix(_ item: String) -> String {
        for suffix in [".crdownload", ".download", ".part"] where item.lowercased().hasSuffix(suffix) {
            let stripped = String(item.dropLast(suffix.count))
            return stripped.isEmpty ? item : stripped
        }
        return item
    }
}
