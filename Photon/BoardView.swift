//
//  BoardView.swift
//  Photon
//
//  Created by Kevin Ngo on 8/4/26.
//

import SwiftUI
import UIKit

let rows = 17
let columns = 17

struct BoardView: View {
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 6.0

    var body: some View {
        GeometryReader { geometry in
            ZStack (alignment: .bottomTrailing) {
                Grid(horizontalSpacing: 1.0, verticalSpacing: 1.0) {
                    ForEach(0..<rows, id: \.self) { row in
                        GridRow {
                            ForEach(0..<columns, id: \.self) { col in
                                Rectangle()
                                    .fill((row + col) % 2 == 0 ? Color.boardTileA : Color.boardTileB)
                                    .frame(width: geometry.size.width / 18.0, height: geometry.size.width / 18.0)
                            }
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(scale)
                .offset(offset)

                // Handles pinch-to-zoom (anchored to pinch point) and
                // 1- or 2-finger pan, composed correctly when simultaneous.
                PinchPanGestureView(
                    scale: $scale,
                    offset: $offset,
                    containerSize: geometry.size,
                    minScale: minScale,
                    maxScale: maxScale
                )
                if scale != 1.0 {
                    Button(action: {
                        withAnimation(.snappy) {
                            scale = 1.0
                            offset = .zero
                        }
                        
                    }){
                        Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                            .foregroundStyle(Color.textPrimary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .glassEffect(.regular.tint(.gridUIElevated), in: RoundedRectangle(cornerRadius: 25.0))
                    }
                    .padding(.bottom, 12)
                    .padding(.trailing, 16)
                } else {
                    Button(action: {
                        withAnimation(.snappy) {
                            scale = 2.0
                            offset = .zero
                        }
                        
                    }){
                        Image(systemName: "plus.magnifyingglass")
                            .foregroundStyle(Color.textPrimary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .glassEffect(.regular.tint(.gridUIElevated), in: RoundedRectangle(cornerRadius: 25.0))
                    }
                    .padding(.bottom, 12)
                    .padding(.trailing, 16)
                }
            }
            
            
        }
        .clipped()
        
    }
}

// MARK: - UIKit gesture bridge

struct PinchPanGestureView: UIViewRepresentable {
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    var containerSize: CGSize
    var minScale: CGFloat
    var maxScale: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(scale: $scale, offset: $offset)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.scale = $scale
        context.coordinator.offset = $offset
        context.coordinator.containerSize = containerSize
        context.coordinator.minScale = minScale
        context.coordinator.maxScale = maxScale
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var scale: Binding<CGFloat>
        var offset: Binding<CGSize>
        var containerSize: CGSize = .zero
        var minScale: CGFloat = 1.0
        var maxScale: CGFloat = 6.0

        init(scale: Binding<CGFloat>, offset: Binding<CGSize>) {
            self.scale = scale
            self.offset = offset
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true // let pinch and pan run at the same time
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .changed:
                let location = gesture.location(in: gesture.view)
                let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
                let anchor = CGPoint(x: location.x - center.x, y: location.y - center.y)

                let currentScale = scale.wrappedValue
                let newScale = (currentScale * gesture.scale).clamped(to: minScale...maxScale)
                gesture.scale = 1

                let factor = newScale / currentScale
                let currentOffset = offset.wrappedValue
                var newOffset = CGSize(
                    width: anchor.x - factor * (anchor.x - currentOffset.width),
                    height: anchor.y - factor * (anchor.y - currentOffset.height)
                )

                // Force back to centered once we hit minimum zoom
                if newScale <= minScale {
                    newOffset = .zero
                }

                scale.wrappedValue = newScale
                offset.wrappedValue = rubberBandClamped(newOffset, scale: newScale, in: containerSize)

            case .ended, .cancelled:
                snapBack()
            default:
                break
            }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .changed:
                // No room to pan when fully zoomed out — ignore the gesture entirely.
                guard scale.wrappedValue > minScale else {
                    gesture.setTranslation(.zero, in: gesture.view)
                    return
                }

                let t = gesture.translation(in: gesture.view)
                gesture.setTranslation(.zero, in: gesture.view)

                let proposed = CGSize(
                    width: offset.wrappedValue.width + t.x,
                    height: offset.wrappedValue.height + t.y
                )
                offset.wrappedValue = rubberBandClamped(proposed, scale: scale.wrappedValue, in: containerSize)

            case .ended, .cancelled:
                snapBack()
            default:
                break
            }
        }

        private func snapBack() {
            let target = clampedOffset(offset.wrappedValue, scale: scale.wrappedValue, in: containerSize)
            withAnimation(.snappy) {
                offset.wrappedValue = target
            }
        }
    }
}

// MARK: - Bounds helpers

private func clampedOffset(_ proposed: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
    let maxX = max(0, (size.width * (scale - 1)) / 2)
    let maxY = max(0, (size.height * (scale - 1)) / 2)
    return CGSize(
        width: min(max(proposed.width, -maxX), maxX),
        height: min(max(proposed.height, -maxY), maxY)
    )
}

private func rubberBandClamped(_ proposed: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
    let maxX = max(0, (size.width * (scale - 1)) / 2)
    let maxY = max(0, (size.height * (scale - 1)) / 2)
    return CGSize(
        width: rubberBand(proposed.width, limit: maxX, dimension: size.width),
        height: rubberBand(proposed.height, limit: maxY, dimension: size.height)
    )
}

private func rubberBand(_ value: CGFloat, limit: CGFloat, dimension: CGFloat, coefficient: CGFloat = 0.55) -> CGFloat {
    guard dimension > 0 else { return 0 }
    let absValue = abs(value)
    guard absValue > limit else { return value }
    let overflow = absValue - limit
    let damped = (overflow * coefficient * dimension) / (overflow + coefficient * dimension)
    return value < 0 ? -(limit + damped) : (limit + damped)
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    BoardView()
}
