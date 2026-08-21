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

private struct MarketingPopoverPreview: View {
    let manager: MenuBarManager

    private var categories: [CategoryInventoryItem] {
        manager.sortedCategories
    }

    private var totalGrowth: Int64 {
        manager.overallGrowthBytes
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(categories) { category in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(category.category.color)
                        .frame(width: segmentWidth(for: category))
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(height: 64)

            Divider().overlay(.white.opacity(0.13))

            HStack(spacing: 6) {
                Label(
                    "\(totalGrowth > 0 ? "+" : "\u{2212}")\(formattedBytes(abs(totalGrowth)))",
                    systemImage: totalGrowth > 0 ? "arrow.up.right" : "arrow.down.right"
                )
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.orange.opacity(0.14), in: Capsule())
                Text("last \(GrowthJournalService.displayWindowDays) days")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.48))
            }
            .frame(height: 44)

            VStack(spacing: 0) {
                ForEach(categories) { category in
                    HStack(spacing: 10) {
                        Image(systemName: category.category.icon)
                            .font(.system(size: 15))
                            .foregroundStyle(category.category.color)
                            .frame(width: 18)

                        Text(category.category.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(formattedBytes(category.currentSizeBytes))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                            if let delta = category.renderableGrowthDeltaBytes {
                                Label(
                                    "\(delta > 0 ? "+" : "\u{2212}")\(formattedBytes(abs(delta)))",
                                    systemImage: delta > 0 ? "arrow.up.right" : "arrow.down.right"
                                )
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(delta > 0 ? Color.orange : Color.secondary)
                            }
                        }
                        .foregroundStyle(.white.opacity(0.88))

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.34))
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 42)
                }
            }

            Spacer(minLength: 0)

            ZStack {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Spacer()
                    Image(systemName: "gearshape")
                }
                Text("Tracking")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
            }
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 18)
            .frame(height: 50)
        }
        .frame(width: 320, height: 480)
    }

    private func segmentWidth(for category: CategoryInventoryItem) -> CGFloat {
        let total = max(1, categories.reduce(Int64(0)) { $0 + $1.currentSizeBytes })
        return max(5, 244 * CGFloat(Double(category.currentSizeBytes) / Double(total)))
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
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
