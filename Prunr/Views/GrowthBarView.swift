import SwiftUI

/// Visual growth bar component showing size change as a horizontal bar
///
/// Growth bar semantics:
/// - RED (growth) = space was consumed = bad for disk usage
/// - GREEN (shrinkage) = space was freed = good for disk usage
struct GrowthBarView: View {
    /// The change in bytes (positive = growth, negative = shrinkage)
    let changeBytes: Int64

    /// Maximum bytes value for proportional width calculation
    let maxBytes: Int64

    /// Bar height
    var height: CGFloat = 8

    /// Corner radius
    var cornerRadius: CGFloat = 4

    /// Minimum width proportion (0.2 = 20% of max bar width)
    /// Ensures all bars are visible even when one category dominates
    var minimumWidth: Double = 0.2

    var body: some View {
        let relativeWidth = max(0.0, min(1.0, abs(Double(changeBytes)) / abs(Double(maxBytes))))
        // Apply minimum width: the smallest bar is still minimumWidth proportion visible
        let effectiveWidth = minimumWidth + (relativeWidth * (1 - minimumWidth))

        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(barColor)
            .frame(width: effectiveWidth == 0 ? 0 : nil)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.3), value: changeBytes)
            .opacity(effectiveWidth == 0 ? 0 : 1)
    }

    /// Color based on growth direction
    /// RED = growth (space consumed, bad)
    /// GREEN = shrinkage (space freed, good)
    private var barColor: Color {
        if changeBytes > 0 {
            return .red  // Growth = space consumed = bad
        } else if changeBytes < 0 {
            return .green  // Shrinkage = space freed = good
        } else {
            return .gray
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        Text("Growth Bar Examples (RED=bad/growth, GREEN=good/shrinkage)")
            .font(.headline)
            .padding(.bottom, 8)

        GrowthBarView(changeBytes: 1_000_000_000, maxBytes: 2_000_000_000)
        Text("+1 GB / 2 GB max (largest = 100% width)")
            .font(.caption)
            .foregroundStyle(.secondary)

        GrowthBarView(changeBytes: 500_000_000, maxBytes: 2_000_000_000)
        Text("+500 MB / 2 GB max (50% relative)")
            .font(.caption)
            .foregroundStyle(.secondary)

        GrowthBarView(changeBytes: 50_000_000, maxBytes: 2_000_000_000)
        Text("+50 MB / 2 GB max (smallest, but min 20% width)")
            .font(.caption)
            .foregroundStyle(.secondary)

        GrowthBarView(changeBytes: -250_000_000, maxBytes: 2_000_000_000)
        Text("-250 MB (shrinkage, green)")
            .font(.caption)
            .foregroundStyle(.secondary)

        GrowthBarView(changeBytes: 0, maxBytes: 2_000_000_000)
        Text("No change (gray, hidden)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding()
    .frame(width: 300)
}
