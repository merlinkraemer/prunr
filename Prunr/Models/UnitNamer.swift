import Foundation

/// What the change list shows for a unit.
struct UnitName: Equatable, Sendable {
    /// What the place is, read inside its owner: "Cache", "Celeste",
    /// "Xcode build files · Weatherly", "Downloads · ubuntu.iso".
    let title: String
    /// What survives when the title does not fit: the project or item name
    /// ("Weatherly"). Nil when the title itself is that.
    let shortTitle: String?
    /// Optional muted caption, e.g. "images, containers, volumes".
    let context: String?
    /// Category whose symbol the row uses when `icon` can't be shown.
    let category: GrowthCategory
    /// Where the row's real icon comes from; `.category` uses the category symbol.
    let icon: UnitIconSource
    /// Who the place belongs to.
    let owner: UnitOwner

    init(
        title: String,
        shortTitle: String? = nil,
        context: String? = nil,
        category: GrowthCategory,
        icon: UnitIconSource = .category,
        owner: UnitOwner? = nil
    ) {
        self.title = title
        self.shortTitle = shortTitle
        self.context = context
        self.category = category
        self.icon = icon
        self.owner = owner ?? .category(category)
    }

    /// The title where the owner is not shown next to it: "Google Chrome · Cache".
    var standaloneTitle: String {
        guard owner.isApp else { return title }
        let ownerName = owner.fallbackDisplayName
        return title.caseInsensitiveCompare(ownerName) == .orderedSame ? title : "\(ownerName) · \(title)"
    }
}

/// Where a place's icon comes from. Resolved lazily by `UnitIconResolver`, which
/// falls back to the category symbol when the app or file isn't there.
enum UnitIconSource: Hashable, Sendable {
    /// The category symbol on its coloured tile.
    case category
    /// The icon of the installed app with this bundle id.
    case app(bundleIdentifier: String)
    /// The icon of the installed app with this name (see `AppCatalog`).
    case namedApp(name: String, vendor: String?)
    /// The file's own icon (a single download).
    case file(path: String)
    /// The generic app icon: an app whose data is left but which is not installed.
    case genericApp

    static let xcode = UnitIconSource.app(bundleIdentifier: "com.apple.dt.Xcode")
    static let docker = UnitIconSource.app(bundleIdentifier: "com.docker.docker")
    static let mail = UnitIconSource.app(bundleIdentifier: "com.apple.mail")
    static let messages = UnitIconSource.app(bundleIdentifier: "com.apple.MobileSMS")
    static let photos = UnitIconSource.app(bundleIdentifier: "com.apple.Photos")
    static let finalCutPro = UnitIconSource.app(bundleIdentifier: "com.apple.FinalCut")
    static let abletonLive = UnitIconSource.app(bundleIdentifier: "com.ableton.live")
    static let steam = UnitIconSource.app(bundleIdentifier: "com.valvesoftware.steam")

    /// The owner's app icon; `.category` for category and system owners.
    static func owner(_ owner: UnitOwner) -> UnitIconSource {
        switch owner {
        case .app(let id): return .app(bundleIdentifier: id)
        case .named(let name, let vendor): return .namedApp(name: name, vendor: vendor)
        case .category, .system: return .category
        }
    }
}

/// Turns a unit key into a display name. Pure; computed at read time.
enum UnitNamer {
    /// Name for a persisted key. Keys without a kind are named as a place.
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
        let shortTitle = raw.shortTitle.map { sanitize($0) }.flatMap { $0.isEmpty || $0 == title ? nil : $0 }
        let context = raw.context.map { sanitize($0) }.flatMap { $0.isEmpty ? nil : $0 }
        return UnitName(
            title: title.isEmpty ? "Files" : title,
            shortTitle: shortTitle,
            context: context,
            category: raw.category,
            icon: raw.icon,
            owner: raw.owner
        )
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
           AppIdentity.identifierFileExtensions.contains(identifier[identifier.index(after: dot)...].lowercased()) {
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

    /// A machine-made name in plain words, or nil when nothing machine-made is in
    /// it: dates, times, numbers, versions, ids and release words are dropped.
    /// "Prunr-backup-20261014-1439" → "Prunr backup",
    /// "Xcode_26.1_Release_Candidate" → "Xcode", "Claude" → nil.
    static func plainStem(_ text: String) -> String? {
        let withoutIds = uuidRegex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " "
        )
        let tokens = withoutIds.split(whereSeparator: { "-_. ".contains($0) }).map(String.init)
        let kept = tokens.filter { !isMachineToken($0) }
        guard kept.count < tokens.count || withoutIds != text, !kept.isEmpty else { return nil }
        return kept.joined(separator: " ")
    }

