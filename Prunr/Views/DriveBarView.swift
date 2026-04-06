import SwiftUI

struct DriveBarSegment: Identifiable {
    let id: String
    let bytes: Int64
    let color: Color
}

/// Visual drive bar showing used and free disk space - minimal single row
struct DriveBarView: View {
    /// Total disk space in bytes
    let totalBytes: Int64

    /// Used disk space in bytes
    let usedBytes: Int64

    /// Free disk space in bytes
    let freeBytes: Int64

    /// Optional category breakdown rendered inside the used portion
    var categorySegments: [DriveBarSegment] = []

    /// Shared hover state so the drive bar and list rows can highlight each other
    @Binding var highlightedSegmentID: String?

    /// Optional tap handler for interactive segments.
    var onTapSegment: ((String) -> Void)? = nil

    /// When set, forces a segment to appear highlighted (like hover) and shows this label next to the bar
    var focusedSegmentID: String? = nil
    var focusedLabel: String? = nil
    var focusedIcon: String? = nil
    var focusedIconColor: Color = .secondary
    
    /// When true, disables hover interactions on the bar segments
    var disableHover: Bool = false

    /// Bar height
    private let barHeight: CGFloat = 12
    private let segmentSpacing: CGFloat = 1
    private let minimumSegmentFraction: CGFloat = 0.03
    private let minimumUsedPresentationFraction: CGFloat = 0.42
    private let maximumFreePresentationFraction: CGFloat = 0.58
    private let maximumFillerPresentationFraction: CGFloat = 0.38

    var body: some View {
        HStack(spacing: 8) {
            barContent

            if let focusedLabel {
                focusedDetailView(focusedLabel)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.vertical, 4)
        .frame(height: 20)
        .animation(.snappy(duration: 0.24, extraBounce: 0), value: focusedLabel)
    }

    private func focusedDetailView(_ label: String) -> some View {
        let parts = label.split(separator: " ", maxSplits: 1)
        let number = String(parts.first ?? "")
        let unit = parts.count > 1 ? String(parts[1]) : ""

        return HStack(spacing: 4) {
            if let focusedIcon {
                Image(systemName: focusedIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(focusedIconColor)
            }

            Text(number)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)

            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }

    private var barContent: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(Color.gray.opacity(0.15))

                if visibleSegments.isEmpty {
                    RoundedRectangle(cornerRadius: barHeight / 2)
                        .fill(
                            LinearGradient(
                                colors: [usageColor.opacity(0.8), usageColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * presentedUsedFraction)
                } else {
                    let usedWidth = geometry.size.width * presentedUsedFraction
                    let availableSegmentWidth = max(0, usedWidth - (segmentSpacing * CGFloat(max(0, renderedSegments.count - 1))))
                    HStack(spacing: segmentSpacing) {
                        ForEach(renderedSegments) { segment in
                            Button {
                                guard isInteractiveSegment(segment.id) else { return }
                                onTapSegment?(segment.id)
                            } label: {
                                Rectangle()
                                    .fill(fillColor(for: segment))
                                    .frame(width: max(0, availableSegmentWidth * segment.fraction))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!isInteractiveSegment(segment.id))
                            .onHover { hovering in
                                guard !disableHover else { return }
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    highlightedSegmentID = hovering ? segment.id : nil
                                }
                            }
                            .accessibilityLabel(accessibilityLabel(for: segment.id))
                            .accessibilityAddTraits(isInteractiveSegment(segment.id) ? .isButton : [])
                            .contentShape(Rectangle())
                            .modifier(DriveBarSegmentHelpModifier(isInteractive: isInteractiveSegment(segment.id)))
                        }
                    }
                    .frame(width: usedWidth, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: barHeight / 2))
                }
            }
        }
        .frame(height: barHeight)
    }

    // MARK: - Private Helpers

    /// Color based on disk usage
    private var usageColor: Color {
        let percentage = usedPercentage
        if percentage < 70 {
            return .green
        } else if percentage < 90 {
            return .orange
        } else {
            return .red
        }
    }

    /// Used percentage (0-100)
    private var usedPercentage: Int {
        guard totalBytes > 0 else { return 0 }
        return Int((Double(usedBytes) / Double(totalBytes)) * 100)
    }

    private var usedFraction: CGFloat {
        guard totalBytes > 0 else { return 0 }
        return CGFloat(Double(usedBytes) / Double(totalBytes))
    }

    private var presentedUsedFraction: CGFloat {
        guard totalBytes > 0 else { return 0 }
        guard usedBytes > 0 else { return 0 }
        guard !categorySegments.isEmpty else { return usedFraction }
        return min(1, max(usedFraction, minimumUsedPresentationFraction, 1 - maximumFreePresentationFraction))
    }

    private var visibleSegments: [DriveBarSegment] {
        guard totalBytes > 0, usedBytes > 0 else {
            return []
        }

        let positiveSegments = categorySegments
            .filter { $0.bytes > 0 }

        guard !positiveSegments.isEmpty else {
            return []
        }

        var remainingUsed = usedBytes
        var rendered: [DriveBarSegment] = []

        for segment in positiveSegments {
            guard remainingUsed > 0 else { break }
            let clampedBytes = min(segment.bytes, remainingUsed)
            guard clampedBytes > 0 else { continue }

            rendered.append(
                DriveBarSegment(
                    id: segment.id,
                    bytes: clampedBytes,
                    color: segment.color
                )
            )
            remainingUsed -= clampedBytes
        }

        if remainingUsed > 0 {
            rendered.append(
                DriveBarSegment(
                    id: "other-used",
                    bytes: remainingUsed,
                    color: usageColor.opacity(0.45)
                )
            )
        }

        return rendered
    }

    private var renderedSegments: [RenderedSegment] {
        guard !visibleSegments.isEmpty, usedBytes > 0 else {
            return []
        }

        if visibleSegments.count == 1 {
            let segment = visibleSegments[0]
            return [RenderedSegment(id: segment.id, color: segment.color, fraction: 1)]
        }

        let fillerSegments = visibleSegments.filter(isFillerSegment)
        let trackedSegments = visibleSegments.filter { !isFillerSegment($0) }

        let baseFractions: [CGFloat]
        if !trackedSegments.isEmpty, !fillerSegments.isEmpty {
            let fillerBytes = fillerSegments.reduce(Int64(0)) { $0 + $1.bytes }
            let trackedBytes = trackedSegments.reduce(Int64(0)) { $0 + $1.bytes }
            let actualFillerFraction = max(CGFloat(Double(fillerBytes) / Double(usedBytes)), 0)
            let displayedFillerFraction = min(actualFillerFraction, maximumFillerPresentationFraction)
            let displayedTrackedFraction = max(0, 1 - displayedFillerFraction)

            baseFractions = visibleSegments.map { segment in
                if isFillerSegment(segment) {
                    guard fillerBytes > 0 else { return 0 }
                    return displayedFillerFraction * CGFloat(Double(segment.bytes) / Double(fillerBytes))
                }

                guard trackedBytes > 0 else { return 0 }
                return displayedTrackedFraction * CGFloat(Double(segment.bytes) / Double(trackedBytes))
            }
        } else {
            baseFractions = visibleSegments.map { max(CGFloat(Double($0.bytes) / Double(usedBytes)), 0) }
        }

        let adjustedFractions = zip(visibleSegments, baseFractions).map { segment, fraction in
            if isFillerSegment(segment) {
                return fraction
            }
            return max(fraction, minimumSegmentFraction)
        }
        let totalAdjusted = adjustedFractions.reduce(0, +)
        guard totalAdjusted > 0 else {
            return []
        }

        return zip(visibleSegments, adjustedFractions).map { segment, fraction in
            RenderedSegment(
                id: segment.id,
                color: segment.color,
                fraction: fraction / totalAdjusted
            )
        }
    }

    private var activeHighlightID: String? {
        if disableHover {
            return focusedSegmentID
        }

        return highlightedSegmentID ?? focusedSegmentID
    }

    private func fillColor(for segment: RenderedSegment) -> Color {
        guard let activeHighlightID else {
            return segment.color.opacity(0.9)
        }

        if activeHighlightID == segment.id {
            return segment.color
        }

        return segment.color.opacity(0.3)
    }

    private func isFillerSegment(_ segment: DriveBarSegment) -> Bool {
        segment.id == "outside-scan-scope" || segment.id == "other-used"
    }

    private func isInteractiveSegment(_ id: String) -> Bool {
        id != "outside-scan-scope" && id != "other-used"
    }

    private func accessibilityLabel(for id: String) -> String {
        if let category = GrowthCategory(rawValue: id) {
            return category.displayName
        }
        if id == "outside-scan-scope" {
            return "Outside scan scope"
        }
        return "Other used storage"
    }

    /// Converts bytes to GB/TB string (no space)
    private func bytesToGBString(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1000 {
            let tb = gb / 1000
            return String(format: "%.0fTB", tb)
        } else if gb >= 10 {
            return String(format: "%.0fGB", gb)
        } else {
            return String(format: "%.1fGB", gb)
        }
    }
}

