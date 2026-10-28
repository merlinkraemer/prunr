import SwiftUI

struct ChangeGroupRow: View {
    let group: ChangeGroup
    let onOpen: () -> Void
    var soleItemPath: (@MainActor () async -> String?)? = nil
    var onReveal: (String) -> Void = { _ in }

    @State private var isHovering = false
    @State private var resolvedSoleItemPath: String?

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                if let iconSource = group.rowIconSource {
                    UnitIconTile(category: group.category, source: iconSource, size: 18)
                        .estimatedLook(group.isEstimated)
                } else {
                    Image(systemName: group.category.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(group.category.color)
                        .frame(width: 18, height: 18)
                        .estimatedLook(group.isEstimated)
                }

                FittingTitle(title: group.rowTitle, shortTitle: group.rowShortTitle, font: .system(size: 13, weight: .semibold), isDimmed: group.isEstimated)

                Text(signedBytes(group.netBytes))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(changeAmountStyle(group.netBytes, isEstimated: group.isEstimated))
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
        .accessibilityLabel("\(group.rowTitle), \(spokenChangeAmount(group.netBytes))")
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .pathContextMenu(resolvedSoleItemPath, onShowInFinder: onReveal)
        .task(id: group) {
            resolvedSoleItemPath = await soleItemPath?()
        }
    }

    private var accessibilityHint: String {
        if resolvedSoleItemPath != nil { return "Shows it in Finder" }
        return FeedPage.soloPlace(of: group) == nil ? "Shows this day's changes of \(group.owner.displayName)" : "Shows what is in this place"
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
