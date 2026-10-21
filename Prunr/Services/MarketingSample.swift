import Foundation

enum MarketingSample {
    static let home = "/Users/alex"

    static let totalBytes: Int64 = 1_000_000_000_000
    static let freeBytes: Int64 = 186_400_000_000
    static var usedBytes: Int64 { totalBytes - freeBytes }
    static let weekNetBytes: Int64 = 30_200_000_000

    private static let calendar = Calendar.current

    static let now: Date = date(day: 21, hour: 16, minute: 40)
    static let footerStatus = FooterStatus.resolve(updatedAt: now.addingTimeInterval(-2 * 60))
    static let watchingSince: Date = date(month: 8, day: 3, hour: 9, minute: 0)

    static let catalog = AppCatalog(entries: [
        AppCatalogEntry(
            bundleIdentifier: "com.google.Chrome", name: "Google Chrome",
            names: ["Google Chrome", "Chrome"], path: "/Applications/Google Chrome.app"
        ),
        AppCatalogEntry(bundleIdentifier: "com.spotify.client", name: "Spotify", path: "/Applications/Spotify.app"),
        AppCatalogEntry(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack", path: "/Applications/Slack.app"),
        AppCatalogEntry(bundleIdentifier: "com.valvesoftware.steam", name: "Steam", path: "/Applications/Steam.app"),
        AppCatalogEntry(bundleIdentifier: "com.docker.docker/Data/vms/0/data/Docker.raw", name: "Docker", path: "/Applications/Docker.app")
    ])

    private static let chromeCache = "/Users/alex/Library/Caches/Google/Chrome"
    private static let spotifyCache = "/Users/alex/Library/Caches/com.spotify.client"

    static let rows: [ChangeEpisode] = [
        place("/Users/alex/Library/Developer/Xcode/DerivedData/Weatherly-bxkqhfzlygrjeqgdbsjnpwhqdyvm/Build/Intermediates.noindex/Weatherly.o",
              3_400_000_000, day: 21, hour: 15, minute: 47),
        place(chromeCache + "/Default/Cache/Cache_Data/f_0a81c2", 4_100_000_000, day: 21, hour: 13, minute: 52),
        place("/Users/alex/dev/acme-web/node_modules/next/package.json", 1_800_000_000, day: 21, hour: 11, minute: 5),
        place("/Users/alex/Library/Application Support/Google/Chrome/Default/History", 1_300_000_000, day: 21, hour: 10, minute: 18),
        place("/Users/alex/Library/HTTPStorages/com.google.Chrome/httpstorages.sqlite", 1_100_000_000, day: 21, hour: 10, minute: 2),
        place("/Users/alex/Library/Caches/com.tinyspeck.slackmacgap/Cache.db", 1_400_000_000, day: 21, hour: 9, minute: 30),
        place("/Users/alex/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/archive/pc/content/basegame_1.archive",
              12_400_000_000, day: 20, hour: 21, minute: 15),
        place(spotifyCache + "/Data/0a/0a81c2", 2_300_000_000, day: 20, hour: 18, minute: 40),
        place("/Users/alex/Downloads/ubuntu-24.04.1-arm64.iso", 3_100_000_000, day: 20, hour: 12, minute: 26),
        place("/Users/alex/.Trash/old-backup.zip", -6_800_000_000, day: 19, hour: 17, minute: 5),
        place("/Users/alex/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", 3_500_000_000, day: 19, hour: 14, minute: 20),
        place("/Users/alex/Pictures/Photos Library.photoslibrary/originals/A/IMG_4471.heic", 2_600_000_000, day: 17, hour: 20, minute: 30,
              buildingSince: date(day: 15, hour: 0, minute: 0))
    ]

    static let feed: ChangeFeed = {
        let days = Dictionary(grouping: rows, by: \.day)
            .map { ChangeFeedDay(day: $0.key, episodes: $0.value.sorted { $0.time > $1.time }) }
            .sorted { $0.day > $1.day }
        return ChangeFeed(days: days, weekNetBytes: weekNetBytes, watchingSince: watchingSince)
            .resolvingOwners(with: catalog)
    }()

    static var appGroup: ChangeGroup { group(containing: chromeCache) }

    static var contentsGroup: ChangeGroup { group(containing: spotifyCache) }

    static let contents: [PlaceChild] = [
        PlaceChild(name: "Data", path: spotifyCache + "/Data", isFolder: true,
                   totalBytes: 3_420_000_000, fileCount: 9_812),
        PlaceChild(name: "fsCachedData", path: spotifyCache + "/fsCachedData", isFolder: true,
                   totalBytes: 214_000_000, fileCount: 1_406),
        PlaceChild(name: "Browser", path: spotifyCache + "/Browser", isFolder: true,
                   totalBytes: 96_000_000, fileCount: 312),
        PlaceChild(name: "Cache.db", path: spotifyCache + "/Cache.db", isFolder: false,
                   totalBytes: 41_000_000, fileCount: 1),
        PlaceChild(name: "Cache.db-wal", path: spotifyCache + "/Cache.db-wal", isFolder: false,
                   totalBytes: 8_200_000, fileCount: 1)
    ]

    static func categories(endedAt now: Date) -> [CategoryInventoryItem] {
        let weekStart = GrowthJournalService.weekStart(now: now, calendar: calendar)
        func item(_ category: GrowthCategory, _ size: Int64, _ delta: Int64?) -> CategoryInventoryItem {
            CategoryInventoryItem(
                category: category,
                currentSizeBytes: size,
                recentGrowthStory: delta.map {
                    RecentGrowthStory(category: category, subcategory: nil, deltaBytes: $0, startedAt: weekStart, endedAt: now)
                }
            )
        }
        return [
            item(.developer, 214_000_000_000, 8_700_000_000),
            item(.mediaAndDocuments, 188_000_000_000, 2_600_000_000),
            item(.applications, 96_000_000_000, 12_400_000_000),
            item(.other, 92_000_000_000, nil),
            item(.cachesAndSystem, 74_000_000_000, 10_200_000_000),
            item(.downloads, 41_000_000_000, 3_100_000_000),
            item(.trash, 3_100_000_000, -6_800_000_000)
        ]
    }

    private static func group(containing rootPath: String) -> ChangeGroup {
        for day in feed.days {
            if let group = day.groups.first(where: { $0.episodes.contains { $0.rootPath == rootPath } }) {
                return group
            }
        }
        preconditionFailure("MarketingSample has no row for \(rootPath)")
    }

    private static func date(month: Int = 10, day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)) ?? Date()
    }

    private static func place(
        _ path: String,
        _ netBytes: Int64,
        day: Int,
        hour: Int,
        minute: Int,
        buildingSince: Date? = nil
    ) -> ChangeEpisode {
        let key = UnitResolver.resolveKey(path: path, home: home)
        let name = UnitNamer.name(for: key, home: home)
        let isTrash = key.kind == .trash
        let time = date(day: day, hour: hour, minute: minute)
        let startOfDay = calendar.startOfDay(for: time)
        return ChangeEpisode(
            id: "\(key.rawValue)@\(Int64(startOfDay.timeIntervalSince1970))",
            title: isTrash ? "Trash emptied" : name.title,
            detail: name.context,
            category: name.category,
            rootPath: key.rootPath,
            netBytes: netBytes,
            grossBytes: abs(netBytes),
            day: startOfDay,
            time: time,
            isApproximateTime: false,
            buildingSince: buildingSince,
            iconSource: name.icon == .category && !isTrash ? .file(path: key.rootPath) : name.icon,
            shortTitle: name.shortTitle,
            unitOwner: name.owner
        )
    }
}
