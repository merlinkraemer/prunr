import SwiftUI

/// One change on a single line: icon, name, and the signed amount on the right
/// (orange when space was used, grey when it was given back). Clicking reveals
/// the place in Finder.
struct ChangeRow: View {
    let episode: ChangeEpisode
    let onReveal: (String) -> Void

    @State private var isHovering = false
    @State private var isMissing = false

    private var isRevealable: Bool { episode.rootPath != nil }

    var body: some View {
        Button(action: reveal) {
            HStack(spacing: 10) {
                UnitIconTile(category: episode.category, source: episode.iconSource)

                Text(episode.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isMissing {
                    Text(Self.missingText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }

                Text(amountText)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(episode.isGrowth ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
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
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isRevealable ? "Shows this place in Finder" : "")
    }

    static let missingText = "No longer on disk"

    private var accessibilityText: String {
        isMissing
            ? "\(episode.title), \(Self.missingText), \(amountText)"
            : "\(episode.title), \(amountText)"
    }

    private var amountText: String { signedBytes(episode.netBytes) }

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
