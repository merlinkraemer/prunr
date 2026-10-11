import AppKit

/// Turns a place's `UnitIconSource` into an image for the change list.
///
/// Main-actor bound because `NSImage` isn't `Sendable`. The lookups are quick
/// Launch Services and icon-cache calls, made at most once per source: results,
/// misses included, are cached for the app's lifetime. A nil result means "show
/// the category symbol" (the source is `.category`, the app isn't installed, or
/// the file is gone).
@MainActor
final class UnitIconResolver {
    /// How icons are looked up. Tests inject fakes so they don't depend on the
    /// apps installed on the machine.
    struct Lookup {
        var applicationIcon: @MainActor (_ bundleIdentifier: String) -> NSImage?
        var fileIcon: @MainActor (_ path: String) -> NSImage?

        static var workspace: Lookup {
            Lookup(
                applicationIcon: { CacheApplicationIconResolver.icon(forBundleIdentifier: $0) },
                fileIcon: { path in
                    // `icon(forFile:)` returns a generic icon for missing paths.
                    guard FileManager.default.fileExists(atPath: path) else { return nil }
                    return NSWorkspace.shared.icon(forFile: path)
                }
            )
        }
    }

    static let shared = UnitIconResolver(lookup: .workspace)

    private let lookup: Lookup
    private var cache: [UnitIconSource: NSImage?] = [:]

    init(lookup: Lookup) {
        self.lookup = lookup
    }

    func icon(for source: UnitIconSource) -> NSImage? {
        if let cached = cache[source] { return cached }
        let image: NSImage?
        switch source {
        case .category:
            return nil
        case .app(let bundleIdentifier):
            image = lookup.applicationIcon(bundleIdentifier)
        case .file(let path):
            image = lookup.fileIcon(path)
        }
        cache[source] = .some(image)
        return image
    }
}

/// App icons by bundle id (or product name), with aliases for helper processes
/// and explicit paths for apps Launch Services may briefly miss. Shared by the
/// cache drilldown and `UnitIconResolver`.
enum CacheApplicationIconResolver {
    @MainActor
    static func icon(forBundleIdentifier bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }

        let candidates = bundleIdentifierCandidates(for: bundleIdentifier)
        for candidate in candidates {
            if let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: candidate
            ) {
                return NSWorkspace.shared.icon(forFile: applicationURL.path)
            }
        }

        // Many cache directories use the application's product name rather
        // than its bundle identifier (for example, Arc or Steam).
        if let applicationPath = NSWorkspace.shared.fullPath(forApplication: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: applicationPath)
        }

        // Launch Services can briefly lag behind an app install/update. Keep
        // explicit paths for the major browsers so their cache rows still get
        // their real icons during that window.
        for candidate in candidates {
            for path in knownApplicationPaths[candidate] ?? [] {
                guard FileManager.default.fileExists(atPath: path) else { continue }
                return NSWorkspace.shared.icon(forFile: path)
            }
        }

        return nil
    }

    static func bundleIdentifierCandidates(for bundleIdentifier: String) -> [String] {
        let helperBase = helperSuffixes.first(where: { bundleIdentifier.hasSuffix($0) })
            .map { String(bundleIdentifier.dropLast($0.count)) }
        var seen = Set<String>()
        return [bundleIdentifier, aliases[bundleIdentifier], helperBase]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }

    private static let helperSuffixes = [".ShipIt", ".helper"]

    private static let aliases: [String: String] = [
        "com.apple.Safari.SafeBrowsing": "com.apple.Safari",
        "com.apple.WebKit.Networking": "com.apple.Safari",
        "com.apple.WebKit.WebContent": "com.apple.Safari",
        "com.google.Chrome.helper": "com.google.Chrome",
        "com.microsoft.VSCode.ShipIt": "com.microsoft.VSCode",
        "Google": "com.google.Chrome",
        "Adobe": "com.adobe.acc.AdobeCreativeCloud",
        "Steam": "com.valvesoftware.steam"
    ]

    private static let knownApplicationPaths: [String: [String]] = [
        "com.google.Chrome": [
            "/Applications/Google Chrome.app",
            userApplicationPath("Google Chrome.app")
        ],
        "com.google.Chrome.canary": [
            "/Applications/Google Chrome Canary.app",
            userApplicationPath("Google Chrome Canary.app")
        ],
        "com.google.Chrome.beta": [
            "/Applications/Google Chrome Beta.app",
            userApplicationPath("Google Chrome Beta.app")
        ],
        "com.google.Chrome.dev": [
            "/Applications/Google Chrome Dev.app",
            userApplicationPath("Google Chrome Dev.app")
        ],
        "org.mozilla.firefox": [
            "/Applications/Firefox.app",
            userApplicationPath("Firefox.app")
        ],
        "com.apple.Safari": [
            "/Applications/Safari.app",
            "/System/Applications/Safari.app"
        ],
        "com.adobe.acc.AdobeCreativeCloud": [
            "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app"
        ],
        "com.valvesoftware.steam": [
            "/Applications/Steam.app"
        ]
    ]

    private static func userApplicationPath(_ applicationName: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(applicationName, isDirectory: true)
            .path
    }
}
