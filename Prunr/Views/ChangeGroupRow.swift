import SwiftUI

/// One category's changes on one day in the main list, with the amount and
/// its direction arrow. Same metrics as the categories view rows.
/// - One place: the place itself; the chevron turns into Show in Finder on
///   hover and clicking reveals the place.
/// - Several places: the category; clicking opens the day's places.
/// - Nothing with a path on disk: plain, without chevron.
struct ChangeGroupRow: View {
    enum TrailingGlyph: Equatable {
        case chevron
        case revealInFinder
        case none
    }

    let group: ChangeGroup
    let onOpen: () -> Void
    let onReveal: (String) -> Void

    @State private var isHovering = false

    nonisolated static func trailingGlyph(for kind: ChangeGroupRowKind, isHovering: Bool) -> TrailingGlyph {
        switch kind {
        case .single:
            return isHovering ? .revealInFinder : .chevron
        case .multi:
            return .chevron
        case .inert:
            return .none
        }
    }

    nonisolated static func perform(_ kind: ChangeGroupRowKind, onOpen: () -> Void, onReveal: (String) -> Void) {
        switch kind {
        case .single(let rootPath):
            onReveal(rootPath)
        case .multi:
            onOpen()
        case .inert:
            break
        }
    }

    var body: some View {
        let kind = group.rowKind
        if kind == .inert {
            content(kind: kind, isHovering: false)
        } else {
            Button { Self.perform(kind, onOpen: onOpen, onReveal: onReveal) } label: {
                content(kind: kind, isHovering: isHovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
            .help(kind == .multi ? Text("") : Text("Show in Finder"))
            .accessibilityHint(accessibilityHint(for: kind))
            .accessibilityAddTraits(.isButton)
        }
    }

    private func content(kind: ChangeGroupRowKind, isHovering: Bool) -> some View {
        HStack(spacing: 10) {
            leadingIcon

            Text(title)
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

            trailing(Self.trailingGlyph(for: kind, isHovering: isHovering))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 34)
        .background(ListRowHoverBackground(isHovering: isHovering))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(spokenChangeAmount(group.netBytes))")
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let place = group.soloPlace {
            UnitIconTile(category: place.category, source: place.iconSource, size: 18)
        } else {
            Image(systemName: group.category.icon)
                .font(.system(size: 15))
                .foregroundStyle(group.category.color)
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private func trailing(_ glyph: TrailingGlyph) -> some View {
        switch glyph {
        case .chevron, .revealInFinder:
            ZStack {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(glyph == .chevron ? 1 : 0)
                RevealInFinderGlyph()
                    .opacity(glyph == .revealInFinder ? 1 : 0)
            }
            .frame(width: 12, height: 12)
        case .none:
            Color.clear
                .frame(width: 12, height: 12)
        }
    }

    private var title: String {
        group.soloPlace.map(EpisodeBuilder.rowTitle(for:)) ?? group.category.displayName
    }

    private func accessibilityHint(for kind: ChangeGroupRowKind) -> String {
        kind == .multi ? "Shows this day's changes in \(group.category.displayName)" : "Shows this place in Finder"
    }
}

/// "Show all (N)" under a day's first groups; expands that day in place.
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

/// The list row hover: a soft rounded fill, like the categories view rows.
struct ListRowHoverBackground: View {
    let isHovering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isHovering ? Color.gray.opacity(0.1) : Color.clear)
    }
}
