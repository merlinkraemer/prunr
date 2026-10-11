import SwiftUI

/// The main list: one plain chronological list, newest first, grouped into
/// day sections with real dates. Date labels stick at the top while
/// scrolling, and the rows themselves fade to transparent above the footer.
struct ChangeFeedView: View {
    /// Height of the fade above the footer; the list ends with as much space,
    /// so the last row can scroll clear of it.
    static let fadeHeight: CGFloat = 32

    /// Nil while the first read is in flight.
    let result: ChangeFeedResult?
    let onReveal: (String) -> Void
    let onRetry: () -> Void

    var body: some View {
        let now = Date()
        Group {
            switch result {
            case nil:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed?:
                ChangeFeedStateView(message: ChangeFeedStateView.failedText, onRetry: onRetry)
            case .loaded(let feed)? where feed.isDayOne(now: now):
                ChangeFeedStateView(message: ChangeFeedStateView.dayOneText)
            case .loaded(let feed)?:
                list(feed, now: now)
            }
        }
    }

    private static let fadeStops: [Gradient.Stop] = [
        .init(color: .black, location: 0),
        .init(color: .black.opacity(0.75), location: 0.3),
        .init(color: .black.opacity(0.35), location: 0.65),
        .init(color: .clear, location: 1),
    ]

    private func list(_ feed: ChangeFeed, now: Date) -> some View {
        ScrollView {
            ChangeFeedRows(feed: feed, now: now, onReveal: onReveal)
                .padding(.bottom, Self.fadeHeight)
        }
        .hiddenScrollIndicators()
        .mask(
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(stops: Self.fadeStops, startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fadeHeight)
            }
        )
    }
}

/// The list's rows without the scroll view: the "Nothing over 1 GB since"
/// line, day sections with sticky date labels, and the "Watching since"
/// marker. The marketing renderer lays these out directly, since
/// `ImageRenderer` leaves AppKit-backed scroll views blank.
struct ChangeFeedRows: View {
    let feed: ChangeFeed
    let now: Date
    let onReveal: (String) -> Void

    private let calendar = Calendar.current

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            if let since = feed.quietSince(now: now, calendar: calendar) {
                Text(EpisodeBuilder.quietLabel(since: since, calendar: calendar))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }

            ForEach(feed.days) { day in
                Section {
                    ForEach(day.episodes) { episode in
                        ChangeRow(
                            episode: episode,
                            onReveal: onReveal
                        )
                    }
                } header: {
                    Text(EpisodeBuilder.dayLabel(for: day.day, calendar: calendar))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
            }

            if feed.isShortHistory(now: now, calendar: calendar), let since = feed.watchingSince {
                Text(EpisodeBuilder.watchingSinceLabel(since, calendar: calendar))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}
