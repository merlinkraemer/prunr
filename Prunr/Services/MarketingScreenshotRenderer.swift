import AppKit
import SwiftUI

/// Renders a marketing-ready image from the real popover view at a controlled
/// backing scale. This avoids the resolution ceiling of a screen capture.
@MainActor
enum MarketingScreenshotRenderer {
    static func run(arguments: [String]) -> Int32 {
        do {
            let config = try Config(arguments: arguments)
            let manager = MenuBarManager.shared ?? MenuBarManager()
            manager.applyScreenshotPreviewContent()

            let renderer = ImageRenderer(content: MarketingScreenshotCanvas(manager: manager, scene: config.scene))
            renderer.scale = config.scale
            renderer.isOpaque = true

            guard
                let image = renderer.nsImage,
                let tiffData = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiffData),
                let pngData = bitmap.representation(using: .png, properties: [:])
            else {
                throw RenderError("SwiftUI did not produce a PNG image")
            }

            try FileManager.default.createDirectory(
                at: config.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pngData.write(to: config.outputURL)
            print("marketing screenshot: \(config.outputURL.path)")
            print("dimensions: \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
            return 0
        } catch {
            fputs("[screenshot] \(error.localizedDescription)\n", stderr)
            return 2
        }
    }
}

private struct MarketingScreenshotCanvas: View {
    let manager: MenuBarManager
    let scene: Scene

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.06, blue: 0.12),
                    Color(red: 0.055, green: 0.20, blue: 0.25),
                    Color(red: 0.09, green: 0.10, blue: 0.22)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color(red: 0.13, green: 0.72, blue: 0.67).opacity(0.42))
                .frame(width: 920, height: 920)
                .blur(radius: 130)
                .offset(x: -650, y: 500)

            Circle()
                .fill(Color(red: 0.94, green: 0.40, blue: 0.36).opacity(0.28))
                .frame(width: 700, height: 700)
                .blur(radius: 120)
                .offset(x: 650, y: -460)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.mint)
                    Text("Prunr")
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 38)
                .frame(height: 56)
                .background(.black.opacity(0.22))

                Spacer()
            }

            HStack {
                Spacer()

                screenshotSurface
            }
            .padding(.trailing, 106)
            .padding(.top, 52)
        }
        .frame(width: 1920, height: 1080)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var screenshotSurface: some View {
        switch scene {
        case .overview:
            MarketingPopoverPreview(manager: manager)
                .marketingGlass(cornerRadius: 24)
                .frame(width: 320, height: 480)
                .scaleEffect(1.55, anchor: .topTrailing)
                .frame(width: 520, height: 760, alignment: .topTrailing)
        case .drilldown:
            MarketingDrilldownPreview()
                .marketingGlass(cornerRadius: 24)
                .frame(width: 320, height: 480)
                .scaleEffect(1.55, anchor: .topTrailing)
                .frame(width: 520, height: 760, alignment: .topTrailing)
        case .settings:
            MarketingSettingsPreview()
                .marketingGlass(cornerRadius: 22)
                .frame(width: 520, height: 480)
                .scaleEffect(1.22, anchor: .topTrailing)
                .frame(width: 680, height: 620, alignment: .topTrailing)
        }
    }
}

private extension View {
    func marketingGlass(cornerRadius: CGFloat) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.38), radius: 42, y: 22)
    }
}

/// The panel as it opens: the real header and change rows over the sample
/// week. The rows are laid out without the scroll view (`ImageRenderer` leaves
/// it blank) and clipped at the panel's height, like the real list.
private struct MarketingPopoverPreview: View {
    let manager: MenuBarManager

    private var segments: [DriveBarSegment] {
        let categories = manager.sortedCategories.filter { $0.currentSizeBytes > 0 }
        var segments = categories.map {
            DriveBarSegment(id: $0.category.rawValue, bytes: $0.currentSizeBytes, color: $0.category.color)
        }
        let outsideScope = manager.usedBytes - categories.reduce(Int64(0)) { $0 + $1.currentSizeBytes }
        if outsideScope > 0 {
            segments.append(DriveBarSegment(id: "outside-scope", bytes: outsideScope, color: Color.gray.opacity(0.55)))
        }
        return segments
    }

    var body: some View {
        VStack(spacing: 0) {
            ChangesHeaderView(onOpenBar: nil) {
                DriveBarView(
                    totalBytes: manager.totalBytes,
                    usedBytes: manager.usedBytes,
                    freeBytes: manager.freeBytes,
                    categorySegments: segments,
                    highlightedSegmentID: .constant(nil),
                    disableHover: true
                )
            } row: {
                WeeklyChangeRow(weekly: WeeklyChange(manager.changeFeed, now: MarketingSample.now))
            }

            Divider().overlay(.white.opacity(0.13))

            ChangeFeedRows(
                feed: manager.changeFeed?.feed ?? .empty,
                now: MarketingSample.now,
                expandedDays: .constant([]),
                onOpenGroup: { _ in }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .softBottomEdge()
            .clipped()
            .overlay(alignment: .bottom) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Spacer()
                    Image(systemName: "gearshape")
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 20)
                .frame(height: SoftBottomEdge.footerHeight)
            }
        }
        .frame(width: 320, height: 480)
    }
}

