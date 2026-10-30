import AppKit
import SwiftUI
@testable import Prunr

enum PanelSnapshotPage {
    case main(ChangeFeed)
    case group(ChangeGroup)
    case contents(ChangeGroup, ChangeEpisode, PlaceContentsPage)
}

struct PanelSnapshotMetrics {
    var totalBytes: Int64 = 1_000_000_000_000
    var freeBytes: Int64 = 186_400_000_000
    var home = "/Users/tester"
    var now = Date()
}

private struct SnapshotPanel: View {
    let page: PanelSnapshotPage
    let metrics: PanelSnapshotMetrics

    var body: some View {
        VStack(spacing: 0) {
            ChangesHeaderView(onOpenBar: nil) {
                DriveBarView(
                    totalBytes: metrics.totalBytes,
                    usedBytes: metrics.totalBytes - metrics.freeBytes,
                    freeBytes: metrics.freeBytes,
                    highlightedSegmentID: .constant(nil),
                    disableHover: true
                )
            } row: {
                headerRow
            }

            Divider()

            ZStack(alignment: .bottom) {
                content
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .softBottomEdge()
                    .clipped()
                footer
            }
        }
        .frame(width: 320, height: 480)
    }

    @ViewBuilder
    private var headerRow: some View {
        switch page {
        case .main(let feed):
            WeeklyChangeRow(weekly: WeeklyChange(.loaded(feed), now: metrics.now))
        case .group(let group):
            HeaderTitleRow(
                title: group.owner.displayName,
                category: group.category,
                iconSource: group.isNamedOwner ? group.rowIconSource : nil,
                backHint: "",
                onBack: {}
            )
        case .contents(let group, let place, _):
            HeaderTitleRow(
                title: group.headerTitle(for: place),
                category: place.category,
                iconSource: group.headerIconSource(for: place),
                backHint: "",
                onBack: {}
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .main(let feed):
            ChangeFeedRows(feed: feed, now: metrics.now, expandedDays: .constant([]), onOpenGroup: { _ in })
        case .group(let group):
            ChangeGroupRows(group: group, onOpenPlace: { _ in }, onReveal: { _ in })
        case .contents(let group, let place, let contents):
            PlaceContentsRows(
                category: group.category,
                caption: EpisodeBuilder.contentsCaption(
                    for: place,
                    headerTitle: group.headerTitle(for: place),
                    home: metrics.home
                ),
                children: contents.children,
                status: contents.children.isEmpty ? .empty : nil,
                hasMore: contents.hasMore,
                isLoadingMore: false,
                onShowMore: {},
                onRetry: {},
                onReveal: { _ in }
            )
        }
    }

    private var footer: some View {
        Text("Snapshot")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: SoftBottomEdge.footerHeight)
    }
}

private struct SnapshotFrame: View {
    static let margin: CGFloat = 24

    let page: PanelSnapshotPage
    let metrics: PanelSnapshotMetrics
    let colorScheme: ColorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let fill = colorScheme == .dark
            ? Color(red: 0.165, green: 0.165, blue: 0.175)
            : Color(red: 0.965, green: 0.965, blue: 0.965)
        SnapshotPanel(page: page, metrics: metrics)
            .clipShape(shape)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(.gray.opacity(0.4), lineWidth: 1))
            .padding(Self.margin)
            .background(colorScheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, colorScheme)
    }
}

enum PanelSnapshot {
    struct RenderFailure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func png(
        _ page: PanelSnapshotPage,
        metrics: PanelSnapshotMetrics = PanelSnapshotMetrics(),
        colorScheme: ColorScheme = .dark,
        scale: CGFloat = 2
    ) throws -> Data {
        let renderer = ImageRenderer(content: SnapshotFrame(page: page, metrics: metrics, colorScheme: colorScheme))
        renderer.scale = scale
        renderer.isOpaque = true

        var cgImage: CGImage?
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        if let appearance {
            appearance.performAsCurrentDrawingAppearance { cgImage = renderer.cgImage }
        } else {
            cgImage = renderer.cgImage
        }
        guard let cgImage,
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else {
            throw RenderFailure(description: "SwiftUI produced no image")
        }
        return data
    }

    @MainActor
    static func writePanels(
        of result: ReplayResult,
        to directory: URL,
        metrics: PanelSnapshotMetrics,
        groupLimit: Int,
        colorScheme: ColorScheme = .dark
    ) throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [String] = []
        func save(_ page: PanelSnapshotPage, _ name: String) throws {
            try png(page, metrics: metrics, colorScheme: colorScheme).write(to: directory.appendingPathComponent(name + ".png"))
            written.append(name)
        }

        try save(.main(result.feed), "main")
        var index = 0
        for day in result.feed.days {
            for group in day.groups {
                guard index < groupLimit else { return written }
                index += 1
                let prefix = String(format: "%02d", index)
                try save(.group(group), "\(prefix)-group")
                for (placeIndex, place) in group.episodes.enumerated() {
                    guard let page = result.contentsByEpisodeID[place.id] else { continue }
                    try save(.contents(group, place, page), "\(prefix)-place-\(placeIndex + 1)")
                }
            }
        }
        return written
    }
}