private struct RenderedSegment: Identifiable {
    let id: String
    let color: Color
    let fraction: CGFloat
}

private struct DriveBarSegmentHelpModifier: ViewModifier {
    let isInteractive: Bool

    func body(content: Content) -> some View {
        if isInteractive {
            content.help("Open category")
        } else {
            content
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        Text("Drive Bar - Simple")
            .font(.headline)

        DriveBarView(
            totalBytes: 500_000_000_000,
            usedBytes: 450_000_000_000,
            freeBytes: 50_000_000_000,
            categorySegments: [
                DriveBarSegment(id: "dev", bytes: 120_000_000_000, color: .orange),
                DriveBarSegment(id: "apps", bytes: 90_000_000_000, color: .indigo),
                DriveBarSegment(id: "media", bytes: 80_000_000_000, color: .pink),
                DriveBarSegment(id: "downloads", bytes: 40_000_000_000, color: .blue)
            ],
            highlightedSegmentID: .constant(nil)
        )
        Text("Nearly full (90% used)")
            .font(.caption)
            .foregroundStyle(.secondary)

        DriveBarView(totalBytes: 500_000_000_000, usedBytes: 300_000_000_000, freeBytes: 200_000_000_000, highlightedSegmentID: .constant(nil))
        Text("Normal usage (60% used)")
            .font(.caption)
            .foregroundStyle(.secondary)

        DriveBarView(totalBytes: 500_000_000_000, usedBytes: 100_000_000_000, freeBytes: 400_000_000_000, highlightedSegmentID: .constant(nil))
        Text("Lots of space (20% used)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding()
    .frame(width: 320)
}
