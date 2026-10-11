import SwiftUI

/// A place's icon in the change list: the real app or file icon when one
/// resolves, else the category symbol on its coloured tile.
struct UnitIconTile: View {
    let category: GrowthCategory
    let source: UnitIconSource
    var size: CGFloat = 24

    @State private var resolvedIcon: NSImage?

    var body: some View {
        Group {
            if let resolvedIcon {
                Image(nsImage: resolvedIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(category.color)
                    .overlay(
                        Image(systemName: category.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: source) {
            resolvedIcon = UnitIconResolver.shared.icon(for: source)
        }
    }
}
