import SwiftUI

/// A dropdown picker for selecting comparison time intervals
/// Provides presets (1h, 12h, 24h, 3d, 7d) and a custom option
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
    private let presets: [Preset] = [
        Preset(id: "1h", label: "Last 1 hour", interval: 3600),
        Preset(id: "12h", label: "Last 12 hours", interval: 43200),
        Preset(id: "24h", label: "Last 24 hours", interval: 86400),
        Preset(id: "3d", label: "Last 3 days", interval: 259200),
        Preset(id: "7d", label: "Last 7 days", interval: 604800),
    ]

    /// Value used for the "Custom..." option
    private let customIntervalValue: TimeInterval = -1

    var body: some View {
        Picker("Compare Since", selection: $selectedInterval) {
            ForEach(presets) { preset in
                Text(preset.label).tag(preset.interval)
            }
            Divider()
            Text("Custom...").tag(customIntervalValue)
        }
        .pickerStyle(.menu)
        .frame(minWidth: 150)
        .onChange(of: selectedInterval) { _, newValue in
            // Persist to UserDefaults whenever the selection changes
            if newValue != customIntervalValue {
                UserDefaults.standard.set(newValue, forKey: "comparisonInterval")
            }
        }
    }
}

#Preview {
    ComparisonPicker(selectedInterval: .constant(86400))
}
