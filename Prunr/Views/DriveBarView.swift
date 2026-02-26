import SwiftUI

/// Visual drive bar showing used and free disk space - minimal single row
struct DriveBarView: View {
    /// Total disk space in bytes
    let totalBytes: Int64

    /// Used disk space in bytes
    let usedBytes: Int64

    /// Free disk space in bytes
    let freeBytes: Int64

    /// Bar height
    private let barHeight: CGFloat = 12

    var body: some View {
        HStack(spacing: 12) {
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: barHeight / 2)
                        .fill(Color.gray.opacity(0.15))

                    RoundedRectangle(cornerRadius: barHeight / 2)
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
            .frame(height: barHeight)

            // Free space text
            HStack(spacing: 4) {
                Text(bytesToGBString(freeBytes))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("free")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
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
        Text("Drive Bar - Simple")
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
