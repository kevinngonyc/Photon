//
//  PhotonGame.swift
//  Photon
//
//  Game flow, ported from the web version's UI layer: setup (placing sources), turns, the
//  bot's replies, online play, end-of-game checks, undo/redo, and the move log.
//

import GameKit
import SwiftUI

private nonisolated struct BotReply: Sendable {
    let move: Move
    let board: Board
    let result: MoveResult
    let outcome: GameOutcome?
}

@Observable
final class PhotonGame: BoardModel {
    enum Mode: String, CaseIterable, Identifiable {
        case bot, twoPlayer
        /// Against another device over Game Center; see `OnlineMatch`.
        case online

        var id: Self { self }
    }

    enum Phase {
        case setup, play
    }

    /// Which side the player takes. Cyan places and moves first.
    enum ColorChoice: String, CaseIterable, Identifiable {
        case cyan, amber, random

        var id: Self { self }

        /// The seat this choice gives, drawn afresh each time for random.
        func pickSeat() -> Player {
            switch self {
            case .cyan: 0
            case .amber: 1
            case .random: Bool.random() ? 0 : 1
            }
        }
    }

    struct PaletteItem {
        let kind: PieceKind
        let orientation: Orientation?
    }

    struct LogEntry: Identifiable {
        let id: Int
        let side: Player
        let text: String
        let isSetup: Bool
    }

    /// The pieces behind PieceSelectorView's buttons 1–9 (0 means nothing is selected), in
    /// the order the buttons draw them.
    static let palette: [Int: PaletteItem] = [
        1: PaletteItem(kind: .mirror, orientation: .backslash),
        2: PaletteItem(kind: .mirror, orientation: .slash),
        3: PaletteItem(kind: .prism, orientation: nil),
        4: PaletteItem(kind: .chamber, orientation: nil),
        5: PaletteItem(kind: .laser, orientation: nil),
        6: PaletteItem(kind: .lens, orientation: .ne),
        7: PaletteItem(kind: .lens, orientation: .sw),
        8: PaletteItem(kind: .lens, orientation: .se),
        9: PaletteItem(kind: .lens, orientation: .nw),
    ]

    // MARK: Settings — changing any of them except the difficulty starts a new game.

    var mode: Mode = .bot {
        didSet { if mode != oldValue && !isSyncing { newGame() } }
    }
    var boardSize = 15 {
        didSet { if boardSize != oldValue && !isSyncing { newGame() } }
    }
    var sourcesPerPlayer = 1 {
        didSet { if sourcesPerPlayer != oldValue && !isSyncing { newGame() } }
    }
    var checkMode = true {
        didSet { if checkMode != oldValue && !isSyncing { newGame() } }
    }
    var difficulty: Difficulty = .balanced
    /// The side the player takes against the bot, and in online games they host (including
    /// rematches). Joining someone else's game, they get whichever side is left. A random
    /// pick is drawn again for each new game.
    var colorChoice: ColorChoice = .cyan {
        didSet { if colorChoice != oldValue && mode == .bot { newGame() } }
    }

    var rules: GameRules {
        GameRules(boardSize: boardSize, sourcesPerPlayer: sourcesPerPlayer, checkMode: checkMode)
    }

    /// Set while the settings are changed to match the opponent's, so that doesn't count as
    /// starting a new game.
    @ObservationIgnored private var isSyncing = false

    // MARK: State

    var selectedPiece = 0
    private(set) var board = Board()
    private(set) var phase = Phase.setup
    private(set) var turn: Player = 0
    /// The human's seat against the bot, fixed when the game starts.
    private(set) var humanSeat: Player = 0
    /// Set once the game is over.
    private(set) var outcome: GameOutcome?
    private(set) var isThinking = false
    private(set) var lastMove: Int?
    /// What the last move removed, drawn as ghosts.
    private(set) var ghosts: [Removal] = []
    private(set) var log: [LogEntry] = []
    /// Feedback about the last action.
    private(set) var message = ""
    /// Bumped on an illegal tap, for the views to flash.
    private(set) var flashCount = 0
    /// Every source and move so far, in order: what an online turn stores.
    private(set) var actions: [GameAction] = []

    let online = OnlineMatch()

    private struct Snapshot {
        var board: Board
        var phase: Phase
        var turn: Player
        var outcome: GameOutcome?
        var lastMove: Int?
        var ghosts: [Removal]
        var log: [LogEntry]
        var actions: [GameAction]
    }

