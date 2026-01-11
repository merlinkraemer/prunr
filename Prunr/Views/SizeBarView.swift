import SwiftUI

/// Visual size bar component showing relative size as a horizontal bar
///
/// Size bar semantics:
/// - Shows the size of an item relative to the maximum size
/// - Uses a single color (category-specific) to indicate size proportion
/// - Like DaisyDisk's size bars - helps visualize relative disk usage
struct SizeBarView: View {
    /// The size in bytes to display
    let sizeBytes: Int64

    /// Maximum bytes value for proportional width calculation
    let maxBytes: Int64

    /// Bar height
    var height: CGFloat = 8

    /// Corner radius
    var cornerRadius: CGFloat = 4

    /// Minimum width proportion (0.2 = 20% of max bar width)
    /// Ensures all bars are visible even when one category dominates
    var minimumWidth: Double = 0.2

    /// Color for the bar (can be category-specific)
    var barColor: Color = .blue

    var body: some View {
        let relativeWidth = max(0.0, min(1.0, abs(Double(sizeBytes)) / abs(Double(maxBytes))))
        // Apply minimum width: the smallest bar is still minimumWidth proportion visible
        let effectiveWidth = minimumWidth + (relativeWidth * (1 - minimumWidth))

        GeometryReader { geometry in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(barColor.opacity(0.7))
                    .frame(width: geometry.size.width * CGFloat(effectiveWidth))
                Spacer()
            }
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.3), value: sizeBytes)
        .opacity(effectiveWidth == 0 ? 0 : 1)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        Text("Size Bar Examples (showing relative category sizes)")
            .font(.headline)
            .padding(.bottom, 8)

        SizeBarView(sizeBytes: 1_000_000_000, maxBytes: 2_000_000_000, barColor: .blue)
        Text("1 GB / 2 GB max (50% width)")
            .font(.caption)
            .foregroundStyle(.secondary)

        SizeBarView(sizeBytes: 500_000_000, maxBytes: 2_000_000_000, barColor: .orange)
        Text("500 MB / 2 GB max (25% relative)")
            .font(.caption)
            .foregroundStyle(.secondary)

        SizeBarView(sizeBytes: 50_000_000, maxBytes: 2_000_000_000, barColor: .green)
        Text("50 MB / 2 GB max (smallest, but min 20% width)")
            .font(.caption)
            .foregroundStyle(.secondary)

        SizeBarView(sizeBytes: 0, maxBytes: 2_000_000_000, barColor: .gray)
        Text("Empty (hidden)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding()
    .frame(width: 300)
}
