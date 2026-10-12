import SwiftUI

/// A place's icon in the change list: the real app or file icon when one
/// resolves, else the category symbol in its colour, both without a tile.
struct UnitIconTile: View {
    let category: GrowthCategory
    let source: UnitIconSource
    var size: CGFloat = 20

    @State private var resolvedIcon: NSImage?

    var body: some View {
        Group {
            if let resolvedIcon {
                Image(nsImage: resolvedIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: category.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(category.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: source) {
            resolvedIcon = UnitIconResolver.shared.icon(for: source)
        }
    }
}
