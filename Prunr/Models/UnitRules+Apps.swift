import Foundation

// App unit rules (slice s6): Steam games, Mail and Messages attachments and
// ~/Library/CloudStorage providers. Places below ~/Library/<Area>/<item> are
// core `library` units, named by `UnitRules.libraryName(for:)` with the app as owner.
//
// How to add a rule:
// - Declare its kind here: `extension UnitKind { static let appCache = UnitKind(rawValue: "app-cache") }`.
//   The raw value is persisted in keys; never rename it after release.
// - Append a `UnitRule(kind:resolve:name:)` to `apps`. `resolve` returns the unit
//   root or nil; `name` names a root of that kind and sets the owner when an app owns it.
// - To only rename an existing core unit without changing its key (so no history
//   splits), add a name-only rule of that core kind, e.g.
//   `UnitRule(kind: .library, name: { root in ... })`, returning nil for roots it
//   does not cover. Pack rules are asked before the core namer.
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
        cloudStorageRule
    ]

    /// Steam game folder → "<Game>", owned by Steam.
    static let steamGameRule = UnitRule(
        kind: .steamGame,
        resolve: { path in
            guard let rel = path.lowercasedRelative, rel.count >= 6,
                  rel[0] == "library", rel[1] == "application support", rel[2] == "steam",
                  rel[3] == "steamapps", rel[4] == "common" else { return nil }
            return path.homeRoot(depth: 6)
        },
        name: { root in
            let owner = UnitOwner.named("Steam")
            guard let rel = root.relative, rel.count >= 6, let game = UnitNamer.displayComponent(rel[5]) else {
                return UnitName(title: "Games", category: root.category, icon: .steam, owner: owner)
            }
            return UnitName(title: game, category: root.category, icon: .steam, owner: owner)
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
            UnitName(
                title: "Attachments", category: root.category, icon: .mail, owner: .app(id: "com.apple.mail")
            )
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
            UnitName(
                title: "Attachments", category: root.category, icon: .messages, owner: .app(id: "com.apple.MobileSMS")
            )
        }
    )

    /// `~/Library/CloudStorage/<Provider-Account>` → "Files", owned by the provider.
    static let cloudStorageRule = UnitRule(
        kind: .cloudStorage,
        resolve: { path in
            guard let rel = path.lowercasedRelative, rel.count >= 3,
                  rel[0] == "library", rel[1] == "cloudstorage" else { return nil }
            return path.homeRoot(depth: 3)
        },
        name: { root in
            guard let rel = root.relative, rel.count >= 3 else {
                return UnitName(title: "Cloud files", category: root.category)
            }
            let owner = UnitOwner.named(UnitRules.cloudProviderName(rel[2]))
            return UnitName(title: "Files", category: root.category, icon: .owner(owner), owner: owner)
        }
    )

    /// "GoogleDrive-me@x.com" → "Google Drive", "OneDrive-Personal" → "OneDrive".
    static func cloudProviderName(_ folder: String) -> String {
        let provider = folder.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folder
        let known = ["googledrive": "Google Drive", "onedrive": "OneDrive", "dropbox": "Dropbox",
                     "box": "Box", "icloud": "iCloud", "pcloud": "pCloud", "nextcloud": "Nextcloud"]
        if let name = known[provider.lowercased()] { return name }
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
