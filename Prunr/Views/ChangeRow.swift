import SwiftUI

/// One change on a single line: icon, name, and the signed amount on the right
/// (orange when space was used, grey when it was given back).
struct ChangeRow: View {
    let episode: ChangeEpisode

    var body: some View {
        HStack(spacing: 10) {
            UnitIconTile(category: episode.category, source: episode.iconSource)

            Text(episode.title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(amountText)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(episode.isGrowth ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(episode.title), \(amountText)")
    }

    private var amountText: String { signedBytes(episode.netBytes) }
}
