import AppKit
import SwiftUI

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

    static func panelPNG(page: MarketingPanelPage, colorScheme: ColorScheme, scale: CGFloat = 2) throws -> Data {
        let renderer = ImageRenderer(content: MarketingPanelShot(page: page, colorScheme: colorScheme))
        renderer.scale = scale
        renderer.isOpaque = false

        var cgImage: CGImage?
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        if let appearance {
            appearance.performAsCurrentDrawingAppearance { cgImage = renderer.cgImage }
        } else {
            cgImage = renderer.cgImage
        }
        guard let cgImage,
              let pngData = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else {
            throw RenderError("SwiftUI did not produce a PNG image for \(page.rawValue)")
        }
        return pngData
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
        case .overview, .drilldown, .contents:
            MarketingPanel(page: scene.panelPage)
                .marketingGlass(cornerRadius: 24)
                .frame(width: 320, height: 480)
                .scaleEffect(1.55, anchor: .topTrailing)
                .frame(width: 520, height: 760, alignment: .topTrailing)
        case .settings:
            MarketingSettingsPreview()
                .marketingGlass(cornerRadius: 22)
                .frame(width: 560, height: 480)
                .scaleEffect(1.22, anchor: .topTrailing)
                .frame(width: 690, height: 620, alignment: .topTrailing)
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

enum MarketingPanelPage: String, CaseIterable {
    case main
    case app
    case contents
}

struct MarketingPanel: View {
    let page: MarketingPanelPage

    private var segments: [DriveBarSegment] {
        let categories = MarketingSample.categories(endedAt: MarketingSample.now)
            .filter { $0.currentSizeBytes > 0 }
            .sorted { $0.currentSizeBytes > $1.currentSizeBytes }
        var segments = categories.map {
            DriveBarSegment(id: $0.category.rawValue, bytes: $0.currentSizeBytes, color: $0.category.color)
        }
        let outsideScope = MarketingSample.usedBytes - categories.reduce(Int64(0)) { $0 + $1.currentSizeBytes }
        if outsideScope > 0 {
            segments.append(DriveBarSegment(id: "outside-scope", bytes: outsideScope, color: Color.gray.opacity(0.55)))
        }
        return segments
    }

    var body: some View {
        VStack(spacing: 0) {
            ChangesHeaderView(onOpenBar: nil) {
                DriveBarView(
                    totalBytes: MarketingSample.totalBytes,
                    usedBytes: MarketingSample.usedBytes,
                    freeBytes: MarketingSample.freeBytes,
                    categorySegments: segments,
                    highlightedSegmentID: .constant(nil),
                    disableHover: true
                )
            } row: {
                headerRow
            }

            Divider()

            ZStack(alignment: .bottom) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .softBottomEdge()
                    .clipped()

                MarketingFooter(status: footerStatus)
            }
        }
        .frame(width: 320, height: 480)
    }

    @ViewBuilder
    private var headerRow: some View {
        switch page {
        case .main:
            WeeklyChangeRow(weekly: WeeklyChange(.loaded(MarketingSample.feed), now: MarketingSample.now))
        case .app:
            let group = MarketingSample.appGroup
            HeaderTitleRow(
                title: group.owner.displayName,
                category: group.category,
                iconSource: group.isNamedOwner ? group.rowIconSource : nil,
                backHint: "",
                onBack: {}
            )
        case .contents:
            let group = MarketingSample.contentsGroup
            if let place = group.episodes.first {
                HeaderTitleRow(
                    title: group.headerTitle(for: place),
                    category: place.category,
                    iconSource: group.headerIconSource(for: place),
                    backHint: "",
                    onBack: {}
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .main:
            ChangeFeedRows(
                feed: MarketingSample.feed,
                now: MarketingSample.now,
                expandedDays: .constant([]),
                onOpenGroup: { _ in }
            )
        case .app:
            ChangeGroupRows(group: MarketingSample.appGroup, onOpenPlace: { _ in }, onReveal: { _ in })
        case .contents:
            let group = MarketingSample.contentsGroup
            PlaceContentsRows(
                category: group.category,
                caption: group.episodes.first.flatMap {
                    EpisodeBuilder.contentsCaption(
                        for: $0,
                        headerTitle: group.headerTitle(for: $0),
                        home: MarketingSample.home
                    )
                },
                children: MarketingSample.contents,
                status: nil,
                hasMore: false,
                isLoadingMore: false,
                onShowMore: {},
                onRetry: {},
                onReveal: { _ in }
            )
        }
    }

    private var footerStatus: FooterStatus {
        switch page {
        case .main: return MarketingSample.footerStatus
        case .app: return .groupDay(MarketingSample.appGroup.day)
        case .contents: return .groupDay(MarketingSample.contentsGroup.day)
        }
    }
}

private struct MarketingFooter: View {
    let status: FooterStatus

    var body: some View {
        ZStack {
            Text(status.text(now: MarketingSample.now))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                footerIcon("arrow.clockwise")
                Spacer()
                footerIcon("gearshape")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: SoftBottomEdge.footerHeight)
    }

    private func footerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .frame(width: 26, height: 26)
    }
}

private struct MarketingPanelShot: View {
    static let margin: CGFloat = 24
    static let cornerRadius: CGFloat = 12

    let page: MarketingPanelPage
    let colorScheme: ColorScheme

    private var fill: Color {
        colorScheme == .dark
            ? Color(red: 0.165, green: 0.165, blue: 0.175)
            : Color(red: 0.965, green: 0.965, blue: 0.965)
    }

    private var stroke: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.12)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        MarketingPanel(page: page)
            .background(fill)
            .clipShape(shape)
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 14, y: 6)
            .padding(Self.margin)
            .environment(\.colorScheme, colorScheme)
    }
}

