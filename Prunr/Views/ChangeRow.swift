import SwiftUI

struct ChangeRow: View {
    let episode: ChangeEpisode
    let onOpen: (ChangeEpisode) -> Void
    let onReveal: (String) -> Void
    var calendar: Calendar = .current

    @State private var isHovering = false

    var body: some View {
        if FeedPage.opensContents(episode) {
            Button { onOpen(episode) } label: {
                content(opens: true)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
            .pathContextMenu(episode.rootPath, onShowInFinder: onReveal)
            .accessibilityHint("Shows what is in this place")
            .accessibilityAddTraits(.isButton)
        } else {
            content(opens: false)
        }
    }

    private func content(opens: Bool) -> some View {
        HStack(spacing: 10) {
            UnitIconTile(category: episode.category, source: episode.iconSource, size: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let time {
                    Text(time)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(signedBytes(episode.netBytes))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(changeAmountStyle(episode.netBytes))
                .lineLimit(1)
                .fixedSize()

            if opens {
                ListChevron()
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: time == nil ? 34 : 44)
        .background(ListRowHoverBackground(isHovering: opens && isHovering))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var title: String { EpisodeBuilder.rowTitle(for: episode) }

    private var time: String? { EpisodeBuilder.timeCaption(for: episode, calendar: calendar) }

    private var accessibilityText: String {
        [title, time, spokenChangeAmount(episode.netBytes)].compactMap { $0 }.joined(separator: ", ")
    }
}

func changeAmountStyle(_ netBytes: Int64) -> AnyShapeStyle {
    if EpisodeBuilder.isLargeGrowth(netBytes) {
        return AnyShapeStyle(Color.orange)
    }
    return netBytes < 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
}

func signedBytes(_ bytes: Int64) -> String {
    "\(bytes < 0 ? "\u{2212}" : "+")\(formattedBytes(abs(bytes)))"
}

func spokenChangeAmount(_ bytes: Int64) -> String {
    "\(bytes < 0 ? "down" : "up") \(formattedBytes(abs(bytes)))"
}
