//
//  Tutorial.swift
//  Photon
//
//  The interactive tutorial: one idea per step, each on a small scripted board that asks for a
//  move. Moves are played by the real engine, and only one that does what the step asks is
//  kept; anything else gets a hint instead.
//

import Foundation

@Observable
final class Tutorial: BoardModel {
    /// Set once the player reaches the end, after which the app stops offering the tutorial.
    static let completedKey = "hasCompletedTutorial"
    /// Set when the player turns the tutorial down, after which the app stops offering it too.
    static let declinedKey = "hasDeclinedTutorial"

    struct Goal {
        /// Squares ringed on the board.
        var rings: [Int]
        /// The piece-selector button to point at, when the step wants a particular piece.
        var button: Int?
        /// What to try instead, after a move that doesn't do it.
        var hint: String
        /// Whether a move does what the step asks, judged on the board after it.
        var isMet: (Move, Board) -> Bool
    }

    struct Step {
        var title: String
        var text: String
        /// A fresh position to start from; nil carries on from the step before.
        var position: [GameAction]? = nil
        /// The move the step asks for; without one, the step is only read.
        var goal: Goal? = nil
        /// Said once the goal is met.
        var done = ""
    }

    let steps = Tutorial.script
    private(set) var index = 0
    private(set) var board: Board
    var selectedPiece = 0 {
        didSet { hint = nil }
    }
    /// Whether the step's move has been made (always, for a step that's only read).
    private(set) var isDone = false
    /// Why the last tap didn't count.
    private(set) var hint: String?
    /// Bumped on every tap that doesn't count, and on every goal met, for feedback.
    private(set) var misses = 0
    private(set) var hits = 0
    private(set) var ghosts: [Removal] = []
    private(set) var lastMove: Int?
    /// The board each step so far started from, so going back can restore it.
    @ObservationIgnored private var starts: [Board] = []

    init() {
        board = PhotonGame.emptyBoard(size: Self.size, checkMode: true)
        begin(0)
    }

    var step: Step { steps[index] }
    var isLastStep: Bool { index == steps.count - 1 }

    /// Whether going on to the next step replaces the board rather than building on it.
    var nextStepHasNewBoard: Bool { !isLastStep && steps[index + 1].position != nil }

    /// The selector button to point at: the piece the step wants, until the step is done.
    var pointedButton: Int? { isDone ? nil : step.goal?.button }

    // MARK: Board

    var activeSeat: Player { 0 }

    /// Until there's a source on the board, a tap places one, as in setup.
    var placesSource: Bool { board.sources[0].isEmpty }

    var playableCells: Set<Int> {
        guard step.goal != nil, !isDone else { return [] }
        if placesSource { return Set(board.setupCells()) }
        if let item = PhotonGame.palette[selectedPiece], item.kind == .lens {
            return PhotonGame.diffuserTargets(on: board, for: 0, item.orientation)
        }
        return Set(board.reach(0))
    }

    var ringedCells: Set<Int> { isDone ? [] : Set(step.goal?.rings ?? []) }

    func tap(_ cell: Int) {
        guard let goal = step.goal, !isDone else { return }
        if placesSource {
            guard board.setupCells().contains(cell), goal.isMet(Move(cell: cell, kind: .source), board) else {
                return miss(goal.hint)
            }
            board.addSource(at: cell, owner: 0)
            board.resolve()
            return made(at: cell, removing: [])
        }
        guard let item = PhotonGame.palette[selectedPiece] else { return miss("Pick a piece below first.") }
        guard playableCells.contains(cell) else {
            return miss(item.kind == .lens
                        ? "A diffuser only fits where your light crosses a laser beam running along its tail."
                        : "You can only build on a dotted square.")
        }
        let move = Move(cell: cell, kind: item.kind, orientation: item.orientation)
        var after = board
        let result = after.apply(move, by: 0)
        guard goal.isMet(move, after) else { return miss(goal.hint) }
        board = after
        made(at: cell, removing: result.removed)
    }

    private func made(at cell: Int, removing removed: [Removal]) {
        lastMove = cell
        ghosts = removed
        hint = nil
        isDone = true
        hits += 1
    }

    private func miss(_ why: String) {
        hint = why
        misses += 1
    }

    // MARK: Steps

    func advance() {
        guard isDone, !isLastStep else { return }
        begin(index + 1)
    }

    func goBack() {
        guard index > 0 else { return }
        starts.removeLast()
        index -= 1
        board = starts[index]
        reset()
    }

    private func begin(_ step: Int) {
        index = step
        if let position = steps[step].position { board = Self.setUp(position) }
        starts.append(board)
        reset()
    }

    private func reset() {
        isDone = step.goal == nil
        hint = nil
        ghosts = []
        lastMove = nil
        selectedPiece = 0
    }

    // MARK: Script

    private static let size = 9

    /// A square by the name the board labels it with, like "E5".
    private static func square(_ name: String) -> Int {
        let column = Int(name.first!.asciiValue!) - 65
        let row = Int(name.dropFirst())! - 1
        return row * size + column
    }

    private static func source(_ name: String, _ seat: Player) -> GameAction {
        .source(cell: square(name), seat: seat)
    }

    private static func piece(_ kind: PieceKind, _ orientation: Orientation? = nil, on name: String, by seat: Player) -> GameAction {
        .move(Move(cell: square(name), kind: kind, orientation: orientation), mover: seat)
    }

    /// The piece-selector button for a piece.
    private static func button(_ kind: PieceKind, _ orientation: Orientation? = nil) -> Int? {
        PhotonGame.palette.first { $0.value.kind == kind && $0.value.orientation == orientation }?.key
    }

