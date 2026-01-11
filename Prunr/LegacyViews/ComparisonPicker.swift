import SwiftUI

/// A dropdown picker for selecting comparison time intervals
/// Provides presets (1h, 12h, 1d, 3d, 1w, 1m)
struct ComparisonPicker: View {
    /// Binding to the selected comparison interval in seconds
    @Binding var selectedInterval: TimeInterval

    /// Available comparison presets
    struct Preset: Identifiable {
        let id: String
        let label: String
        let interval: TimeInterval
    }

    /// All available presets
    /// Complete set: 1h, 12h, 1d, 3d, 1w, 1m
    private let presets: [Preset] = [
        Preset(id: "1h", label: "Last 1 hour", interval: 3600),           // 1 hour
        Preset(id: "12h", label: "Last 12 hours", interval: 43200),       // 12 hours
        Preset(id: "1d", label: "Last 1 day", interval: 86400),          // 24 hours = 1 day
        Preset(id: "3d", label: "Last 3 days", interval: 259200),        // 3 days
        Preset(id: "1w", label: "Last 1 week", interval: 604800),        // 7 days = 1 week
        Preset(id: "1m", label: "Last 1 month", interval: 2592000),      // 30 days = 1 month
    ]

    var body: some View {
        Picker("Compare Since", selection: $selectedInterval) {
            ForEach(presets) { preset in
                Text(preset.label).tag(preset.interval)
            }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 150)
        .onChange(of: selectedInterval) { _, newValue in
            // Persist to UserDefaults whenever the selection changes
            UserDefaults.standard.set(newValue, forKey: "comparisonInterval")
        }
    }
}

#Preview {
    ComparisonPicker(selectedInterval: .constant(2592000))
}
