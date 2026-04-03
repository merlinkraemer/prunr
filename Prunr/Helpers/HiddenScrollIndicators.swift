import SwiftUI
import AppKit

private struct HiddenScrollIndicatorsModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollIndicators(.hidden)
            .background(ScrollViewAccessor())
    }
}

extension View {
    func hiddenScrollIndicators() -> some View {
        modifier(HiddenScrollIndicatorsModifier())
    }
}

private struct ScrollViewAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = enclosingScrollView(from: nsView) else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.verticalScroller?.isHidden = true
            scrollView.horizontalScroller?.isHidden = true
        }
    }

    private func enclosingScrollView(from view: NSView) -> NSScrollView? {
        var currentView: NSView? = view
        while let candidate = currentView {
            if let scrollView = candidate as? NSScrollView {
                return scrollView
            }

            if let scrollView = candidate.enclosingScrollView {
                return scrollView
            }

            currentView = candidate.superview
        }

        return nil
    }
}
