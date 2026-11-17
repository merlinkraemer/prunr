import Foundation

/// Which children of a place moved in one journal bucket: the per-child side
/// of `growthJournalBucket` (PRD L1). Every writer of the journal records it
/// next to its bucket, so a row's page can list what grew in the row's span.
/// Kept small: per bucket and place, the `topChildren` largest moves plus one
/// remainder row under `otherName`.
enum GrowthJournalDetail {
    static let topChildren = 20

    /// The remainder row's name. A path component never contains "/", and the
    /// empty name is the root of a file place.
    static let otherName = "/"

    static func isOther(_ child: PlaceChildKey) -> Bool {
        child.name == otherName
    }

    static func other(unitRoot: String) -> PlaceChildKey {
        PlaceChildKey(unitRoot: unitRoot, name: otherName, isFolder: false)
    }

    /// Per place: the `topChildren` children with the largest absolute delta,
    /// the rest summed into the place's remainder row. Zero deltas are dropped.
    static func bounded(_ deltas: [PlaceChildKey: Int64]) -> [PlaceChildKey: Int64] {
        var result: [PlaceChildKey: Int64] = [:]
        for (unitRoot, entries) in Dictionary(grouping: deltas.filter { $0.value != 0 }, by: { $0.key.unitRoot }) {
            var remainder: Int64 = 0
            let named = entries.filter { entry in
                guard isOther(entry.key) else { return true }
                remainder += entry.value
                return false
            }
            let ranked = named.sorted {
                abs($0.value) != abs($1.value) ? abs($0.value) > abs($1.value) : $0.key.name < $1.key.name
            }
            for (index, entry) in ranked.enumerated() {
                if index < topChildren {
                    result[entry.key] = entry.value
                } else {
                    remainder += entry.value
                }
            }
            if remainder != 0 {
                result[other(unitRoot: unitRoot)] = remainder
            }
        }
        return result
    }

    /// Per child: what the authoritative scan delta adds on top of what the
    /// journal already holds for the window, the way the scan reconciles the
    /// per-place buckets.
    static func residual(
        authoritative: [PlaceChildKey: Int64],
        recorded: [PlaceChildKey: Int64]
    ) -> [PlaceChildKey: Int64] {
        var result: [PlaceChildKey: Int64] = [:]
        for key in Set(authoritative.keys).union(recorded.keys) {
            let residual = (authoritative[key] ?? 0) - (recorded[key] ?? 0)
            if residual != 0 {
                result[key] = residual
            }
        }
        return result
    }
}

/// One child of a place on a row's page: how much it changed in the row's span
/// and how big it is now.
struct PlaceChildChange: Identifiable, Sendable, Equatable {
    var id: String { path ?? GrowthJournalDetail.otherName }
    let name: String
    /// Nil for the remainder row ("Other changes").
    let path: String?
    let isFolder: Bool
    let deltaBytes: Int64
    /// Nil when the child is no longer there.
    let currentBytes: Int64?
}

/// What a row's page knows about the row's span.
struct PlaceChanges: Sendable, Equatable {
    /// Largest change first, the remainder last. Nil when the journal holds no
    /// per-child detail for the span (rows from before it was recorded).
    let children: [PlaceChildChange]?
    /// The place's size now.
    let currentBytes: Int64
}

/// The time a row covers: from the day its count started to the end of the
/// row's day.
struct PlaceChangeSpan: Equatable, Sendable {
    let start: Date
    let end: Date
    /// Set when the row built up over several days.
    let firstDay: Date?
    let day: Date
    let netBytes: Int64

    init(episode: ChangeEpisode, calendar: Calendar) {
        let day = calendar.startOfDay(for: episode.day)
        let firstDay = episode.buildingSince.map { calendar.startOfDay(for: $0) }
        self.day = day
        self.firstDay = firstDay.flatMap { $0 < day ? $0 : nil }
        start = self.firstDay ?? day
        end = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(24 * 60 * 60)
        netBytes = episode.netBytes
    }

    /// "on Thu 29 Oct" or "from Sun 18 Oct to Mon 26 Oct".
    func daysText(calendar: Calendar) -> String {
        let dayLabel = EpisodeBuilder.dayLabel(for: day, calendar: calendar)
        guard let firstDay else { return "on \(dayLabel)" }
        return "from \(EpisodeBuilder.dayLabel(for: firstDay, calendar: calendar)) to \(dayLabel)"
    }
}

/// The short lines above a place's list that say what the list shows.
enum PlacePageNotes {
    static let otherChangesTitle = "Other changes"
    static let goneText = "Gone"

    static func lines(span: PlaceChangeSpan, changes: PlaceChanges, calendar: Calendar) -> [String] {
        if changes.children != nil {
            return []
        }
        let days = span.daysText(calendar: calendar)
        let amount = formattedBytes(abs(span.netBytes))
        let moved = span.netBytes < 0 ? "shrank \(amount)" : "grew \(amount)"
        guard changes.currentBytes > 0 else {
            if span.netBytes < 0 {
                return ["\(goneText), was about \(formattedBytes(-span.netBytes))"]
            }
            return ["\(goneText) now \u{00B7} \(moved) \(days)"]
        }
        return ["Now \(formattedBytes(changes.currentBytes)) \u{00B7} \(moved) \(days)", "Size now"]
    }
}
