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
        scheduleConfigurePasses()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleConfigurePasses()
    }

    func refresh() {
        scheduleConfigurePasses()
    }

    private func scheduleConfigurePasses() {
        guard window != nil else { return }

        DispatchQueue.main.async { [weak self] in
            self?.configureNearbyScrollViews()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.configureNearbyScrollViews()
        }
    }

    private func configureNearbyScrollViews() {
        var current: NSView? = self
        while let view = current {
            if let scrollView = view as? NSScrollView {
                configure(scrollView)
            }
            if let scrollView = view.enclosingScrollView {
                configure(scrollView)
            }
            current = view.superview
        }

        // SwiftUI may place this representable in a sibling/descendant tree of
        // the AppKit NSScrollView after the first layout pass. As a final local
        // fallback, hide all scroll indicators in the same window. This modifier
        // is only attached to Prunr's chrome/list scroll views, where hidden
        // indicators are the intended visual style.
        if let contentView = window?.contentView {
            configureScrollViews(in: contentView)
        }
    }

    private func configureScrollViews(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            configure(scrollView)
        }

        for subview in view.subviews {
            configureScrollViews(in: subview)
        }
    }

    private func configure(_ scrollView: NSScrollView) {
        if scrollView.hasVerticalScroller {
            scrollView.hasVerticalScroller = false
        }
        if scrollView.hasHorizontalScroller {
            scrollView.hasHorizontalScroller = false
        }
        if scrollView.verticalScroller?.isHidden == false {
            scrollView.verticalScroller?.isHidden = true
        }
        if scrollView.horizontalScroller?.isHidden == false {
            scrollView.horizontalScroller?.isHidden = true
        }
        if !scrollView.autohidesScrollers {
            scrollView.autohidesScrollers = true
        }
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
    }
}

private struct ScrollViewHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ScrollViewHiderView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let hider = nsView as? ScrollViewHiderView else { return }
        hider.refresh()
    }
}