    private var history: [Snapshot] = []
    private var cursor = -1
    @ObservationIgnored private var botTask: Task<Void, Never>?

    init() {
        resetBoard()
        online.onLoad = { [weak self] data, isNewMatch in self?.matchLoaded(data, isNewMatch: isNewMatch) }
        online.onStart = { [unowned self] in (rules, colorChoice.pickSeat()) }
    }

    /// Starts over with the current settings. Online, a game's rules are fixed when it starts,
    /// so a new game is a rematch once the match is over.
    func newGame() {
        guard mode != .online else {
            if online.isOver { online.rematch() }
            return
        }
        resetBoard()
    }

    /// An empty board under the rules the app plays by (the tutorial's too).
    static func emptyBoard(size: Int, checkMode: Bool) -> Board {
        var board = Board(size: size, fedSurvival: true, lensPrivate: true, lifeOwnerRequired: false, checkMode: checkMode)
        board.resolve()
        return board
    }

    private func resetBoard() {
        botTask?.cancel()
        board = Self.emptyBoard(size: boardSize, checkMode: checkMode)
        phase = .setup
        turn = 0
        outcome = nil
        isThinking = false
        lastMove = nil
        ghosts = []
        log = []
        actions = []
        history = []
        cursor = -1
        humanSeat = colorChoice.pickSeat()
        // Playing first, the bot's opening source is part of the starting position.
        if mode == .bot { placeBotSources() }
        message = setupPrompt(setupSeat ?? 0)
        pushState()
    }

    // MARK: Derived state

    var selectedItem: PaletteItem? { Self.palette[selectedPiece] }

    /// Whose source goes down next during setup (the side with fewer), or nil once all are set.
    var setupSeat: Player? {
        let placed0 = board.sources[0].count, placed1 = board.sources[1].count
        if placed0 >= sourcesPerPlayer && placed1 >= sourcesPerPlayer { return nil }
        return placed0 <= placed1 ? 0 : 1
    }

    /// The bot's seat, when playing against it.
    var botSeat: Player { 1 - humanSeat }

    /// The seat whose action the board is waiting for.
    var activeSeat: Player { phase == .setup ? setupSeat ?? 0 : turn }

    /// Whether the person holding the device may act now (always, with two players).
    var isLocalTurn: Bool {
        guard outcome == nil, !isThinking else { return false }
        switch mode {
        case .bot: return activeSeat == humanSeat
        case .twoPlayer: return true
        case .online: return online.isMyTurn && !online.isOver && !isReviewing && activeSeat == online.localSeat
        }
    }

    /// The seat of the person holding the device (the first, with two players).
    var viewerSeat: Player {
        switch mode {
        case .bot: humanSeat
        case .twoPlayer: 0
        case .online: online.localSeat
        }
    }

    /// Online, undo and redo only step back through the game to look at it: nothing is sent,
    /// and play resumes from the latest position.
    var isReviewing: Bool { mode == .online && cursor < history.count - 1 }

    /// Squares the active seat may tap: setup squares, or where the selected piece may go.
    var legalCells: Set<Int> {
        switch phase {
        case .setup:
            return Set(board.setupCells())
        case .play:
            if let item = selectedItem, item.kind == .lens { return Self.diffuserTargets(on: board, for: turn, item.orientation) }
            return Set(board.reach(turn))
        }
    }

    var playableCells: Set<Int> { isLocalTurn ? legalCells : [] }

    /// A diffuser drops only where the player's light crosses a laser diagonal it matches:
    /// NE/SW on ╱ beams, NW/SE on ╲ beams. Cavity squares are allowed.
    static func diffuserTargets(on board: Board, for player: Player, _ orientation: Orientation?) -> Set<Int> {
        let axis: LaserAxes = orientation == .ne || orientation == .sw ? .slash : .backslash
        return Set(board.reach(player, includeKillzone: true).filter { board.laserAxis[$0].contains(axis) })
    }