    /// A goal of exactly this move, pointing at its square and its button.
    private static func place(_ kind: PieceKind, _ orientation: Orientation? = nil, on name: String, hint: String) -> Goal {
        let move = Move(cell: square(name), kind: kind, orientation: orientation)
        return Goal(rings: [move.cell], button: button(kind, orientation), hint: hint) { made, _ in made == move }
    }

    /// Plays a position out from an empty board.
    private static func setUp(_ position: [GameAction]) -> Board {
        var board = PhotonGame.emptyBoard(size: size, checkMode: true)
        for action in position {
            switch action {
            case let .source(cell, seat):
                board.addSource(at: cell, owner: seat)
                board.resolve()
            case let .move(move, mover):
                board.apply(move, by: mover)
            }
        }
        return board
    }

    // Each position was checked against the engine: the move asked for does what the step says,
    // and no other move does it in a way the text would get wrong.
    private static let script: [Step] = [
        Step(title: "Your Source",
             text: "Photon is a game of light: you play cyan, your opponent amber. Each of you starts by placing a source. Tap the ring to place yours.",
             position: [],
             goal: Goal(rings: [square("E5")], hint: "Tap the ringed square to place your source there.") { move, _ in
                 move.cell == square("E5")
             },
             done: "Your source shines light in four straight lines until it meets a piece or the edge. The darker squares around it are its moat, where no one can build."),
        Step(title: "Mirrors",
             text: "Each turn, you place one piece on a dotted square: anywhere your light reaches, except right beside the piece it shines from. Place the ╱ mirror on the ring.",
             goal: place(.mirror, .slash, on: "E2", hint: "Pick the ╱ mirror below, then tap the ring."),
             done: "Mirrors turn light 90°. Your light now runs east along row 2, and you can build along it."),
        Step(title: "Prisms",
             text: "A prism splits light three ways: straight on, left and right. Pick the prism and place it on the ring.",
             goal: place(.prism, on: "H2", hint: "Pick the prism below, then tap the ring."),
             done: "Light from a prism fades after four squares. See how it stops short of the bottom edge?"),
        Step(title: "Feeding",
             text: "A piece lives only while someone’s light runs into one of its faces. Amber’s light feeds the mirror on B2: place any piece on the ring to cut it off.",
             position: [source("C7", 0), source("G2", 1), piece(.mirror, .slash, on: "B2", by: 1)],
             goal: Goal(rings: [square("C2")], hint: "Place any piece on the ring, where your light crosses amber’s.") { _, board in
                 board.grid[square("B2")] == nil
             },
             done: "Starved of light, the mirror was removed; its ghost marks where it stood. Cutting off light is one way to clear a piece."),
        Step(title: "Chambers",
             text: "A chamber lit on three faces by your light becomes your source. Three lines of your light meet at the ring — place a chamber there.",
             position: [source("E8", 0), piece(.mirror, .backslash, on: "B8", by: 0), piece(.mirror, .slash, on: "B4", by: 0),
                        piece(.mirror, .slash, on: "H8", by: 0), piece(.mirror, .backslash, on: "H4", by: 0)],
             goal: Goal(rings: [square("E4")], button: button(.chamber),
                        hint: "Pick the chamber below, then tap the ring, where three lines of your light meet.") { _, board in
                 board.sources[0].count > 1
             },
             done: "The chamber became a second source for you. A new source also clears away the pieces around it."),
        Step(title: "Lasers",
             text: "A laser fed by light fires beams along its four diagonals, through other pieces. Two crossing beams make a cavity: place a laser on the ring to trap the mirror on C2.",
             position: [source("D7", 0), source("G2", 1), piece(.mirror, .slash, on: "C2", by: 1),
                        piece(.mirror, .backslash, on: "B7", by: 0), piece(.laser, on: "D3", by: 0)],
             goal: Goal(rings: [square("B3")], button: button(.laser), hint: "Pick the laser below, then tap the ring.") { _, board in
                 board.grid[square("C2")] == nil
             },
             done: "Caught in the cavity, the mirror was destroyed. Only lasers and diffusers are safe where beams cross."),
        Step(title: "Diffusers",
             text: "A diffuser fits where your light crosses a laser beam, tail along the beam. It stops the beam and sends your light out of its arms. Put the highlighted one on the ring.",
             position: [source("G7", 0), source("B2", 1), piece(.laser, on: "E2", by: 1)],
             goal: place(.lens, .nw, on: "G4", hint: "Pick the diffuser whose arms point north and west, then tap the ring."),
             done: "The beam now stops at your diffuser, and your light runs north and west out of it. A diffuser needs a beam striking it and light feeding it."),
        Step(title: "Check",
             text: "Amber’s beams cross on your source: it’s in check. Break the cavity this turn or lose the source — block a beam with a diffuser, or cut off a laser’s light.",
             position: [source("E7", 0), source("E2", 1), piece(.mirror, .backslash, on: "C7", by: 0),
                        piece(.mirror, .slash, on: "B2", by: 1), piece(.mirror, .backslash, on: "H2", by: 1),
                        piece(.laser, on: "B4", by: 1), piece(.laser, on: "H4", by: 1)],
             goal: Goal(rings: [square("C5"), square("C2")], button: button(.lens, .nw),
                        hint: "Put a diffuser on C5 to block the beam, or any piece on C2 to starve the laser on B4.") { _, board in
                 board.sources[0].contains(square("E7")) && !board.killzone[square("E7")]
             },
             done: "Your source is safe. A source left in a cavity is destroyed, and a player who can’t break a check at all loses the game."),
        Step(title: "You’re Ready",
             text: "You win when your opponent has no source left, can’t break a check, or has nowhere to build. With Check off in the menu, trapped sources die at once."),
    ]
}
