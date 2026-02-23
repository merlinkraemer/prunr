import SwiftUI

/// Visual drive bar showing used and free disk space with modern design
struct DriveBarView: View {
    /// Total disk space in bytes
    let totalBytes: Int64

    /// Used disk space in bytes
    let usedBytes: Int64

    /// Free disk space in bytes
    let freeBytes: Int64

    /// Bar height
    var height: CGFloat = 16

    /// Corner radius
    var cornerRadius: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Visual bar at top with gradient based on usage
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.gray.opacity(0.15))

                    // Used space bar with gradient
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(
                            LinearGradient(
                                colors: [usageColor.opacity(0.8), usageColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * CGFloat(usedPercentage) / 100.0)
                }
            }
            .frame(height: height)

            // Text row: icon + "X GB of Y GB used" left-aligned, percentage tag right-aligned
            HStack(alignment: .center, spacing: 6) {
                // Drive icon
                Image(systemName: "internaldrive")
                    .font(.system(size: 14))
                    .foregroundStyle(usageColor)

                Text(bytesToGBString(usedBytes))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)

                Text("of")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(bytesToGBString(totalBytes))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)

                Text("used")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                // Percentage tag
                Text("\(usedPercentage)%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(usageColor, in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.vertical, 4)
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

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        Text("Drive Bar - Redesigned")
            .font(.headline)

        DriveBarView(totalBytes: 500_000_000_000, usedBytes: 450_000_000_000, freeBytes: 50_000_000_000)
        Text("Nearly full (90% used)")
            .font(.caption)
            .foregroundStyle(.secondary)

        DriveBarView(totalBytes: 500_000_000_000, usedBytes: 300_000_000_000, freeBytes: 200_000_000_000)
        Text("Normal usage (60% used)")
            .font(.caption)
            .foregroundStyle(.secondary)

        DriveBarView(totalBytes: 500_000_000_000, usedBytes: 100_000_000_000, freeBytes: 400_000_000_000)
        Text("Lots of space (20% used)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding()
    .frame(width: 320)
}