    var status: (text: String, seat: Player) {
        if isReviewing { return ("Reviewing move \(cursor) of \(history.count - 1) — redo to return", activeSeat) }
        if let outcome { return (resultText(outcome), outcome.winner) }
        if mode == .online {
            if let seat = online.forfeitedSeat {
                return (isYou(seat) ? "You resigned" : "\(name(seat)) resigned — you win", 1 - seat)
            }
            if online.isSending { return ("Sending your move…", online.localSeat) }
            if online.opponentName == nil && !online.isMyTurn {
                return ("Waiting for an opponent to join…", 1 - online.localSeat)
            }
        }
        switch phase {
        case .setup:
            let seat = activeSeat
            let tag = sourcesPerPlayer > 1 ? " (\(board.sources[seat].count + 1) of \(sourcesPerPlayer))" : ""
            let text = switch mode {
            case .twoPlayer: "Player \(seat + 1): place source\(tag)"
            case .online where !isYou(seat): "Waiting for \(opponentName)’s source…"
            case .bot, .online: "Place your source\(tag)"
            }
            return (text, seat)
        case .play:
            if isThinking { return ("\(name(turn)) is thinking…", turn) }
            return (mode == .online && isYou(turn) ? "Your move" : "\(name(turn)) to move", turn)
        }
    }

    /// Shown while the side to move has a source in a cavity (check mode).
    var checkWarning: String? {
        guard outcome == nil, phase == .play, !isThinking, PhotonBot.sourcesInCheck(board, turn) > 0 else { return nil }
        let whose = isYou(turn) ? "Your" : "\(name(turn))’s"
        return "\(whose) source is in check — save it this turn!"
    }

    var counts: String {
        func side(_ p: Player) -> String { "\(label(p)) · reach \(board.reach(p).count) · src \(board.sources[p].count)" }
        return "\(side(0))  /  \(side(1))"
    }

    /// Whether `player` is the person holding the device (never, with two players).
    private func isYou(_ player: Player) -> Bool {
        switch mode {
        case .bot: player == humanSeat
        case .twoPlayer: false
        case .online: player == online.localSeat
        }
    }

    func name(_ player: Player) -> String {
        switch mode {
        case .bot: isYou(player) ? "You" : Self.botName(player)
        case .twoPlayer: "Player \(player + 1)"
        case .online: isYou(player) ? "You" : opponentName
        }
    }

    func label(_ player: Player) -> String {
        switch mode {
        case .bot: isYou(player) ? "you" : Self.botName(player).lowercased()
        case .twoPlayer: "P\(player + 1)"
        case .online: isYou(player) ? "you" : "opp"
        }
    }

    private var opponentName: String { online.opponentName ?? "Opponent" }

    /// The bot goes by its side's color: Cyan or Amber.
    private static func botName(_ seat: Player) -> String { seat == 0 ? "Cyan" : "Amber" }

    private func resultText(_ outcome: GameOutcome) -> String {
        let winner = outcome.winner, loser = 1 - winner
        let wins = isYou(winner) ? "win" : "wins"
        let loserName = isYou(loser) ? "you" : name(loser)
        let has = isYou(loser) ? "have" : "has"
        let reason = switch outcome {
        case .opponentHasNoSource: "\(loserName) \(has) no source."
        case .opponentCannotKeepSourceAlive: "\(loserName) can’t keep a source alive."
        case .opponentCannotPlace: "\(loserName) can’t place."
        }
        return "\(name(winner)) \(wins) — \(reason)"
    }

    private func setupPrompt(_ seat: Player) -> String {
        let progress = "(\(board.sources[seat].count + 1) of \(sourcesPerPlayer))"
        if mode == .online && !isYou(seat) { return "Waiting for \(opponentName)’s source…" }
        return mode == .twoPlayer ? "Player \(seat + 1): place source \(progress)" : "Place your Photon source \(progress)"
    }

    // MARK: Actions

    func tap(_ cell: Int) {
        if isReviewing {
            flash()
            message = "Reviewing an earlier position — redo to return to the game before moving."
            return
        }
        guard isLocalTurn else { return }
        guard phase == .play else { return placeSource(at: cell) }
        guard let item = selectedItem else {
            flash()
            message = "Pick a piece first."
            return
        }
        guard legalCells.contains(cell) else { return flash() }
        // A player is never forced to escape a check: if this move leaves the cavity, the
        // checked source just dies (and if it was their last, they lose).
        play(Move(cell: cell, kind: item.kind, orientation: item.orientation), by: turn)
        submitTurn()
    }

    private func placeSource(at cell: Int) {
        guard legalCells.contains(cell) else { return flash() }
        guard let seat = setupSeat else { return }
        placeSetupSource(at: cell, seat: seat)
        submitTurn()
    }

    private func placeSetupSource(at cell: Int, seat: Player) {
        addSource(at: cell, seat: seat)
        if mode == .bot { placeBotSources() }
        if let next = setupSeat {
            message = setupPrompt(next)
        } else {
            phase = .play
            turn = 0
            message = "Sources set. \(name(0)) to move."
        }
        pushState()
        if phase == .play && mode == .bot && turn == botSeat { startBotTurn() }
    }

