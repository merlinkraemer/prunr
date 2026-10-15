import AppKit

/// One installed app.
struct AppCatalogEntry: Sendable, Hashable {
    let bundleIdentifier: String
    /// `CFBundleDisplayName` ?? `CFBundleName` ?? the `.app` stem.
    let name: String
    /// Every name the app answers to: display name, bundle name, `.app` stem.
    let names: [String]
    let path: String

    init(bundleIdentifier: String, name: String, names: [String] = [], path: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.names = names.isEmpty ? [name] : names
        self.path = path
    }
}

/// An owner as the list shows it: one key per app, its name and icon.
struct ResolvedOwner: Sendable, Hashable {
    /// Owners with the same key are one row.
    let key: String
    let displayName: String
    let icon: UnitIconSource
}

/// A snapshot of the installed apps, by bundle id and by name. Built on the
/// main actor by `AppCatalogProvider`, passed around as a value; tests build
/// one from fake entries.
struct AppCatalog: Sendable {
    static let empty = AppCatalog(entries: [])

    private let byIdentifier: [String: AppCatalogEntry]
    private let byName: [String: AppCatalogEntry]
    private let namesLongestFirst: [(name: String, entry: AppCatalogEntry)]

    init(entries: [AppCatalogEntry]) {
        var byIdentifier: [String: AppCatalogEntry] = [:]
        var byName: [String: AppCatalogEntry] = [:]
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            byIdentifier[entry.bundleIdentifier.lowercased()] = byIdentifier[entry.bundleIdentifier.lowercased()] ?? entry
            for name in entry.names {
                byName[name.lowercased()] = byName[name.lowercased()] ?? entry
            }
        }
        self.byIdentifier = byIdentifier
        self.byName = byName
        namesLongestFirst = byName
            .map { (name: $0.key, entry: $0.value) }
            .sorted { $0.name.count == $1.name.count ? $0.name < $1.name : $0.name.count > $1.name.count }
    }

    /// The app with this bundle id, or with the id minus its last segment
    /// (helper bundles: `com.apple.Safari.SafeBrowsing` → Safari).
    func entry(forIdentifier identifier: String) -> AppCatalogEntry? {
        if let entry = byIdentifier[identifier.lowercased()] { return entry }
        guard let parent = Self.droppingLastSegment(identifier) else { return nil }
        return byIdentifier[parent.lowercased()]
    }

    /// The app called `name` (or "<vendor> <name>"): exact, case-insensitive,
    /// then by a prefix that ends at a separator, either way round:
    /// "Prunr backup" → Prunr, "Ableton" → "Ableton Live 12 Suite". Never
    /// "Go" → "GoLand".
    func entry(named name: String, vendor: String? = nil) -> AppCatalogEntry? {
        let candidates = [vendor.map { "\($0) \(name)" }, name].compactMap { $0?.lowercased() }
        for candidate in candidates {
            if let entry = byName[candidate] { return entry }
        }
        for candidate in candidates {
            if let match = namesLongestFirst.first(where: { Self.hasSeparatedPrefix(candidate, $0.name) }) {
                return match.entry
            }
            if let match = namesLongestFirst.reversed().first(where: { Self.hasSeparatedPrefix($0.name, candidate) }) {
                return match.entry
            }
        }
        return nil
    }

    func resolve(_ owner: UnitOwner) -> ResolvedOwner {
        switch owner {
        case .app(let id):
            if let entry = entry(forIdentifier: id) { return Self.resolved(entry) }
            if id.lowercased().hasPrefix("com.apple.") { return Self.system }
            return ResolvedOwner(key: owner.key, displayName: owner.fallbackDisplayName, icon: .genericApp)
        case .named(let name, let vendor):
            if let entry = entry(named: name, vendor: vendor) { return Self.resolved(entry) }
            return ResolvedOwner(key: owner.key, displayName: name, icon: .genericApp)
        case .category(let category):
            return ResolvedOwner(key: owner.key, displayName: category.displayName, icon: .category)
        case .system:
            return Self.system
        }
    }

    private static let system = ResolvedOwner(
        key: UnitOwner.system.key, displayName: UnitOwner.system.fallbackDisplayName, icon: .category
    )

    private static func resolved(_ entry: AppCatalogEntry) -> ResolvedOwner {
        ResolvedOwner(
            key: UnitOwner.app(id: entry.bundleIdentifier).key,
            displayName: entry.name,
            icon: .app(bundleIdentifier: entry.bundleIdentifier)
        )
    }

    private static let separators: Set<Character> = [" ", "-", "_", "."]

    private static func hasSeparatedPrefix(_ text: String, _ prefix: String) -> Bool {
        guard text.count > prefix.count, text.hasPrefix(prefix) else { return false }
        return separators.contains(text[text.index(text.startIndex, offsetBy: prefix.count)])
    }

    private static func droppingLastSegment(_ identifier: String) -> String? {
        let segments = identifier.split(separator: ".")
        guard segments.count > 3 else { return nil }
        return segments.dropLast().joined(separator: ".")
    }
}

/// Builds and caches the `AppCatalog` of the apps in `/Applications`,
/// `~/Applications` and `/System/Applications` (and one folder level below),
/// refreshed when an app launches. Apps elsewhere are found by bundle id
/// through Launch Services.
@MainActor
final class AppCatalogProvider {
    static let shared = AppCatalogProvider()

    private var scanned: [AppCatalogEntry]?
    private var located: [String: AppCatalogEntry] = [:]
    private var launchObserver: NSObjectProtocol?

    private init() {
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanned = nil }
        }
    }

    /// The installed apps, plus the apps behind `identifiers` that live
    /// outside the scanned folders.
    func catalog(resolving identifiers: [String] = []) -> AppCatalog {
        let entries = scannedEntries()
        let known = Set(entries.map { $0.bundleIdentifier.lowercased() })
        for identifier in identifiers where !known.contains(identifier.lowercased()) {
            locate(identifier)
        }
        return AppCatalog(entries: entries + located.values)
    }

    private func scannedEntries() -> [AppCatalogEntry] {
        if let scanned { return scanned }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", home + "/Applications", "/System/Applications"]
        let entries = roots.flatMap { Self.apps(in: $0, depth: 2) }
        scanned = entries
        return entries
    }

    private func locate(_ identifier: String) {
        guard located[identifier.lowercased()] == nil,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
              let entry = Self.entry(at: url) else { return }
        located[identifier.lowercased()] = entry
    }

    private static func apps(in folder: String, depth: Int) -> [AppCatalogEntry] {
        guard depth > 0, let items = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        return items.flatMap { item -> [AppCatalogEntry] in
            let path = folder + "/" + item
            if item.lowercased().hasSuffix(".app") {
                return entry(at: URL(fileURLWithPath: path)).map { [$0] } ?? []
            }
            var isDirectory: ObjCBool = false
            guard !item.hasPrefix("."), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return [] }
            return apps(in: path, depth: depth - 1)
        }
    }

    private static func entry(at url: URL) -> AppCatalogEntry? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        let displayName = (info["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let bundleName = (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var names: [String] = []
        for name in [displayName, bundleName, stem].compactMap({ $0 }) where !names.contains(name) {
            names.append(name)
        }
        return AppCatalogEntry(
            bundleIdentifier: identifier, name: displayName ?? bundleName ?? stem, names: names, path: url.path
        )
    }
}
