import SwiftUI

/// The header above the change list: the coloured storage bar, then
/// "19 GB free of 2 TB" on the left and "this week +48 GB" on the right. The
/// weekly amount ends on the same right edge as the row amounts below it.
/// While the change list shows, the whole header is one button that opens the
/// categories view.
struct ChangesHeaderView<Bar: View>: View {
    let freeBytes: Int64
    let totalBytes: Int64
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
        VStack(alignment: .leading, spacing: 6) {
            bar()
                // One target: inside the button the bar is only a picture.
                .allowsHitTesting(onOpen == nil)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                freeLine
                Spacer(minLength: 0)
                weeklyLine
            }
            .font(.system(size: 13))
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var freeLine: some View {
        if totalBytes > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formattedBytes(freeBytes))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text("free")
                    .foregroundStyle(.primary)
                Text("of \(formattedBytes(totalBytes))")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("\u{2014}")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var weeklyLine: some View {
        if let amount = weekly.amountText {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("this week")
                    .foregroundStyle(.secondary)
                Text(amount)
                    .font(.system(size: 13, weight: isGrowth ? .semibold : .medium, design: .monospaced))
                    .foregroundStyle(isGrowth ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .fixedSize()
            }
        } else {
            Text("no change this week")
                .foregroundStyle(.secondary)
        }
    }

    private var isGrowth: Bool {
        if case .bytes(let net) = weekly { return net > 0 }
        return false
    }

    private var accessibilityText: String {
        let free = totalBytes > 0
            ? "\(formattedBytes(freeBytes)) free of \(formattedBytes(totalBytes))"
            : "Free space unknown"
        let week: String
        switch weekly {
        case .unknown:
            week = "change this week unknown"
        case .none:
            week = "no change this week"
        case .bytes(let net):
            week = "this week \(net > 0 ? "up" : "down") \(formattedBytes(abs(net)))"
        }
        return "\(free), \(week)"
    }
}
