import Foundation

/// Who a place belongs to: an app, or a category when no app owns it.
/// Computed at read time from the unit key, never stored.
enum UnitOwner: Hashable, Sendable {
    /// An app known by its canonical bundle id, e.g. `com.google.Chrome`.
    case app(id: String)
    /// An app known only by a folder name, e.g. "Claude" or "Chrome" inside a
    /// `Google` vendor folder. `AppCatalog` matches it against installed apps.
    case named(String, vendor: String? = nil)
    /// Places no app owns: Developer, Downloads, Media & Documents, ...
    case category(GrowthCategory)
    /// macOS itself: flat Library areas, Preferences, Apple daemons.
    case system

    /// Stable grouping key: owners with the same key are one owner.
    var key: String {
        switch self {
        case .app(let id): return "app:\(id.lowercased())"
        case .named(let name, _): return "name:\(name.lowercased())"
        case .category(let category): return "category:\(category.rawValue)"
        case .system: return "system"
        }
    }

    /// The owner's name without looking at installed apps.
    var fallbackDisplayName: String {
        switch self {
        case .app(let id): return AppIdentity.fallbackName(forIdentifier: id)
        case .named(let name, _): return name
        case .category(let category): return category.displayName
        case .system: return "System"
        }
    }

    var isApp: Bool {
        switch self {
        case .app, .named: return true
        case .category, .system: return false
        }
    }
}

/// Bundle-id canonicalisation for folder and file names macOS files under an app.
enum AppIdentity {
    /// The app's bundle id for a `~/Library/<Area>/<item>` name, or nil when the
    /// item is not a bundle id: `group.net.whatsapp.WhatsApp.shared` →
    /// `net.whatsapp.WhatsApp`, `UBF8T346G9.com.microsoft.teams` →
    /// `com.microsoft.teams`, `com.google.Chrome.helper` → `com.google.Chrome`,
    /// `com.apple.finder.plist` → `com.apple.finder`, `UBF8T346G9.Office` → nil.
    static func canonical(_ item: String) -> String? {
        var segments = bareName(item).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard isIdentifier(segments, minimumSegments: 3) else { return nil }
        while segments.count > 3, let last = segments.last, isHelperSegment(last) {
            segments.removeLast()
        }
        return segments.joined(separator: ".")
    }

    /// The item without what macOS adds around an app's id or name: a `group.`
    /// prefix, a team-id prefix and an id file extension.
    /// `UBF8T346G9.Office` → "Office", `group.com.apple.notes` → "com.apple.notes".
    static func bareName(_ item: String) -> String {
        var identifier = item
        if identifier.lowercased().hasPrefix("group.") {
            identifier = String(identifier.dropFirst("group.".count))
        }
        if let teamPrefix = identifier.range(of: "^[A-Z0-9]{10}\\.", options: .regularExpression) {
            identifier.removeSubrange(teamPrefix)
        }
        if let dot = identifier.lastIndex(of: "."),
           identifierFileExtensions.contains(identifier[identifier.index(after: dot)...].lowercased()) {
            identifier = String(identifier[..<dot])
        }
        return identifier.isEmpty ? item : identifier
    }

    /// The app's bundle id for an iCloud container folder:
    /// `iCloud~com~culturedcode~ThingsMac` → `com.culturedcode.ThingsMac`,
    /// `57T9237FN3~net~whatsapp~WhatsApp` → `net.whatsapp.WhatsApp`,
    /// `27N4MQEA55~pro~writer` → `pro.writer`.
    static func icloudIdentifier(_ container: String) -> String? {
        var segments = container.split(separator: "~").map(String.init)
        if segments.first?.lowercased() == "icloud" { segments.removeFirst() }
        if let first = segments.first, first.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil {
            segments.removeFirst()
        }
        guard isIdentifier(segments, minimumSegments: 2) else { return nil }
        return segments.joined(separator: ".")
    }

    /// An app name for a bundle id when the app is not installed: the offline
    /// table, else the last segment ("com.acme.FooBar" → "FooBar").
    static func fallbackName(forIdentifier identifier: String) -> String {
        let name = GrowthCategory.cacheApplicationDisplayName(for: identifier)
        guard let first = name.first, first.isLowercase else { return name }
        return first.uppercased() + name.dropFirst()
    }

    static let identifierFileExtensions: Set<String> = [
        "plist", "savedstate", "binarycookies", "log", "db", "sqlite", "json", "lock"
    ]

    private static let helperSegments: Set<String> = [
        "shipit", "shared", "group", "launcher", "renderer", "gpu", "plugin", "xpc", "mac", "desktop", "app"
    ]

    private static let helperSuffixes = ["helper", "extension", "widget", "agent"]

    private static func isHelperSegment(_ segment: String) -> Bool {
        let lower = segment.lowercased()
        return helperSegments.contains(lower) || helperSuffixes.contains { lower.hasSuffix($0) }
    }

    private static func isIdentifier(_ segments: [String], minimumSegments: Int) -> Bool {
        segments.count >= minimumSegments && segments.allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }
}
