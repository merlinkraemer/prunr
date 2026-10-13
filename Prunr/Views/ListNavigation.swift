import AppKit
import SwiftUI

enum FeedPage: Equatable {
    case feed
    case group(ChangeGroup)
    case place(ChangeGroup, ChangeEpisode)

    var depth: Int {
        switch self {
        case .feed: return 0
        case .group: return 1
        case .place: return 2
        }
    }

    var group: ChangeGroup? {
        switch self {
        case .feed: return nil
        case .group(let group), .place(let group, _): return group
        }
    }

    var place: ChangeEpisode? {
        if case .place(_, let place) = self { return place }
        return nil
    }

    var parent: FeedPage {
        switch self {
        case .feed, .group: return .feed
        case .place(let group, _): return .group(group)
        }
    }

    func opening(_ group: ChangeGroup) -> FeedPage {
        .group(group)
    }

    func opening(_ place: ChangeEpisode) -> FeedPage {
        guard case .group(let group) = self, FeedPage.opensContents(place) else { return self }
        return .place(group, place)
    }

    static func opensContents(_ place: ChangeEpisode) -> Bool {
        place.rootPath != nil
    }
}

enum RowPathAction: CaseIterable, Equatable {
    case showInFinder
    case copyPath

    var title: String {
        switch self {
        case .showInFinder: return "Show in Finder"
        case .copyPath: return "Copy Path"
        }
    }

    static func actions(forPath path: String?) -> [RowPathAction] {
        path == nil ? [] : allCases
    }

    static func copyToPasteboard(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}

extension View {
    @ViewBuilder
    func pathContextMenu(_ path: String?, onShowInFinder: @escaping (String) -> Void) -> some View {
        if let path {
            contextMenu {
                ForEach(RowPathAction.actions(forPath: path), id: \.self) { action in
                    Button(action.title) {
                        switch action {
                        case .showInFinder: onShowInFinder(path)
                        case .copyPath: RowPathAction.copyToPasteboard(path)
                        }
                    }
                }
            }
        } else {
            self
        }
    }
}

enum InlineStatus: Equatable {
    case indexing
    case empty
    case failed

    var text: String {
        switch self {
        case .indexing: return "Indexing files…"
        case .empty: return "No files found"
        case .failed: return "Couldn't read"
        }
    }
}

struct InlineStatusRow: View {
    let status: InlineStatus
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(status.text)
                .foregroundStyle(.secondary)
            if status == .failed, let onRetry {
                Text("\u{00B7}")
                    .foregroundStyle(.tertiary)
                Button("Retry", action: onRetry)
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 46)
        .padding(.trailing, 18)
        .frame(height: 34)
    }
}

struct ShowMoreRow: View {
    let title: String
    var isEnabled = true
    let onShowMore: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onShowMore) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 40)
                .padding(.trailing, 12)
                .frame(height: 30)
                .background(ListRowHoverBackground(isHovering: isHovering && isEnabled))
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.6)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

struct ListChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}
