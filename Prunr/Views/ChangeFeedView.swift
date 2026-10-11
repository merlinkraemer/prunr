import SwiftUI

/// The main list: this week's notable changes under plain day labels, newest
/// first, each week ending with its "smaller changes" row, then older weeks.
struct ChangeFeedView: View {
    static let calmText = "Nothing notable changed this week"

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
                // Never an empty list on an error: say so and offer a retry.
                ChangeFeedStateView(message: ChangeFeedStateView.failedText, onRetry: onRetry)
            case .loaded(let feed)? where feed.isDayOne(now: now):
                ChangeFeedStateView(message: ChangeFeedStateView.dayOneText)
            case .loaded(let feed)?:
                list(feed, now: now)
            }
        }
    }

    private func list(_ feed: ChangeFeed, now: Date) -> some View {
        ScrollView {
            ChangeFeedRows(feed: feed, now: now, onReveal: onReveal)
        }
        .hiddenScrollIndicators()
    }
}

/// The list's rows without the scroll view: calm line, day labels, rows, each
/// week's "smaller changes" row and the "Watching since" marker. The
/// marketing renderer lays these out directly, since `ImageRenderer` leaves
/// AppKit-backed scroll views blank.
struct ChangeFeedRows: View {
    let feed: ChangeFeed
    let now: Date
    let onReveal: (String) -> Void

    private let calendar = Calendar.current

    var body: some View {
        // This week always shows (calm line at least); older weeks only when
        // something moved in them.
        let weeks = feed.weeks.filter { $0.index == 0 || !$0.isEmpty }
        LazyVStack(alignment: .leading, spacing: 0) {
            if feed.thisWeek?.days.isEmpty ?? true {
                Text(ChangeFeedView.calmText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }

            ForEach(weeks) { week in
                ForEach(week.days) { day in
                    Text(EpisodeBuilder.dayLabel(for: day.day, now: now, calendar: calendar))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, isFirstLabel(day, in: week) ? 4 : 12)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(day.episodes) { episode in
                        ChangeRow(
                            episode: episode,
                            caption: EpisodeBuilder.caption(for: episode, calendar: calendar),
                            onReveal: onReveal
                        )
                    }
                }

                if !week.smaller.isEmpty {
                    ChangeTailRow(
                        count: week.smaller.count,
                        netBytes: week.smallerNetBytes,
                        caption: EpisodeBuilder.weekSpanLabel(for: week, calendar: calendar)
                    )
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
        .padding(.vertical, 6)
    }

    /// The very first day label sits tight under the header.
    private func isFirstLabel(_ day: ChangeFeedDay, in week: ChangeFeedWeek) -> Bool {
        week.index == 0 && week.days.first?.day == day.day
    }
}
