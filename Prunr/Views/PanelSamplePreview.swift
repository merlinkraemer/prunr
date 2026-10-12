import SwiftUI

struct PanelSamplePreview: View {
    @State private var expandedDays: Set<Date> = []

    private var segments: [DriveBarSegment] {
        let categories = MarketingSample.categories(endedAt: MarketingSample.now)
            .filter { $0.currentSizeBytes > 0 }
            .sorted { $0.currentSizeBytes > $1.currentSizeBytes }
        var segments = categories.map {
            DriveBarSegment(id: $0.category.rawValue, bytes: $0.currentSizeBytes, color: $0.category.color)
        }
        let insideBytes = categories.reduce(Int64(0)) { $0 + $1.currentSizeBytes }
        let outsideBytes = MarketingSample.usedBytes - insideBytes
        if outsideBytes > 0 {
            segments.append(DriveBarSegment(id: "outside-scan-scope", bytes: outsideBytes, color: Color.gray.opacity(0.55)))
        }
        return segments
    }

    var body: some View {
        VStack(spacing: 0) {
            ChangesHeaderView(onOpenBar: nil) {
                DriveBarView(
                    totalBytes: MarketingSample.totalBytes,
                    usedBytes: MarketingSample.usedBytes,
                    freeBytes: MarketingSample.freeBytes,
                    categorySegments: segments,
                    highlightedSegmentID: .constant(nil),
                    disableHover: true
                )
            } row: {
                WeeklyChangeRow(weekly: WeeklyChange(.loaded(MarketingSample.feed), now: MarketingSample.now))
            }

            Divider()

            ScrollView {
                ChangeFeedRows(
                    feed: MarketingSample.feed,
                    now: MarketingSample.now,
                    expandedDays: $expandedDays,
                    onOpenGroup: { _ in },
                    onReveal: { _ in }
                )
                .padding(.bottom, SoftBottomEdge.height)
            }
            .hiddenScrollIndicators()
            .softBottomEdge()
            .padding(.bottom, -SoftBottomEdge.footerHeight)

            Text("Sample data")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: SoftBottomEdge.footerHeight)
        }
    }
}
