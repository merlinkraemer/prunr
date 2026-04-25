import SwiftUI
import AppKit

/// Hides scroll indicators on any enclosing NSScrollView reliably.
/// Uses a custom NSView subclass that detects window attachment and walks
/// up the view hierarchy to find the NSScrollView. This is more reliable
/// than the old .background() + DispatchQueue.main.async hack which could
/// race the initial render before the view was in the window hierarchy.
private struct HiddenScrollIndicatorsModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollIndicators(.hidden)
            .background(ScrollViewHider().frame(width: 0, height: 0))
    }
}

extension View {
    func hiddenScrollIndicators() -> some View {
        modifier(HiddenScrollIndicatorsModifier())
    }
}

// MARK: - ScrollView Hider

private final class ScrollViewHiderView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }

        var current: NSView? = self
        while let view = current {
            if let scrollView = view as? NSScrollView {
                configure(scrollView)
                return
            }
            if let scrollView = view.enclosingScrollView {
                configure(scrollView)
                return
            }
            current = view.superview
        }
    }

    private func configure(_ scrollView: NSScrollView) {
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller?.isHidden = true
        scrollView.horizontalScroller?.isHidden = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
    }
}

private struct ScrollViewHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ScrollViewHiderView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
