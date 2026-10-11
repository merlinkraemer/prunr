import SwiftUI

/// One change: category tile, name with a muted "time · detail" caption, and
/// the signed amount on the right (orange when space was used, grey when it was
/// given back). Clicking reveals the place in Finder.
struct ChangeRow: View {
    let episode: ChangeEpisode
    let caption: String
    let onReveal: (String) -> Void

    @State private var isHovering = false
    @State private var isMissing = false

    private var isRevealable: Bool { episode.rootPath != nil }

    var body: some View {
        Button(action: reveal) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(episode.category.color)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: episode.category.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(episode.title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(isMissing ? "No longer on disk" : caption)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(amountText)
                    .font(.system(size: 13, weight: episode.isGrowth ? .semibold : .medium, design: .monospaced))
                    .foregroundStyle(episode.isGrowth ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering && isRevealable ? Color.gray.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isRevealable)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .help(isRevealable ? "Show in Finder" : "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(episode.title), \(caption), \(amountText)")
        .accessibilityHint(isRevealable ? "Shows this place in Finder" : "")
    }

    private var amountText: String {
        "\(episode.netBytes > 0 ? "+" : "\u{2212}")\(formattedBytes(abs(episode.netBytes)))"
    }

    private func reveal() {
        guard let rootPath = episode.rootPath else { return }
        guard FileManager.default.fileExists(atPath: rootPath) else {
            isMissing = true
            return
        }
        isMissing = false
        onReveal(rootPath)
    }
}
