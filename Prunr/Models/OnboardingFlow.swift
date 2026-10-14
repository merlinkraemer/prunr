import Foundation

enum OnboardingPage: Int, CaseIterable {
    case folder
    case permissions
    case scan

    var number: Int {
        rawValue + 1
    }

    var title: String {
        switch self {
        case .folder:
            return "Folder"
        case .permissions:
            return "Access"
        case .scan:
            return "Scan"
        }
    }

    static func maxUnlocked(folderChosen: Bool, accessGranted: Bool, accessSkipped: Bool) -> OnboardingPage {
        guard folderChosen else { return .folder }
        guard accessGranted || accessSkipped else { return .permissions }
        return .scan
    }
}

struct OnboardingFolderOption: Identifiable, Equatable {
    let id: String
    let title: String
    let badge: String?
    let subtitle: String
    let url: URL

    static func options(home: URL, custom: URL?) -> [OnboardingFolderOption] {
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let fullDisk = URL(fileURLWithPath: "/", isDirectory: true)
        var options = [
            OnboardingFolderOption(
                id: "home",
                title: "Home",
                badge: "Recommended",
                subtitle: displayPath(for: home, home: home),
                url: home
            ),
            OnboardingFolderOption(
                id: "desktop",
                title: "Desktop",
                badge: nil,
                subtitle: displayPath(for: desktop, home: home),
                url: desktop
            ),
            OnboardingFolderOption(
                id: "full-disk",
                title: "Full disk",
                badge: nil,
                subtitle: "/",
                url: fullDisk
            )
        ]

        if let custom, !options.contains(where: { $0.url.standardizedFileURL == custom.standardizedFileURL }) {
            options.insert(
                OnboardingFolderOption(
                    id: "custom",
                    title: "Custom folder",
                    badge: nil,
                    subtitle: displayPath(for: custom, home: home),
                    url: custom
                ),
                at: 0
            )
        }

        return options
    }

    static func displayPath(for url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path

        if path == "/" {
            return "/"
        }
        if path == homePath {
            return "~"
        }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }
}
