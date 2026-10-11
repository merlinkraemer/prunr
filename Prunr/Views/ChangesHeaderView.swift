import SwiftUI

/// The header above every list: the coloured storage bar, a hairline, then one
/// row in a fixed place: "This week" on the change list, or a title row with a
/// back button. While `onOpenBar` is set, the bar area is one button with a row
/// hover that opens the categories view; otherwise the bar's own segments work.
struct ChangesHeaderView<Bar: View, Row: View>: View {
    let onOpenBar: (() -> Void)?
    @ViewBuilder let bar: () -> Bar
    @ViewBuilder let row: () -> Row

    @State private var isHoveringBar = false

    var body: some View {
        VStack(spacing: 0) {
            barArea

            Divider()

            row()
                .frame(maxWidth: .infinity)
                .frame(height: HeaderRowMetrics.height)
        }
    }

    @ViewBuilder
    private var barArea: some View {
        if let onOpenBar {
            Button(action: onOpenBar) {
                paddedBar
                    .allowsHitTesting(false)
                    .background(
                        ListRowHoverBackground(isHovering: isHoveringBar)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHoveringBar = hovering
                }
            }
            .help("Show categories")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Storage by category")
            .accessibilityHint("Shows storage by category")
            .accessibilityAddTraits(.isButton)
        } else {
            paddedBar
        }
    }

    private var paddedBar: some View {
        bar()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
    }
}

/// "This week" with the signed weekly amount on the right. Not clickable.
struct WeeklyChangeRow: View {
    let weekly: WeeklyChange

    var body: some View {
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
        .padding(.horizontal, 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
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

/// A title row in the header's row slot: back chevron at the left edge, the
/// title (with an optional category glyph) centred, no amount.
struct HeaderTitleRow: View {
    let title: String
    var category: GrowthCategory? = nil
    let backHint: String
    let onBack: () -> Void

    private static var backWidth: CGFloat { 52 }

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                if let category {
                    Image(systemName: category.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(category.color)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Self.backWidth)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            HStack(spacing: 0) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.leading, 18)
                        .frame(width: Self.backWidth, height: HeaderRowMetrics.height, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .accessibilityHint(backHint)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The header row's fixed height, shared by "This week" and every title row.
enum HeaderRowMetrics {
    static let height: CGFloat = 34
}