/// Privacy-safe sample content for the marketing screenshot: a busy week on a
/// 2 TB Mac with 19 GB left, as in mockup S1. Fixed to Thursday 8 Oct 2026,
/// 09:12 local time, so the days read Wed 7 Oct back to Thu 1 Oct.
enum MarketingSample {
    static let totalBytes: Int64 = 2_000_000_000_000
    static let freeBytes: Int64 = 19_000_000_000
    /// The header: everything this week, rows or not.
    static let weekNetBytes: Int64 = 48_000_000_000

    private static let calendar = Calendar.current

    static let now: Date = date(day: 8, hour: 9, minute: 12)
    /// Long before the shown 30 days, so the list has no "Watching since" end.
    static let watchingSince: Date = date(month: 8, day: 1, hour: 9, minute: 0)

    /// Newest first. Mail built up over days; the rest moved in one go. Each
    /// category's rows this week add up to its change in `categories`, and
    /// Monday has four categories, so it shows "Show all (4)".
    static let rows: [ChangeEpisode] = [
        episode("xcode", "Xcode build files", detail: "Prunr", .developer,
                "/Users/sample/Library/Developer/Xcode/DerivedData", 6_900_000_000, day: 7, hour: 17, minute: 5),
        episode("docker", "Docker disk", detail: nil, .developer,
                "/Users/sample/Library/Containers/com.docker.docker", 31_000_000_000, day: 6, hour: 14, minute: 20),
        episode("recordings", "Screen recordings", detail: "Movies", .mediaAndDocuments,
                "/Users/sample/Movies", 1_200_000_000, day: 6, hour: 11, minute: 30),
        episode("iso", "Downloads", detail: "ubuntu-24.04.1-desktop-amd64.iso", .downloads,
                "/Users/sample/Downloads/ubuntu-24.04.1-desktop-amd64.iso", 5_000_000_000, day: 5, hour: 21, minute: 40),
        episode("safari", "Safari data", detail: "Caches", .cachesAndSystem,
                "/Users/sample/Library/Caches/com.apple.Safari", 4_300_000_000, day: 5, hour: 19, minute: 30),
        episode("mail", "Mail attachments", detail: nil, .mediaAndDocuments,
                "/Users/sample/Library/Mail", 1_500_000_000, day: 5, hour: 18, minute: 0,
                buildingSince: date(day: 2, hour: 0, minute: 0)),
        episode("node", "node_modules", detail: "acme", .developer,
                "/Users/sample/dev/acme/node_modules", 2_100_000_000, day: 5, hour: 9, minute: 5),
        episode("trash", "Trash emptied", detail: nil, .trash,
                "/Users/sample/.Trash", -4_000_000_000, day: 4, hour: 10, minute: 15),
        episode("photos", "Photos library", detail: nil, .mediaAndDocuments,
                "/Users/sample/Pictures/Photos Library.photoslibrary", 2_400_000_000, day: 1, hour: 20, minute: 30)
    ]

    static let feed: ChangeFeed = {
        let days = Dictionary(grouping: rows, by: \.day)
            .map { ChangeFeedDay(day: $0.key, episodes: $0.value.sorted { $0.time > $1.time }) }
            .sorted { $0.day > $1.day }
        return ChangeFeed(days: days, weekNetBytes: weekNetBytes, watchingSince: watchingSince)
    }()

    /// The categories view behind the header. Sizes add up to 1,858.6 GB, so
    /// "Not watched" carries the other 122.4 GB; the changes add up to the week.
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
            item(.audioProduction, 640_000_000_000, nil),
            item(.other, 476_800_000_000, nil),
            item(.mediaAndDocuments, 300_000_000_000, 2_700_000_000),
            item(.cachesAndSystem, 228_200_000_000, 4_300_000_000),
            item(.developer, 160_000_000_000, 40_000_000_000),
            item(.applications, 30_000_000_000, nil),
            item(.downloads, 22_400_000_000, 5_000_000_000),
            item(.trash, 1_200_000_000, -4_000_000_000)
        ]
    }

    private static func date(month: Int = 10, day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)) ?? Date()
    }

    private static func episode(
        _ id: String,
        _ title: String,
        detail: String?,
        _ category: GrowthCategory,
        _ rootPath: String?,
        _ netBytes: Int64,
        day: Int,
        hour: Int,
        minute: Int,
        buildingSince: Date? = nil
    ) -> ChangeEpisode {
        let time = date(day: day, hour: hour, minute: minute)
        return ChangeEpisode(
            id: id,
            title: title,
            detail: detail,
            category: category,
            rootPath: rootPath,
            netBytes: netBytes,
            grossBytes: abs(netBytes),
            day: calendar.startOfDay(for: time),
            time: time,
            isApproximateTime: false,
            buildingSince: buildingSince
        )
    }
}


