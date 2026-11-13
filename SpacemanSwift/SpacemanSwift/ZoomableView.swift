//
//  ZoomableView.swift
//  SpacemanSwift
//
//  Pinch-to-zoom, drag-to-pan and double-tap-to-zoom container.
//  When not zoomed, a horizontal swipe drags the strip with the finger and
//  calls `onSwipe` once it commits.
//

import SwiftUI

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

    private let maxScale: CGFloat = 5

    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Darkens as the user zooms, to emphasize the strip.
                Color.black
                    .opacity(min((scale - 1) / 0.5, 1) * 0.9)
                content
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .offset(x: swipeOffset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Make the whole area (not just the strip) respond to gestures.
            .contentShape(Rectangle())
            .gesture(dragGesture(in: proxy.size))
            .simultaneousGesture(magnifyGesture(in: proxy.size))
            .onTapGesture(count: 2) { toggleZoom() }
        }
        .clipped()
        .ignoresSafeArea()
        .onChange(of: scale) { _, newScale in
            if newScale <= 1 {
                baseScale = 1
                offset = .zero
                baseOffset = .zero
            } else {
                baseScale = newScale
            }
        }
    }

    private func magnifyGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(baseScale * value.magnification, 1), maxScale)
                offset = clamped(baseOffset, in: size)
            }
            .onEnded { _ in
                baseScale = scale
                offset = clamped(offset, in: size)
                baseOffset = offset
            }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if scale > 1 {
                    offset = clamped(
                        CGSize(width: baseOffset.width + value.translation.width,
                               height: baseOffset.height + value.translation.height),
                        in: size)
                } else {
                    let dx = value.translation.width
                    // Rubber-band when there's nothing in that direction.
                    swipeOffset = canSwipe(dx < 0 ? .left : .right) ? dx : dx * 0.25
                }
            }
            .onEnded { value in
                if scale > 1 {
                    baseOffset = offset
                    return
                }
                let dx = value.translation.width
                let direction: SwipeDirection = dx < 0 ? .left : .right
                let projected = value.predictedEndTranslation.width
                let commits = canSwipe(direction)
                    && (abs(dx) > size.width * 0.3 || (abs(projected) > size.width * 0.6 && abs(dx) > 30))
                if commits {
                    let target = direction == .left ? -size.width : size.width
                    withAnimation(.easeOut(duration: 0.2)) {
                        swipeOffset = target
                    } completion: {
                        onSwipe?(direction)
                    }
                } else {
                    withAnimation(.snappy) { swipeOffset = 0 }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.snappy) {
            scale = scale > 1 ? 1 : 2.5
        }
    }

    private func clamped(_ o: CGSize, in size: CGSize) -> CGSize {
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        return CGSize(width: min(max(o.width, -maxX), maxX),
                      height: min(max(o.height, -maxY), maxY))
    }
}
