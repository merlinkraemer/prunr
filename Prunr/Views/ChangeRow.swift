import SwiftUI

/// One place in a day group's drilldown: icon, the place on a single line
/// with the clock time under it when known, and the amount flush right.
/// Hovering swaps the amount for a Show in Finder glyph in the same spot;
/// clicking reveals the place. Rows without a place on disk are plain.
struct ChangeRow: View {
    let episode: ChangeEpisode
    let onReveal: (String) -> Void
    var calendar: Calendar = .current

    @State private var isHovering = false

    var body: some View {
        if let rootPath = episode.rootPath {
            Button { onReveal(rootPath) } label: {
                content(showsReveal: isHovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
            .help("Show in Finder")
            .accessibilityHint("Shows this place in Finder")
            .accessibilityAddTraits(.isButton)
        } else {
            content(showsReveal: false)
        }
    }

    private func content(showsReveal: Bool) -> some View {
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

            ZStack(alignment: .trailing) {
                Text(arrowBytes(episode.netBytes))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(changeAmountStyle(episode.netBytes))
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(showsReveal ? 0 : 1)

                RevealInFinderGlyph()
                    .opacity(showsReveal ? 1 : 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: time == nil ? 34 : 44)
        .background(ListRowHoverBackground(isHovering: showsReveal))
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

/// A folder with a small arrow out of its corner: "Show in Finder".
struct RevealInFinderGlyph: View {
    var body: some View {
        Image(systemName: "folder")
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.primary)
                    .offset(x: 3, y: 2)
            }
            .padding(.trailing, 3)
            .accessibilityHidden(true)
    }
}

/// Orange for growth of at least the row line, grey for shrinks, primary for
/// smaller growth.
func changeAmountStyle(_ netBytes: Int64) -> AnyShapeStyle {
    if netBytes >= EpisodeBuilder.rowThresholdBytes {
        return AnyShapeStyle(Color.orange)
    }
    return netBytes < 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
}

/// "↗ 9.0 GB" for growth, "↘ 4.0 GB" for a shrink.
func arrowBytes(_ bytes: Int64) -> String {
    "\(bytes < 0 ? "\u{2198}" : "\u{2197}") \(formattedBytes(abs(bytes)))"
}

/// The amount as VoiceOver reads it: "up 9.0 GB" or "down 4.0 GB".
func spokenChangeAmount(_ bytes: Int64) -> String {
    "\(bytes < 0 ? "down" : "up") \(formattedBytes(abs(bytes)))"
}
