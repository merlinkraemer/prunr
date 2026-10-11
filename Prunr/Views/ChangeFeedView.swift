import SwiftUI

/// The main list: changes grouped under plain day labels, newest first.
struct ChangeFeedView: View {
    /// Nil while the first read is in flight.
    let result: ChangeFeedResult?
    let onReveal: (String) -> Void
    let onRetry: () -> Void

    private let calendar = Calendar.current

    /// Days with at least one row worth drawing. Sub-floor rows stay in the
    /// data; the floor only decides whether a line earns the pixels.
    private var visibleDays: [ChangeFeedDay] {
        guard let feed = result?.feed else { return [] }
        return feed.days.compactMap { day in
            let episodes = day.episodes.filter {
                abs($0.netBytes) >= GrowthJournalService.presentationFloorBytes
            }
            return episodes.isEmpty ? nil : ChangeFeedDay(day: day.day, episodes: episodes)
        }
    }

    var body: some View {
        let days = visibleDays
        Group {
            switch result {
            case nil:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed?:
                // Never an empty list on an error: say so and offer a retry.
                VStack(spacing: 8) {
                    Text("Couldn't read change history")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Retry", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded? where days.isEmpty:
                Text("Nothing notable changed this week")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded?:
                list(days)
            }
        }
    }

    private func list(_ days: [ChangeFeedDay]) -> some View {
        let now = Date()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    Text(EpisodeBuilder.dayLabel(for: day.day, now: now, calendar: calendar))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, index == 0 ? 4 : 12)
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
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .hiddenScrollIndicators()
    }
}
