import AppKit
import UniformTypeIdentifiers

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
        var namedApplicationIcon: @MainActor (_ name: String, _ vendor: String?) -> NSImage? = { _, _ in nil }
        var genericApplicationIcon: @MainActor () -> NSImage? = { nil }

        static var workspace: Lookup {
            Lookup(
                applicationIcon: { CacheApplicationIconResolver.icon(forBundleIdentifier: $0) },
                fileIcon: { path in
                    // `icon(forFile:)` returns a generic icon for missing paths.
                    guard FileManager.default.fileExists(atPath: path) else { return nil }
                    return NSWorkspace.shared.icon(forFile: path)
                },
                namedApplicationIcon: { name, vendor in
                    guard let entry = AppCatalogProvider.shared.catalog().entry(named: name, vendor: vendor) else {
                        return nil
                    }
                    return NSWorkspace.shared.icon(forFile: entry.path)
                },
                genericApplicationIcon: { NSWorkspace.shared.icon(for: .application) }
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
        case .namedApp(let name, let vendor):
            image = lookup.namedApplicationIcon(name, vendor)
        case .file(let path):
            image = lookup.fileIcon(path)
        case .genericApp:
            image = lookup.genericApplicationIcon()
        }
        cache[source] = .some(image)
        return image
    }
}

/// App icons by bundle id or app name: the id itself, its canonical form
/// (helper suffixes dropped), the id minus its last segment, then the installed
/// app with that name. Shared by the cache drilldown and `UnitIconResolver`.
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

        if AppIdentity.canonical(bundleIdentifier) == nil,
           let entry = AppCatalogProvider.shared.catalog().entry(named: AppIdentity.bareName(bundleIdentifier)) {
            return NSWorkspace.shared.icon(forFile: entry.path)
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
        let canonical = AppIdentity.canonical(bundleIdentifier)
        let parent = (canonical ?? bundleIdentifier).split(separator: ".")
        let dropped = parent.count > 3 ? parent.dropLast().joined(separator: ".") : nil
        var seen = Set<String>()
        return [bundleIdentifier, canonical, dropped]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }

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
