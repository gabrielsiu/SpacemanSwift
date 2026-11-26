//
//  ZoomableView.swift
//  SpacemanSwift
//
//  Pinch-to-zoom, pan and double-tap-to-zoom container built on UIScrollView,
//  so zoom tracks the pinch centroid, the same two fingers can pan mid-pinch,
//  and the limits rubber-band — like Photos / Apollo.
//  When not zoomed, a horizontal swipe drags the strip with the finger and
//  calls `onSwipe` once it commits.
//

import SwiftUI
import UIKit

enum SwipeDirection { case left, right }

struct ZoomableView<Content: View>: View {
    /// Current zoom level (1 = not zoomed). Set to 1 externally to reset.
    @Binding var scale: CGFloat
    /// Horizontal page-swipe offset, driven live by the finger while not zoomed.
    @Binding var swipeOffset: CGFloat
    /// Whether there is a page in the given direction (otherwise the swipe rubber-bands).
    var canSwipe: (SwipeDirection) -> Bool = { _ in true }
    /// Called once the swipe has committed and the strip has slid off screen.
    var onSwipe: ((SwipeDirection) -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            // Darkens as the user zooms, to emphasize the strip.
            Color.black
                .opacity(min((scale - 1) / 0.5, 1) * 0.9)
            ZoomScrollView(scale: $scale, swipeOffset: $swipeOffset,
                           canSwipe: canSwipe, onSwipe: onSwipe, content: content)
                .offset(x: swipeOffset)
        }
        .clipped()
        .ignoresSafeArea()
    }
}

private struct ZoomScrollView<Content: View>: UIViewRepresentable {
    @Binding var scale: CGFloat
    @Binding var swipeOffset: CGFloat
    var canSwipe: (SwipeDirection) -> Bool
    var onSwipe: ((SwipeDirection) -> Void)?
    var content: Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> FittingScrollView {
        let coordinator = context.coordinator
        let scrollView = FittingScrollView()
        scrollView.delegate = coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        // At 1x the content exactly fits, so the scroll view must not bounce
        // on its own; the page swipe below handles horizontal drags instead.
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.decelerationRate = .fast

        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        scrollView.addSubview(host.view)
        scrollView.hostView = host.view
        coordinator.host = host
        coordinator.scrollView = scrollView

        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let pageSwipe = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pageSwiped(_:)))
        pageSwipe.maximumNumberOfTouches = 1
        pageSwipe.delegate = coordinator
        scrollView.addGestureRecognizer(pageSwipe)

        return scrollView
    }

    func updateUIView(_ scrollView: FittingScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.host?.rootView = content

        // External reset (Reset Zoom button, new strip): animate back to 1x.
        if scale <= 1, scrollView.zoomScale > 1.01, !coordinator.isUserInteracting {
            scrollView.setZoomScale(1, animated: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomScrollView
        var host: UIHostingController<Content>?
        weak var scrollView: UIScrollView?

        init(_ parent: ZoomScrollView) { self.parent = parent }

        var isUserInteracting: Bool {
            guard let s = scrollView else { return false }
            return s.isZooming || s.isDragging || s.isDecelerating || s.isZoomBouncing
        }

        private var isZoomed: Bool {
            (scrollView?.zoomScale ?? 1) > 1.01
        }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? FittingScrollView)?.hostView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? FittingScrollView)?.centerContent()
            let newScale = max(scrollView.zoomScale, 1)
            if abs(parent.scale - newScale) > .ulpOfOne { parent.scale = newScale }
        }

        // MARK: Double tap

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = scrollView, let hostView = (scrollView as? FittingScrollView)?.hostView else { return }
            if isZoomed {
                scrollView.setZoomScale(1, animated: true)
                return
            }
            let zoom: CGFloat = 2.5
            let point = recognizer.location(in: hostView)
            let size = scrollView.bounds.size
            let rect = CGRect(x: point.x - size.width / zoom / 2,
                              y: point.y - size.height / zoom / 2,
                              width: size.width / zoom,
                              height: size.height / zoom)
            scrollView.zoom(to: rect, animated: true)
        }

        // MARK: Page swipe (only while not zoomed)

        @objc func pageSwiped(_ recognizer: UIPanGestureRecognizer) {
            guard let scrollView = scrollView else { return }
            let reference = scrollView.superview ?? scrollView
            let dx = recognizer.translation(in: reference).x
            let width = scrollView.bounds.width

            switch recognizer.state {
            case .changed:
                // Rubber-band when there's nothing in that direction.
                parent.swipeOffset = parent.canSwipe(dx < 0 ? .left : .right) ? dx : dx * 0.25
            case .ended:
                let direction: SwipeDirection = dx < 0 ? .left : .right
                let projected = dx + recognizer.velocity(in: reference).x * 0.25
                let commits = parent.canSwipe(direction)
                    && (abs(dx) > width * 0.3 || (abs(projected) > width * 0.6 && abs(dx) > 30))
                if commits {
                    let target = direction == .left ? -width : width
                    let onSwipe = parent.onSwipe
                    withAnimation(.easeOut(duration: 0.2)) {
                        parent.swipeOffset = target
                    } completion: {
                        onSwipe?(direction)
                    }
                } else {
                    withAnimation(.snappy) { parent.swipeOffset = 0 }
                }
            case .cancelled, .failed:
                withAnimation(.snappy) { parent.swipeOffset = 0 }
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            guard !isZoomed else { return false }
            // Horizontal-dominant drags only, so vertical scrolls aren't hijacked.
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Scroll view whose single zoomable subview always fills the bounds at 1x and
/// is centred (via insets) whenever it is smaller than the viewport.
private final class FittingScrollView: UIScrollView {
    var hostView: UIView?
    private var laidOutSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let hostView, bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0 else { return }
        laidOutSize = bounds.size
        zoomScale = 1
        hostView.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
        contentOffset = .zero
        centerContent()
    }

    func centerContent() {
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}
