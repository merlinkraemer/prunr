import SwiftUI

struct ChangeGroupRow: View {
    let group: ChangeGroup
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: group.category.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(group.category.color)
                    .frame(width: 18, height: 18)

                Text(group.category.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(signedBytes(group.netBytes))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(changeAmountStyle(group.netBytes))
                    .lineLimit(1)
                    .fixedSize()

                ListChevron()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 34)
            .background(ListRowHoverBackground(isHovering: isHovering))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.category.displayName), \(spokenChangeAmount(group.netBytes))")
        .accessibilityHint("Shows this day's changes in \(group.category.displayName)")
        .accessibilityAddTraits(.isButton)
    }
}

struct ShowAllGroupsRow: View {
    let count: Int
    let onExpand: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onExpand) {
            Text("Show all (\(count))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 40)
                .padding(.trailing, 12)
                .frame(height: 24)
                .background(ListRowHoverBackground(isHovering: isHovering))
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel("Show all \(count) categories")
    }
}

struct ListRowHoverBackground: View {
    let isHovering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isHovering ? Color.gray.opacity(0.1) : Color.clear)
    }
}
