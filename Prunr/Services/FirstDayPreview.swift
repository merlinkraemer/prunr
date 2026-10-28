import Foundation

enum FirstDayPreview {
    private struct Row {
        let path: String
        let netBytes: Int64
        let daysAgo: Int
        let hour: Int
        let minute: Int
    }

    private static let rows = [
        Row(path: "/Users/alex/Downloads/ubuntu-24.04.1-arm64.iso", netBytes: 3_100_000_000, daysAgo: 1, hour: 18, minute: 12),
        Row(path: "/Users/alex/Library/Developer/CoreSimulator/Devices/5E1C0B7A/data/Containers/Data/Weatherly.sqlite",
            netBytes: 7_800_000_000, daysAgo: 2, hour: 10, minute: 31),
        Row(path: "/Applications/Steam.app/Contents/MacOS/steam_osx", netBytes: 1_900_000_000, daysAgo: 3, hour: 20, minute: 4),
        Row(path: "/Users/alex/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/archive/pc/content/basegame_1.archive",
            netBytes: 12_400_000_000, daysAgo: 3, hour: 20, minute: 48),
        Row(path: "/Users/alex/Movies/Holiday 2026/IMG_2041.mov", netBytes: 5_600_000_000, daysAgo: 5, hour: 22, minute: 9),
        Row(path: "/Users/alex/Pictures/Photos Library.photoslibrary/originals/A/A1B2.heic",
            netBytes: 2_700_000_000, daysAgo: 6, hour: 21, minute: 35),
        Row(path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Google Chrome Framework",
            netBytes: 1_300_000_000, daysAgo: 8, hour: 9, minute: 50),
        Row(path: "/Users/alex/Documents/Archive/Tax 2025/scans.zip", netBytes: 1_600_000_000, daysAgo: 11, hour: 14, minute: 22),
        Row(path: "/Users/alex/Library/Developer/Xcode/DerivedData/Weatherly-bxkqhfzlygrjeqgdbsjnpwhqdyvm/Build/Products/Weatherly.app",
            netBytes: 4_200_000_000, daysAgo: 14, hour: 16, minute: 41),
        Row(path: "/Users/alex/Downloads/Xcode_26.4.xip", netBytes: 3_300_000_000, daysAgo: 17, hour: 11, minute: 15),
        Row(path: "/Users/alex/Movies/Screen Recordings/demo-walkthrough.mov", netBytes: 2_100_000_000, daysAgo: 19, hour: 17, minute: 3),
        Row(path: "/Users/alex/Pictures/Photos Library.photoslibrary/originals/B/C3D4.heic",
            netBytes: 1_500_000_000, daysAgo: 24, hour: 19, minute: 58)
    ]

    static func feed(now: Date, calendar: Calendar = .current) -> ChangeFeed {
        let today = calendar.startOfDay(for: now)
        let weekStart = GrowthJournalService.weekStart(now: now, calendar: calendar)
        let episodes = rows.map { row -> ChangeEpisode in
            let day = calendar.date(byAdding: .day, value: -row.daysAgo, to: today) ?? today
            let time = calendar.date(bySettingHour: row.hour, minute: row.minute, second: 0, of: day) ?? day
            return MarketingSample.episode(row.path, row.netBytes, at: time)
        }
        let days = Dictionary(grouping: episodes, by: \.day)
            .map { ChangeFeedDay(day: $0.key, episodes: $0.value.sorted { $0.time > $1.time }) }
            .sorted { $0.day > $1.day }
        let weekNet = episodes.filter { $0.day >= weekStart }.reduce(Int64(0)) { $0 + $1.netBytes }
        return ChangeFeed(days: days, weekNetBytes: weekNet, watchingSince: now, hasFileHistory: true)
            .resolvingOwners(with: MarketingSample.catalog)
    }
}
