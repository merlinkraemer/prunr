import SwiftUI

struct UnitIconTile: View {
    let category: GrowthCategory
    let source: UnitIconSource
    let size: CGFloat

    @State private var resolvedIcon: NSImage?

    @MainActor
    init(category: GrowthCategory, source: UnitIconSource, size: CGFloat = 20) {
        self.category = category
        self.source = source
        self.size = size
        _resolvedIcon = State(initialValue: UnitIconResolver.shared.icon(for: source))
    }

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
