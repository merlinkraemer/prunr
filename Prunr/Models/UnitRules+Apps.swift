import Foundation

// App and cache unit rules (slice s6): ~/Library/Caches/<id> → "<App> cache",
// Containers and Group Containers → "<App> data", Application Support, Steam
// games, Mail, Messages attachments and ~/Library/CloudStorage providers.
//
// How to add a rule:
// - Declare its kind here: `extension UnitKind { static let appCache = UnitKind(rawValue: "app-cache") }`.
//   The raw value is persisted in keys; never rename it after release.
// - Append a `UnitRule(kind:resolve:name:)` to `apps`. `resolve` returns the unit
//   root or nil; `name` names a root of that kind.
// - To only rename an existing core unit without changing its key (so no history
//   splits), add a name-only rule of that core kind, e.g.
//   `UnitRule(kind: .library, name: { root in ... })`, returning nil for roots it
//   does not cover. Pack rules are asked before the core namer.
// - `UnitNamer.appDisplayName(_:)` turns bundle ids into app names (via
//   `GrowthCategory.cacheApplicationDisplayName`).
//
// Order: this pack resolves after the developer and media packs, before the
// generic ~/Library and place fallbacks.

extension UnitKind {
    /// `~/Library/Application Support/Steam/steamapps/common/<Game>`.
    static let steamGame = UnitKind(rawValue: "steam-game")
    /// Mail attachment folders below `~/Library/Mail`, rooted at the `Attachments` folder.
    static let mailAttachments = UnitKind(rawValue: "mail-attachments")
    /// `~/Library/Messages/Attachments`.
    static let messagesAttachments = UnitKind(rawValue: "messages-attachments")
    /// `~/Library/CloudStorage/<Provider-Account>`.
    static let cloudStorage = UnitKind(rawValue: "cloud-storage")
}

extension UnitRules {
    static let apps: [UnitRule] = [
        steamGameRule,
        mailAttachmentsRule,
        messagesAttachmentsRule,
        cloudStorageRule,
        appLibraryNameRule
    ]

    /// Steam game folder → "<Game> · Steam".
    static let steamGameRule = UnitRule(
        kind: .steamGame,
        resolve: { path in
            guard let rel = path.lowercasedRelative, rel.count >= 6,
                  rel[0] == "library", rel[1] == "application support", rel[2] == "steam",
                  rel[3] == "steamapps", rel[4] == "common" else { return nil }
            return path.homeRoot(depth: 6)
        },
        name: { root in
            guard let rel = root.relative, rel.count >= 6, let game = UnitNamer.displayComponent(rel[5]) else {
                return UnitName(title: "Steam", category: .other)
            }
            return UnitName(title: "\(game) \u{00B7} Steam", category: GrowthCategory.categorize(path: root.path))
        }
    )

    /// Anything below an `Attachments` folder inside `~/Library/Mail`.
    static let mailAttachmentsRule = UnitRule(
        kind: .mailAttachments,
        resolve: { path in
            guard let rel = path.lowercasedRelative, rel.count >= 3,
                  rel[0] == "library", rel[1] == "mail",
                  let index = rel.dropFirst(2).firstIndex(of: "attachments") else { return nil }
            return path.homeRoot(depth: index + 1)
        },
        name: { root in
            UnitName(title: "Mail attachments", category: GrowthCategory.categorize(path: root.path))
        }
    )

    /// `~/Library/Messages/Attachments/...`.
    static let messagesAttachmentsRule = UnitRule(
        kind: .messagesAttachments,
        resolve: { path in
            guard let rel = path.lowercasedRelative, rel.count >= 3,
                  rel[0] == "library", rel[1] == "messages", rel[2] == "attachments" else { return nil }
            return path.homeRoot(depth: 3)
        },
        name: { root in
            UnitName(title: "Messages attachments", category: GrowthCategory.categorize(path: root.path))
        }
    )

    /// `~/Library/CloudStorage/<Provider-Account>` → "<Provider> files".
    static let cloudStorageRule = UnitRule(
        kind: .cloudStorage,
        resolve: { path in
            guard let rel = path.lowercasedRelative, rel.count >= 3,
                  rel[0] == "library", rel[1] == "cloudstorage" else { return nil }
            return path.homeRoot(depth: 3)
        },
        name: { root in
            let category = GrowthCategory.categorize(path: root.path)
            guard let rel = root.relative, rel.count >= 3 else {
                return UnitName(title: "Cloud files", category: category)
            }
            return UnitName(title: "\(UnitRules.cloudProviderName(rel[2])) files", category: category)
        }
    )

    /// Name-only rule for core `library` roots (`~/Library/<Area>/<X>`; keys unchanged):
    /// Caches → "<App> cache", Containers and Group Containers → "<App> data",
    /// Mail and Messages → "Mail" / "Messages". Application Support keeps the core name.
    static let appLibraryNameRule = UnitRule(
        kind: .library,
        name: { root in
            guard let rel = root.relative, rel.count >= 2, rel[0].lowercased() == "library" else { return nil }
            let category = GrowthCategory.categorize(path: root.path)
            switch rel[1].lowercased() {
            case "mail":
                return UnitName(title: "Mail", category: category)
            case "messages":
                return UnitName(title: "Messages", category: category)
            case "caches":
                guard rel.count >= 3, let app = UnitNamer.appDisplayName(rel[2]) else { return nil }
                return UnitName(title: "\(app) cache", detail: "Caches", category: category)
            case "containers", "group containers":
                guard rel.count >= 3, let app = UnitNamer.appDisplayName(rel[2]) else { return nil }
                return UnitName(title: "\(app) data", detail: UnitNamer.displayComponent(rel[1]), category: category)
            default:
                return nil
            }
        }
    )

    /// "GoogleDrive-me@x.com" → "Google Drive", "OneDrive-Personal" → "OneDrive".
    static func cloudProviderName(_ folder: String) -> String {
        let provider = folder.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folder
        let known = ["googledrive": "Google Drive", "onedrive": "OneDrive", "dropbox": "Dropbox",
                     "box": "Box", "icloud": "iCloud", "pcloud": "pCloud", "nextcloud": "Nextcloud"]
        if let name = known[provider.lowercased()] { return name }
        // Split camel case: "ProtonDrive" → "Proton Drive".
        var spaced = ""
        for (i, ch) in provider.enumerated() {
            if i > 0, ch.isUppercase, !(provider[provider.index(provider.startIndex, offsetBy: i - 1)].isUppercase) {
                spaced.append(" ")
            }
            spaced.append(ch)
        }
        return UnitNamer.displayComponent(spaced) ?? "Cloud"
    }
}