    /// The bot's setup sources, for as long as setup is waiting on it.
    private func placeBotSources() {
        while setupSeat == botSeat, let reply = PhotonBot.setupSource(on: board, player: botSeat) {
            addSource(at: reply, seat: botSeat)
        }
    }

    private func addSource(at cell: Int, seat: Player) {
        board.addSource(at: cell, owner: seat)
        board.resolve()
        actions.append(.source(cell: cell, seat: seat))
        appendLog(side: seat, text: "source \(board.coordinate(cell))", isSetup: true)
        lastMove = cell
    }

    private func play(_ move: Move, by mover: Player) {
        let result = board.apply(move, by: mover)
        record(move, by: mover, removed: result.removed)
        message = summary(of: result, at: move.cell)
        turn = 1 - mover
        outcome = PhotonBot.outcome(after: mover, on: board)
        pushState()
        if outcome == nil && mode == .bot && turn == botSeat { startBotTurn() }
    }

    /// The bot's reply, worked out (and played out) off the main actor.
    private func startBotTurn() {
        isThinking = true
        let board = board, difficulty = difficulty, bot = botSeat
        botTask = Task {
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            let reply = await Task.detached(priority: .userInitiated) { () -> BotReply? in
                guard let move = PhotonBot.botMove(board, player: bot, difficulty: difficulty) else { return nil }
                var after = board
                let result = after.apply(move, by: bot)
                return BotReply(move: move, board: after, result: result, outcome: PhotonBot.outcome(after: bot, on: after))
            }.value
            guard !Task.isCancelled else { return }
            isThinking = false
            guard let reply else {
                outcome = .opponentCannotPlace(winner: 1 - bot)
                history[cursor].outcome = outcome
                return
            }
            self.board = reply.board
            record(reply.move, by: bot, removed: reply.result.removed)
            turn = 1 - bot
            outcome = reply.outcome
            pushState()
        }
    }

    private func record(_ move: Move, by side: Player, removed: [Removal]) {
        let glyph = switch move.kind {
        case .mirror: move.orientation == .slash ? "╱" : "╲"
        case .prism: "△"
        case .chamber: "▣"
        case .laser: "◆"
        case .lens: move.orientation.flatMap { [Orientation.ne: "⌞", .nw: "⌟", .se: "⌜", .sw: "⌝"][$0] } ?? "◇"
        case .source: "●"
        }
        let name = switch move.kind {
        case .source: "src"
        case .mirror: "mirror"
        case .prism: "prism"
        case .chamber: "chamber"
        case .laser: "laser"
        case .lens: "diffuser"
        }
        actions.append(.move(move, mover: side))
        appendLog(side: side, text: "\(glyph) \(name) \(board.coordinate(move.cell))", isSetup: false)
        lastMove = move.cell
        ghosts = removed
    }

    private func appendLog(side: Player, text: String, isSetup: Bool) {
        log.append(LogEntry(id: log.count, side: side, text: text, isSetup: isSetup))
    }

    private func summary(of result: MoveResult, at cell: Int) -> String {
        if result.removed.contains(where: { $0.piece.kind == .source && $0.cause == .cavity }) {
            return "A source trapped in a laser cavity was destroyed."
        }
        // A chamber that converts the moment it lands doesn't "survive" in engine terms, but
        // it wasn't starved either.
        let convertedInPlace = board.grid[cell]?.kind == .source
        if !result.survived && !convertedInPlace { return "That piece had no light entering a face and was removed." }
        if result.privGained > 0 { return "Conversion — a chamber became your source." }
        if result.oppGained > 0 { return "Conversion — that chamber sat in 3 of your opponent’s beams; it became THEIR source." }
        if !result.removed.isEmpty { return "\(result.removed.count) piece(s) removed (see ghosts)." }
        return ""
    }

    private func flash() {
        flashCount += 1
    }

    // MARK: Undo / redo

    var canUndo: Bool { !isThinking && undoTarget != nil }
    var canRedo: Bool { !isThinking && redoTarget != nil }

    func undo() {
        guard canUndo, let target = undoTarget else { return }
        restore(target)
        message = "Undo."
    }

    func redo() {
        guard canRedo, let target = redoTarget else { return }
        restore(target)
        message = "Redo."
    }

