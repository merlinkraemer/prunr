import SwiftUI

/// One change in a day group: icon, name over a muted caption ("14:20 ·
/// detail", "found by scan", "a little each day since Fri 2 Oct"), and the
/// amount with its direction arrow on the right. Not clickable.
struct ChangeRow: View {
    let episode: ChangeEpisode
    var calendar: Calendar = .current

    var body: some View {
        HStack(spacing: 10) {
            UnitIconTile(category: episode.category, source: episode.iconSource, size: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(caption)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(amountText)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(changeAmountStyle(episode.netBytes))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(episode.title), \(caption), \(spokenChangeAmount(episode.netBytes))")
    }

    private var caption: String { EpisodeBuilder.caption(for: episode, calendar: calendar) }

    private var amountText: String { arrowBytes(episode.netBytes) }
}

/// Orange for growth of at least the row line, grey for shrinks, primary for
/// smaller growth.
func changeAmountStyle(_ netBytes: Int64) -> AnyShapeStyle {
    if netBytes >= EpisodeBuilder.rowThresholdBytes {
        return AnyShapeStyle(Color.orange)
    }
    return netBytes < 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
}

/// "↑ 9.0 GB" for growth, "↓ 4.0 GB" for a shrink.
func arrowBytes(_ bytes: Int64) -> String {
    "\(bytes < 0 ? "\u{2193}" : "\u{2191}") \(formattedBytes(abs(bytes)))"
}

/// The amount as VoiceOver reads it: "up 9.0 GB" or "down 4.0 GB".
func spokenChangeAmount(_ bytes: Int64) -> String {
    "\(bytes < 0 ? "down" : "up") \(formattedBytes(abs(bytes)))"
}
