import SwiftUI

/// The last row of a week: "in 9 smaller changes +4.3 GB", carrying every
/// change without a row of its own. Same metrics as `ChangeRow`, with a quiet
/// tile instead of a category icon. Not clickable: it is not one place.
struct ChangeTailRow: View {
    let count: Int
    let netBytes: Int64
    /// The week's days, "5 – 11 Oct".
    let caption: String

    private var hasAmount: Bool {
        abs(netBytes) >= GrowthJournalService.presentationFloorBytes
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(EpisodeBuilder.smallerChangesTitle(count: count))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(caption)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hasAmount {
                Text(signedBytes(netBytes))
                    .font(.system(size: 13, weight: netBytes > 0 ? .semibold : .medium, design: .monospaced))
                    .foregroundStyle(netBytes > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let title = EpisodeBuilder.smallerChangesTitle(count: count)
        guard hasAmount else { return "\(title), \(caption)" }
        return "\(title), \(caption), \(signedBytes(netBytes))"
    }
}