    /// Against the bot, history steps over positions where the bot is to move: nothing would
    /// trigger its reply from there, so they'd be dead ends.
    private func isStoppingPoint(_ snapshot: Snapshot) -> Bool {
        mode != .bot || snapshot.phase == .setup || snapshot.turn == humanSeat || snapshot.outcome != nil
    }

    private var undoTarget: Int? {
        stride(from: cursor - 1, through: 0, by: -1).first { isStoppingPoint(history[$0]) }
    }

    private var redoTarget: Int? {
        (cursor + 1..<history.count).first { isStoppingPoint(history[$0]) }
    }

    private func pushState() {
        history.removeSubrange((cursor + 1)...)
        history.append(Snapshot(board: board, phase: phase, turn: turn, outcome: outcome,
                                lastMove: lastMove, ghosts: ghosts, log: log, actions: actions))
        cursor = history.count - 1
    }

    private func restore(_ index: Int) {
        let snapshot = history[index]
        cursor = index
        board = snapshot.board
        phase = snapshot.phase
        turn = snapshot.turn
        outcome = snapshot.outcome
        lastMove = snapshot.lastMove
        ghosts = snapshot.ghosts
        log = snapshot.log
        actions = snapshot.actions
        isThinking = false
    }

    // MARK: Online

    /// Opens Game Center's list of online games, where new ones start too.
    func playOnline() {
        online.showGames()
    }

    /// Back to playing the bot. The online game carries on and can be reopened from the list.
    func leaveOnline() {
        online.close()
        mode = .bot
    }

    /// Shows the match Game Center has: a newly opened one, or the latest turn in this one.
    private func matchLoaded(_ data: MatchData?, isNewMatch: Bool) {
        if isNewMatch {
            selectedPiece = 0
            isSyncing = true
            mode = .online
            isSyncing = false
        }
        guard let data else {
            // Nobody has moved yet: the player starting it sets the rules.
            if isNewMatch { resetBoard() }
            return
        }
        if isNewMatch || data.rules != rules || data.actions != history.last?.actions {
            adopt(data.rules, data.actions)
        }
    }

    /// Hands the turn to the opponent, with a line for their notification.
    private func submitTurn() {
        guard mode == .online, let last = log.last else { return }
        let me = GKLocalPlayer.local.displayName
        let message = if let outcome {
            outcome.winner == online.localSeat ? "\(me) won the game." : "You won against \(me)!"
        } else if last.isSetup {
            "\(me) placed a source. Your turn."
        } else {
            "\(me) played \(last.text). Your turn."
        }
        online.submit(rules: rules, actions: actions, message: message, winner: outcome?.winner)
    }

    /// Replays the opponent's game from the start, one snapshot per action so the whole game
    /// can be reviewed. Every action is checked as if it had been played here; if any is
    /// illegal, the update is dropped and the game stays as it was.
    private func adopt(_ newRules: GameRules, _ newActions: [GameAction]) {
        let backup = (rules: rules, history: history, cursor: cursor)
        guard newRules.isValid else { return rejectUpdate() }
        applyRules(newRules)
        resetBoard()
        for action in newActions {
            if !replay(action) {
                applyRules(backup.rules)
                history = backup.history
                restore(backup.cursor)
                return rejectUpdate()
            }
        }
        message = isLocalTurn ? "Your move." : ""
    }

    private func replay(_ action: GameAction) -> Bool {
        switch action {
        case let .source(cell, seat):
            guard phase == .setup, seat == setupSeat, board.setupCells().contains(cell) else { return false }
            placeSetupSource(at: cell, seat: seat)
        case let .move(move, mover):
            guard isLegal(move, by: mover) else { return false }
            play(move, by: mover)
        }
        return true
    }

    private func isLegal(_ move: Move, by mover: Player) -> Bool {
        guard phase == .play, outcome == nil, mover == turn, PieceKind.placeable.contains(move.kind),
              PhotonBot.orientations(for: move.kind).contains(move.orientation) else { return false }
        let targets = move.kind == .lens ? Self.diffuserTargets(on: board, for: mover, move.orientation) : Set(board.reach(mover))
        return targets.contains(move.cell)
    }

    private func applyRules(_ newRules: GameRules) {
        isSyncing = true
        boardSize = newRules.boardSize
        sourcesPerPlayer = newRules.sourcesPerPlayer
        checkMode = newRules.checkMode
        isSyncing = false
    }

    private func rejectUpdate() {
        online.alert = "This game’s saved moves don’t follow the rules, so they weren’t loaded."
    }
}
