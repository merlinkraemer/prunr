import SwiftUI

/// A list body without rows: one quiet sentence in the middle, with an
/// optional Retry. Used for day one and for a history that cannot be read.
struct ChangeFeedStateView: View {
    static func dayOneText(folder: ScanFolderName) -> String {
        "Watching \(folder.phrase) since today. Changes show here from tomorrow."
    }
    static let failedText = "Couldn't read change history"

    let message: String
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
