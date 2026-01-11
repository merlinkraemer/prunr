import SwiftUI

/// Visual drive bar showing used and free disk space
struct DriveBarView: View {
    /// Total disk space in bytes
    let totalBytes: Int64

    /// Used disk space in bytes
    let usedBytes: Int64

    /// Free disk space in bytes
    let freeBytes: Int64

    /// Bar height
    var height: CGFloat = 12

    /// Corner radius
    var cornerRadius: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Visual bar with background track
            ZStack(alignment: .leading) {
                // Background track (gray)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.gray.opacity(0.2))

                // Used space bar (blue)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.blue)
                    .frame(width: barWidth(for: usedBytes))
            }
            .frame(height: height)

            // Labels
            HStack {
                Text(spaceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - Private Helpers

    /// Calculates proportional width for a segment
    private func barWidth(for bytes: Int64) -> CGFloat {
        guard totalBytes > 0 else { return 0 }
        let proportion = max(0, min(1, Double(bytes) / Double(totalBytes)))
        return proportion * 300 // Max width matching popover
    }

    /// Used percentage (0-100)
    private var usedPercentage: Int {
        guard totalBytes > 0 else { return 0 }
        return Int((Double(usedBytes) / Double(totalBytes)) * 100)
    }

    /// Space label (e.g., "50 GB free of 500 GB (75% used)")
    private var spaceLabel: String {
        "\(bytesToGBString(freeBytes)) free of \(bytesToGBString(totalBytes)) (\(usedPercentage)% used)"
    }

    /// Converts bytes to GB string (e.g., "50 GB")
    private func bytesToGBString(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1000 {
            let tb = gb / 1000
            return String(format: "%.0f TB", tb)
        } else if gb >= 10 {
            return String(format: "%.0f GB", gb)
        } else {
            return String(format: "%.1f GB", gb)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        Text("Drive Bar Examples")
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