private struct MarketingDrilldownPreview: View {
    private let rows: [(title: String, size: String, growth: String, icon: String)] = [
        ("node_modules", "24.6 GB", "+2.2 GB", "shippingbox.fill"),
        ("Build Artifacts", "18.3 GB", "+1.7 GB", "hammer.fill"),
        ("Git Repositories", "13.1 GB", "+620 MB", "point.3.connected.trianglepath.dotted"),
        ("Python Environments", "9.8 GB", "+280 MB", "chevron.left.forwardslash.chevron.right"),
        ("Databases", "5.7 GB", "+90 MB", "cylinder.fill")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Rectangle().fill(.orange).frame(width: 60)
                Rectangle().fill(.teal).frame(width: 44)
                Rectangle().fill(.pink).frame(width: 28)
                Rectangle().fill(.purple).frame(width: 18)
                Spacer(minLength: 0)
            }
            .clipShape(Capsule())
            .padding(16)
            .frame(height: 64)

            Divider().overlay(.white.opacity(0.13))

            HStack {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26)
                Spacer()
                Label("Developer", systemImage: "hammer.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Color.clear.frame(width: 26)
            }
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 12)
            .frame(height: 44)

            VStack(spacing: 0) {
                ForEach(rows, id: \.title) { row in
                    HStack(spacing: 10) {
                        Image(systemName: row.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                            .frame(width: 18)
                        Text(row.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.size)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                            Label(row.growth, systemImage: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                        .foregroundStyle(.white.opacity(0.88))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.34))
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                }
            }

            Spacer(minLength: 0)

            Text("Developer tools · 71.5 GB")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
                .frame(height: 50)
        }
        .frame(width: 320, height: 480)
    }
}

private struct MarketingSettingsPreview: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                settingsTab("gear", title: "General", selected: true)
                settingsTab("folder", title: "Scan Scope", selected: false)
                settingsTab("wrench.and.screwdriver", title: "Troubleshooting", selected: false)
            }
            .padding(.horizontal, 28)
            .frame(height: 94)

            Divider().overlay(.white.opacity(0.13))

            VStack(alignment: .leading, spacing: 18) {
                Text("General")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))

                VStack(alignment: .leading, spacing: 9) {
                    Text("Startup")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                    HStack {
                        Label("Launch Prunr at Login", systemImage: "power")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Capsule()
                            .fill(.blue)
                            .frame(width: 38, height: 22)
                            .overlay(alignment: .trailing) {
                                Circle().fill(.white).padding(3)
                            }
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("Updates")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Keep Prunr up to date")
                                .font(.system(size: 13, weight: .medium))
                            Text("Automatically checks for new versions")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.52))
                        }
                        Spacer()
                        Text("Check Now")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                    .padding(14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Spacer()
            }
            .padding(28)

            Divider().overlay(.white.opacity(0.13))
            Text("Prunr alpha · Version 0.1.5")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.46))
                .frame(height: 38)
        }
        .frame(width: 520, height: 480)
    }

    private func settingsTab(_ icon: String, title: String, selected: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
        }
        .foregroundStyle(selected ? .white.opacity(0.95) : .white.opacity(0.44))
    }
}

private enum Scene: String {
    case overview
    case drilldown
    case settings
}

private struct Config {
    let outputURL: URL
    let scale: CGFloat
    let scene: Scene

    init(arguments: [String]) throws {
        var outputPath: String?
        var scale: CGFloat = 2
        var scene: Scene = .overview
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--output":
                guard index + 1 < arguments.count else { throw RenderError("--output requires a path") }
                outputPath = arguments[index + 1]
                index += 2
            case "--scale":
                guard index + 1 < arguments.count, let value = Double(arguments[index + 1]), value > 0 else {
                    throw RenderError("--scale must be a positive number")
                }
                scale = CGFloat(value)
                index += 2
            case "--scene":
                guard index + 1 < arguments.count, let value = Scene(rawValue: arguments[index + 1]) else {
                    throw RenderError("--scene must be overview, drilldown, or settings")
                }
                scene = value
                index += 2
            default:
                throw RenderError("unknown argument: \(arguments[index])")
            }
        }

        guard let outputPath, !outputPath.isEmpty else {
            throw RenderError("usage: render-screenshot --output /path/to/image.png [--scene overview|drilldown|settings] [--scale 2]")
        }

        self.outputURL = URL(fileURLWithPath: outputPath)
        self.scale = scale
        self.scene = scene
    }
}

private struct RenderError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
