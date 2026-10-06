//
//  BoardView.swift
//  Photon
//
//  Created by Kevin Ngo on 8/4/26.
//

import SwiftUI
import UIKit

/// What a `BoardView` shows, and where its taps go: the game, or the tutorial.
protocol BoardModel: AnyObject {
    var board: Board { get }
    /// The seat whose action the board is waiting for; playable squares are dotted in its color.
    var activeSeat: Player { get }
    var playableCells: Set<Int> { get }
    /// What the last move removed, drawn as ghosts.
    var ghosts: [Removal] { get }
    var lastMove: Int? { get }
    /// Squares ringed to point the player at them.
    var ringedCells: Set<Int> { get }
    func tap(_ cell: Int)
}

extension BoardModel {
    var ringedCells: Set<Int> { [] }
}

struct BoardView<Model: BoardModel, Header: View>: View {
    var model: Model
    /// How far views below overlap the bottom of the board area; the board stays clear of it.
    var bottomOverlap: CGFloat = 0
    /// Room kept just above the board for `header`; the two are centered together.
    var headerHeight: CGFloat = 0
    @ViewBuilder var header: Header

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 6.0

    var body: some View {
        GeometryReader { geometry in
            let layout = BoardLayout(containerSize: geometry.size, bottomOverlap: bottomOverlap, topInset: headerHeight,
                                     cells: model.board.size, scale: scale, offset: offset)
            ZStack (alignment: .bottomTrailing) {
                ZoomedBoard(scene: BoardScene(model: model), layout: layout)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                // Handles pinch-to-zoom (anchored to pinch point),
                // 1- or 2-finger pan, composed correctly when simultaneous,
                // and taps on squares.
                PinchPanGestureView(
                    scale: $scale,
                    offset: $offset,
                    containerSize: geometry.size,
                    minScale: minScale,
                    maxScale: maxScale,
                    onTap: { point in
                        if let cell = layout.cell(at: point) { model.tap(cell) }
                    }
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
            .overlay(alignment: .top) {
                header
                    .frame(height: headerHeight)
                    .padding(.top, max(0, layout.origin.y - headerHeight))
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
    var onTap: (CGPoint) -> Void

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

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.scale = $scale
        context.coordinator.offset = $offset
        context.coordinator.containerSize = containerSize
        context.coordinator.minScale = minScale
        context.coordinator.maxScale = maxScale
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var scale: Binding<CGFloat>
        var offset: Binding<CGSize>
        var containerSize: CGSize = .zero
        var minScale: CGFloat = 1.0
        var maxScale: CGFloat = 6.0
        var onTap: (CGPoint) -> Void = { _ in }

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

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended {
                onTap(gesture.location(in: gesture.view))
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

// MARK: - Geometry

/// Where squares sit in the view. The board is drawn unzoomed and the zoom applied as a
/// transform about the view's center, matching what scaleEffect + offset would do.
private struct BoardLayout {
    let containerSize: CGSize
    let bottomOverlap: CGFloat
    var topInset: CGFloat = 0
    let cells: Int
    var scale: CGFloat
    var offset: CGSize

    private var visibleHeight: CGFloat { max(0, containerSize.height - bottomOverlap) }
    var cellSize: CGFloat { max(1, floor((min(containerSize.width, visibleHeight - topInset) - 8) / CGFloat(cells))) }
    var center: CGPoint { CGPoint(x: containerSize.width / 2, y: containerSize.height / 2) }
    var origin: CGPoint {
        let side = cellSize * CGFloat(cells)
        return CGPoint(x: ((containerSize.width - side) / 2).rounded(),
                       y: ((visibleHeight - topInset - side) / 2).rounded() + topInset)
    }

    func rect(_ cell: Int) -> CGRect {
        CGRect(x: origin.x + CGFloat(cell % cells) * cellSize, y: origin.y + CGFloat(cell / cells) * cellSize,
               width: cellSize, height: cellSize)
    }

    func center(row: Int, col: Int) -> CGPoint {
        CGPoint(x: origin.x + (CGFloat(col) + 0.5) * cellSize, y: origin.y + (CGFloat(row) + 0.5) * cellSize)
    }

    func center(of cell: Int) -> CGPoint { center(row: cell / cells, col: cell % cells) }

    /// Applies the zoom to a canvas, so it can be drawn on in unzoomed coordinates.
    func zoom(_ context: inout GraphicsContext) {
        context.translateBy(x: center.x + offset.width, y: center.y + offset.height)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -center.x, y: -center.y)
    }

    /// The square under a point in the (zoomed) view.
    func cell(at point: CGPoint) -> Int? {
        let x = (point.x - center.x - offset.width) / scale + center.x
        let y = (point.y - center.y - offset.height) / scale + center.y
        let col = Int(floor((x - origin.x) / cellSize)), row = Int(floor((y - origin.y) / cellSize))
        guard row >= 0, row < cells, col >= 0, col < cells else { return nil }
        return row * cells + col
    }
}

// MARK: - Drawing

/// The board drawn at a given zoom. Animatable, so zoom and snap-back animations interpolate
/// while the canvas redraws crisply at every scale.
private struct ZoomedBoard: View, Animatable {
    let scene: BoardScene
    var layout: BoardLayout

    var animatableData: AnimatablePair<CGFloat, CGSize.AnimatableData> {
        get { AnimatablePair(layout.scale, layout.offset.animatableData) }
        set {
            layout.scale = newValue.first
            layout.offset.animatableData = newValue.second
        }
    }

    var body: some View {
        Canvas { [scene, layout] context, _ in
            scene.draw(in: &context, layout: layout)
        }
        .overlay {
            // Only the rings redraw every frame, to pulse.
            if !scene.rings.isEmpty {
                TimelineView(.animation) { timeline in
                    Canvas { [scene, layout] context, _ in
                        scene.drawRings(in: &context, layout: layout, at: timeline.date)
                    }
                }
            }
        }
    }
}

/// Everything the board draws, read from the model in `body` so SwiftUI tracks it.
private struct BoardScene {
    let board: Board
    let moat: [Bool]
    let dots: Set<Int>
    let dotColor: Color
    let ghosts: [Removal]
    let lastMove: Int?
    let rings: Set<Int>

    init(model: some BoardModel) {
        board = model.board
        moat = model.board.moat()
        dots = model.playableCells
        dotColor = .seat(model.activeSeat)
        ghosts = model.ghosts
        lastMove = model.lastMove
        rings = model.ringedCells
    }

    private static let laserInk = Color(hex: 0xFF6B8A)
    private static let diffuserInk = Color(hex: 0x7DD3FC)

    func draw(in context: inout GraphicsContext, layout: BoardLayout) {
        layout.zoom(&context)

        let n = board.size, cs = layout.cellSize
        for cell in 0..<n * n {
            let tile = Path(layout.rect(cell).insetBy(dx: 0.5, dy: 0.5))
            context.fill(tile, with: .color((cell / n + cell % n) % 2 == 0 ? .boardTileA : .boardTileB))
            if board.killzone[cell] {
                context.fill(tile, with: .color(.gridRed.opacity(0.32)))
            } else if board.grid[cell] == nil {
                let lit = board.lit[cell]
                if !lit.isEmpty { context.fill(tile, with: .color(Self.lightColor(lit).opacity(0.24))) }
                if moat[cell] { context.fill(tile, with: .color(.black.opacity(0.18))) }
            }
        }
        drawCoordinates(in: &context, layout: layout)
        drawBeams(in: &context, layout: layout)

        let dotRadius = max(1.6, cs * 0.07)
        for cell in dots {
            let p = layout.center(of: cell)
            context.fill(Path(ellipseIn: CGRect(x: p.x - dotRadius, y: p.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)),
                         with: .color(dotColor.opacity(0.6)))
        }

        for ghost in ghosts where board.grid[ghost.cell] == nil {
            drawGhost(ghost.piece, at: layout.center(of: ghost.cell), cellSize: cs, in: &context)
        }
        for cell in board.grid.indices {
            if let piece = board.grid[cell] { drawPiece(piece, at: layout.center(of: cell), cellSize: cs, in: &context) }
        }

        // Sources in check.
        for source in board.sources.joined() where board.killzone[source] {
            let p = layout.center(of: source), r = cs * 0.46
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .gridRed, radius: 4))
                layer.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(.gridRed), lineWidth: max(2, cs * 0.09))
            }
        }

        if let lastMove {
            context.stroke(Path(layout.rect(lastMove).insetBy(dx: 2, dy: 2)), with: .color(.textPrimary.opacity(0.85)), lineWidth: 2)
        }
    }

    /// A glowing ring on each ringed square, with a ripple spreading out from it.
    func drawRings(in context: inout GraphicsContext, layout: BoardLayout, at date: Date) {
        layout.zoom(&context)
        let cs = layout.cellSize, period = 1.4
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        for cell in rings {
            let rect = layout.rect(cell), corner = cs * 0.18
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .textPrimary, radius: 4))
                layer.stroke(Path(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerRadius: corner),
                             with: .color(.textPrimary), lineWidth: max(2, cs * 0.06))
            }
            let spread = cs * 0.45 * phase
            context.stroke(Path(roundedRect: rect.insetBy(dx: -spread, dy: -spread), cornerRadius: corner + spread),
                           with: .color(.textPrimary.opacity(0.75 * (1 - phase))), lineWidth: max(1.5, cs * 0.045))
        }
    }

    private static func lightColor(_ owners: Owners) -> Color {
        if owners.contains(.shared) || owners.isSuperset(of: [.of(0), .of(1)]) { return .gridGreen }
        return owners.contains(.of(0)) ? .seat(0) : .seat(1)
    }

    /// Column letters along the top edge, row numbers down the left, as the move log names squares.
    private func drawCoordinates(in context: inout GraphicsContext, layout: BoardLayout) {
        let cs = layout.cellSize, inset = cs * 0.08
        let font = Font.system(size: max(6, cs * 0.22), weight: .semibold, design: .monospaced)
        for i in 0..<board.size {
            let top = layout.rect(i), left = layout.rect(i * board.size)
            context.draw(Text(board.coordinate(i).prefix(1)).font(font).foregroundStyle(Color.textSecondary.opacity(0.75)),
                         at: CGPoint(x: top.maxX - inset, y: top.minY + inset), anchor: .topTrailing)
            context.draw(Text("\(i + 1)").font(font).foregroundStyle(Color.textSecondary.opacity(0.75)),
                         at: CGPoint(x: left.minX + inset, y: left.maxY - inset), anchor: .bottomLeading)
        }
    }

    /// Each firing laser's four diagonals, up to the edge or the diffuser / laser that stops them.
    private func drawBeams(in context: inout GraphicsContext, layout: BoardLayout) {
        guard !board.activeLasers.isEmpty else { return }
        let n = board.size, cs = layout.cellSize
        var beams = Path()
        for laser in board.activeLasers {
            for (dr, dc) in Board.diagonals {
                var r = laser / n, c = laser % n
                beams.move(to: layout.center(of: laser))
                while true {
                    r += dr
                    c += dc
                    guard board.contains(r, c) else {
                        let last = layout.center(row: r - dr, col: c - dc)
                        beams.addLine(to: CGPoint(x: last.x + CGFloat(dc) * cs / 2, y: last.y + CGFloat(dr) * cs / 2))
                        break
                    }
                    beams.addLine(to: layout.center(row: r, col: c))
                    if let piece = board.grid[r * n + c], piece.kind == .lens || piece.kind == .laser { break }
                }
            }
        }
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .gridRed, radius: 3))
            layer.stroke(beams, with: .color(.gridRed.opacity(0.9)), style: StrokeStyle(lineWidth: max(1.5, cs * 0.06), lineCap: .round))
        }
    }

    private func drawPiece(_ piece: Piece, at p: CGPoint, cellSize cs: CGFloat, in context: inout GraphicsContext) {
        let s = cs * 0.32
        if piece.kind == .source {
            let color = Color.seat(piece.owner)
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: color, radius: 5))
                layer.fill(Path(ellipseIn: CGRect(x: p.x - s * 0.9, y: p.y - s * 0.9, width: s * 1.8, height: s * 1.8)), with: .color(color))
            }
            context.stroke(Path(ellipseIn: CGRect(x: p.x - s * 0.42, y: p.y - s * 0.42, width: s * 0.84, height: s * 0.84)),
                           with: .color(.gridUIBackground.opacity(0.9)), lineWidth: 2)
            return
        }
        if piece.kind == .chamber {
            context.fill(Self.glyph(.chamber, nil, at: p, size: s), with: .color(.textPrimary.opacity(0.10)))
        }
        let ink: Color = piece.kind == .laser ? Self.laserInk : piece.kind == .lens ? Self.diffuserInk : .textPrimary
        let width = piece.kind == .lens ? max(2, cs * 0.075) : max(1.6, cs * 0.055)
        context.stroke(Self.glyph(piece.kind, piece.orientation, at: p, size: s), with: .color(ink),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    /// A removed piece: its outline dashed, crossed out.
    private func drawGhost(_ piece: Piece, at p: CGPoint, cellSize cs: CGFloat, in context: inout GraphicsContext) {
        let s = cs * 0.30
        let outline = piece.kind == .source
            ? Path(ellipseIn: CGRect(x: p.x - s, y: p.y - s, width: s * 2, height: s * 2))
            : Self.glyph(piece.kind, piece.orientation, at: p, size: s)
        context.stroke(outline, with: .color(Self.laserInk.opacity(0.5)), style: StrokeStyle(lineWidth: 1.6, dash: [3, 3]))
        var cross = Path()
        cross.move(to: CGPoint(x: p.x - s * 0.7, y: p.y - s * 0.7))
        cross.addLine(to: CGPoint(x: p.x + s * 0.7, y: p.y + s * 0.7))
        cross.move(to: CGPoint(x: p.x + s * 0.7, y: p.y - s * 0.7))
        cross.addLine(to: CGPoint(x: p.x - s * 0.7, y: p.y + s * 0.7))
        context.stroke(cross, with: .color(Self.laserInk.opacity(0.55)), lineWidth: 1.4)
    }

    /// The strokable outline of a piece, centered on `p` within ±`s`. The diffuser is the same
    /// figure as `DiffuserShape` (two arms and the beam's tail), turned to face its outputs.
    private static func glyph(_ kind: PieceKind, _ orientation: Orientation?, at p: CGPoint, size s: CGFloat) -> Path {
        var path = Path()
        switch kind {
        case .mirror:
            if orientation == .slash {
                path.move(to: CGPoint(x: p.x + s, y: p.y - s))
                path.addLine(to: CGPoint(x: p.x - s, y: p.y + s))
            } else {
                path.move(to: CGPoint(x: p.x - s, y: p.y - s))
                path.addLine(to: CGPoint(x: p.x + s, y: p.y + s))
            }
        case .prism:
            path.addLines([CGPoint(x: p.x, y: p.y - s), CGPoint(x: p.x + s, y: p.y + s), CGPoint(x: p.x - s, y: p.y + s)])
            path.closeSubpath()
        case .chamber, .source:
            path.addRoundedRect(in: CGRect(x: p.x - s, y: p.y - s, width: s * 2, height: s * 2),
                                cornerSize: CGSize(width: s * 0.28, height: s * 0.28))
        case .laser:
            path.addLines([CGPoint(x: p.x, y: p.y - s), CGPoint(x: p.x + s, y: p.y), CGPoint(x: p.x, y: p.y + s), CGPoint(x: p.x - s, y: p.y)])
            path.closeSubpath()
            let x = s * 0.45
            path.move(to: CGPoint(x: p.x - x, y: p.y - x))
            path.addLine(to: CGPoint(x: p.x + x, y: p.y + x))
            path.move(to: CGPoint(x: p.x + x, y: p.y - x))
            path.addLine(to: CGPoint(x: p.x - x, y: p.y + x))
        case .lens:
            // Drawn facing NE (arms up and right, tail from the SW), then turned clockwise.
            path.move(to: CGPoint(x: 0, y: -s))
            path.addLine(to: .zero)
            path.addLine(to: CGPoint(x: s, y: 0))
            path.move(to: CGPoint(x: -s, y: s))
            path.addLine(to: .zero)
            let quarterTurns: CGFloat = switch orientation {
            case .se: 1
            case .sw: 2
            case .nw: 3
            default: 0
            }
            path = path.applying(CGAffineTransform(rotationAngle: quarterTurns * .pi / 2)
                .concatenating(CGAffineTransform(translationX: p.x, y: p.y)))
        }
        return path
    }
}

extension BoardView where Header == EmptyView {
    init(model: Model, bottomOverlap: CGFloat = 0) {
        self.init(model: model, bottomOverlap: bottomOverlap) { EmptyView() }
    }
}

#Preview {
    BoardView(model: PhotonGame())
}
