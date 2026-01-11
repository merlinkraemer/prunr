import SwiftUI

struct MenuBarView: View {
    var body: some View {
        VStack(spacing: 16) {
            // Header with app name
            HStack {
                Image(systemName: "harddrive.fill")
                    .foregroundStyle(.blue)
                Text("Prunr")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Placeholder content - will be replaced with growth list in Phase 4
            VStack(spacing: 8) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)

                Text("Disk Growth Tracker")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("Coming soon")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer buttons
            HStack(spacing: 12) {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Settings...") {
                    // TODO: Phase 5
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
            }
        }
        .padding()
        .frame(width: 280, height: 200)
    }
}

#Preview {
    MenuBarView()
}
