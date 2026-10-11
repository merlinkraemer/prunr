import SwiftUI

/// The header above the change list: the coloured storage bar, a divider, then
/// one "This week" row with the signed weekly amount on the same right edge as
/// the row amounts below it. While the change list shows, the whole header is
/// one button that opens the categories view.
struct ChangesHeaderView<Bar: View>: View {
    let weekly: WeeklyChange
    /// Opens the categories view; nil while it is already open, which leaves
    /// the bar's own segment clicks working.
    let onOpen: (() -> Void)?
    @ViewBuilder let bar: () -> Bar

    var body: some View {
        if let onOpen {
            Button(action: onOpen) {
                content
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show categories")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Shows storage by category")
            .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar()
                .allowsHitTesting(onOpen == nil)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("This week")
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(weekly.amountText ?? "No change")
                    .monospacedDigit()
                    .foregroundStyle(amountStyle)
                    .fixedSize()
            }
            .font(.system(size: 13))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var amountStyle: AnyShapeStyle {
        switch weekly {
        case .bytes(let net) where net >= EpisodeBuilder.rowThresholdBytes:
            return AnyShapeStyle(Color.orange)
        case .bytes:
            return AnyShapeStyle(.primary)
        case .unknown, .none:
            return AnyShapeStyle(.secondary)
        }
    }

    private var accessibilityText: String {
        switch weekly {
        case .unknown:
            return "Change this week unknown"
        case .none:
            return "No change this week"
        case .bytes(let net):
            return "This week \(net > 0 ? "up" : "down") \(formattedBytes(abs(net)))"
        }
    }
}