    /// Removes anything a name must never show: 32+ character hex runs, dashed
    /// UUIDs and dotted bundle ids (replaced by the app's name). Applied to every name.
    static func sanitize(_ text: String) -> String {
        var result = text
        for match in bundleIdRegex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: GrowthCategory.cacheApplicationDisplayName(for: String(result[range])))
        }
        result = uuidRegex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: ""
        )
        result = hexRunRegex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: ""
        )
        result = result.replacingOccurrences(of: "  ", with: " ")
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ·-"))
    }

    /// True if text contains a 32+ hex run, a dashed UUID or a dotted bundle id.
    /// Rule-pack tests use this as their guard.
    static func containsForbiddenToken(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return hexRunRegex.firstMatch(in: text, range: range) != nil
            || uuidRegex.firstMatch(in: text, range: range) != nil
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

    /// A dashed 36-character UUID, with one leading separator.
    private static let uuidRegex = try! NSRegularExpression(
        pattern: "[-_.]?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    )

    private static let releaseWords: Set<String> = [
        "release", "candidate", "rc", "beta", "alpha", "universal", "arm64", "x64", "x86", "intel"
    ]

    private static func isMachineToken(_ token: String) -> Bool {
        let lower = token.lowercased()
        if releaseWords.contains(lower) { return true }
        if lower.range(of: "^v?[0-9]+[a-z]?$", options: .regularExpression) != nil { return true }
        if lower.range(of: "^(rc|beta|alpha|b)[0-9]+$", options: .regularExpression) != nil { return true }
        return lower.count >= 8 && lower.allSatisfy(\.isHexDigit) && lower.contains(where: \.isNumber)
    }

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
    /// Installers read as what they install: "Xcode_26.1_Release_Candidate.xip" → "Xcode installer".
    static let downloadRule = UnitRule(
        kind: .download,
        resolve: { path in
            guard let relative = path.lowercasedRelative, relative.first == "downloads" else { return nil }
            return path.homeRoot(depth: 2)
        },
        name: { root in
            guard let relative = root.relative, relative.count >= 2 else {
                return UnitName(title: "Downloads", category: .downloads)
            }
            let file = UnitRules.strippingPartialDownloadSuffix(relative[1])
            guard let item = UnitRules.installerName(file) ?? UnitNamer.displayComponent(file) else {
                return UnitName(title: "Downloads", category: .downloads)
            }
            return UnitName(
                title: "Downloads · \(item)", shortTitle: item, category: .downloads, icon: .file(path: root.path)
            )
        }
    )

    /// `~/Library/<Area>/<X>/...`; named by `libraryName(for:)`. Preferences and
    /// files lying directly in an area are one unit per area; vendor folders
    /// (`Application Support/Google/Chrome`) go one level deeper.
    static let libraryRule = UnitRule(
        kind: .library,
        resolve: { path in
            guard let relative = path.lowercasedRelative, relative.first == "library" else { return nil }
            if relative.count >= 2, relative[1] == "preferences" { return path.homeRoot(depth: 2) }
            if relative.count == 3 { return path.homeRoot(depth: 2) }
            if relative.count >= 5, libraryVendors.contains(relative[2]) { return path.homeRoot(depth: 4) }
            return path.homeRoot(depth: 3)
        },
        name: { root in UnitRules.libraryName(for: root) }
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
        let category = root.category
        let readable = parts.suffix(2).compactMap(UnitNamer.displayComponent)
        switch readable.count {
        case 2:
            return UnitName(title: "\(readable[1]) · \(readable[0])", shortTitle: readable[1], category: category)
        case 1:
            return UnitName(title: readable[0], category: category)
        default:
            return UnitName(title: root.relative != nil ? "Home folder" : "Disk", category: category)
        }
    }

    // MARK: Library

    /// Library areas macOS files under an app, and what a place there is to its app.
    private static let appAreaTitles: [String: String] = [
        "application support": "App data",
        "containers": "App data",
        "caches": "Cache",
        "group containers": "Shared data",
        "webkit": "Website data",
        "httpstorages": "Website data",
        "cookies": "Cookies",
        "logs": "Logs",
        "saved application state": "Saved windows"
    ]

    /// Vendors that nest their apps one level deeper: `Application Support/Google/Chrome`.
    static let libraryVendors: Set<String> = ["google", "adobe", "microsoft", "mozilla", "jetbrains", "epic", "unity"]

    /// Places whose app id says nothing readable on its own.
    private static let knownItemTitles: [String: String] = [
        "com.apple.wallpaper": "Aerial wallpapers"
    ]

    /// A `~/Library` root. Inside app areas (Application Support, Caches,
    /// Containers, ...) the owner is the app and the title says what the place
    /// is ("Cache", "App data"); other areas belong to the system and read as
    /// the area ("Fonts", "Preferences").
    static func libraryName(for root: UnitPath) -> UnitName? {
        guard let rel = root.relative, rel.first?.caseInsensitiveCompare("Library") == .orderedSame else {
            return nil
        }
        let category = root.category
        let areaOwner: UnitOwner = category == .cachesAndSystem ? .system : .category(category)
        guard rel.count >= 2 else {
            return UnitName(title: "Library files", category: category, owner: areaOwner)
        }
        let area = rel[1].lowercased()
        let areaName = UnitNamer.displayComponent(rel[1]) ?? "Library files"
        switch area {
        case "mail":
            let owner = UnitOwner.app(id: "com.apple.mail")
            return UnitName(title: "Mailboxes", category: category, icon: .mail, owner: owner)
        case "messages":
            let owner = UnitOwner.app(id: "com.apple.MobileSMS")
            return UnitName(title: "Chat history", category: category, icon: .messages, owner: owner)
        default:
            break
        }
        guard rel.count >= 3 else {
            return UnitName(title: areaName, category: category, owner: areaOwner)
        }
        let item = rel[2]
        guard let kindTitle = appAreaTitles[area] else {
            return UnitName(
                title: areaName, context: UnitNamer.appDisplayName(item), category: category, owner: areaOwner
            )
        }

        let owner: UnitOwner
        var title = kindTitle
        if rel.count >= 4, libraryVendors.contains(item.lowercased()), let app = UnitNamer.displayComponent(rel[3]) {
            owner = .named(app, vendor: UnitNamer.displayComponent(item))
        } else if let id = AppIdentity.canonical(item) {
            owner = .app(id: id)
            title = knownItemTitles[id] ?? kindTitle
        } else if let stem = UnitNamer.plainStem(AppIdentity.bareName(item)) {
            owner = .named(stem)
            title = stem
        } else if let name = UnitNamer.displayComponent(AppIdentity.bareName(item)) {
            owner = .named(name)
        } else {
            return UnitName(title: areaName, category: category, owner: areaOwner)
        }
        return UnitName(title: title, category: category, icon: .owner(owner), owner: owner)
    }

    // MARK: Helpers

    private static func strippingPartialDownloadSuffix(_ item: String) -> String {
        for suffix in [".crdownload", ".download", ".part"] where item.lowercased().hasSuffix(suffix) {
            let stripped = String(item.dropLast(suffix.count))
            return stripped.isEmpty ? item : stripped
        }
        return item
    }

    private static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]

    /// "Xcode_26.1_Release_Candidate.xip" → "Xcode installer"; nil for other files.
    private static func installerName(_ file: String) -> String? {
        guard let dot = file.lastIndex(of: "."),
              installerExtensions.contains(file[file.index(after: dot)...].lowercased()) else { return nil }
        let base = String(file[..<dot])
        guard let stem = UnitNamer.plainStem(base) ?? UnitNamer.displayComponent(base) else { return nil }
        return "\(stem) installer"
    }
}