private struct MarketingSettingsPreview: View {
    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Prunr \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(SettingsTab.visibleTabs(devMode: false), id: \.self) { tab in
                    settingsTab(tab.systemImage, title: tab.title, selected: tab == .general)
                }
            }
            .padding(.horizontal, 28)
            .frame(height: 94)

            Divider().overlay(.white.opacity(0.13))

            VStack(alignment: .leading, spacing: 18) {
                section("Startup") {
                    HStack {
                        Text("Launch Prunr at login")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        toggle
                    }
                }

                section("Updates") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Check for updates automatically")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            toggle
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(versionText)
                                    .font(.system(size: 13, weight: .medium))
                                Text("Up to date.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.52))
                            }
                            Spacer()
                            Text("Check Now")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.blue)
                        }
                    }
                }

                section("History") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Prunr keeps \(GrowthJournalService.historyWindowDays) days of changes")
                                .font(.system(size: 13, weight: .medium))
                            Text("Older days drop off the list on their own.")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.52))
                        }
                        Spacer()
                        Text(EpisodeBuilder.watchingSinceLabel(MarketingSample.watchingSince, calendar: .current))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                }

                Spacer()
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(28)
        }
        .frame(width: 560, height: 480)
    }

    private var toggle: some View {
        Capsule()
            .fill(.blue)
            .frame(width: 38, height: 22)
            .overlay(alignment: .trailing) {
                Circle().fill(.white).padding(3)
            }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
            content()
                .padding(14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
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
    case contents
    case settings

    var panelPage: MarketingPanelPage {
        switch self {
        case .overview, .settings: return .main
        case .drilldown: return .app
        case .contents: return .contents
        }
    }
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
                    throw RenderError("--scene must be overview, drilldown, contents, or settings")
                }
                scene = value
                index += 2
            default:
                throw RenderError("unknown argument: \(arguments[index])")
            }
        }

        guard let outputPath, !outputPath.isEmpty else {
            throw RenderError("usage: render-screenshot --output /path/to/image.png [--scene overview|drilldown|contents|settings] [--scale 2]")
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
