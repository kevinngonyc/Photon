//
//  PhotonBot.swift
//  Photon
//
//  The computer opponent and the check / end-of-game rules, ported from the web version
//  (projects/photon/index.html, "BOT"). Randomness comes from an injected generator; the
//  shuffle consumes it exactly like the JS one does, so a seeded run is reproducible.
//

import Foundation

nonisolated enum Difficulty: String, CaseIterable, Identifiable, Sendable {
    case random, balanced, sharp

    var id: Self { self }
}

/// Why a game ended, from the winner's point of view.
nonisolated enum GameOutcome: Sendable, Hashable {
    case opponentHasNoSource(winner: Player)
    case opponentCannotKeepSourceAlive(winner: Player)
    case opponentCannotPlace(winner: Player)

    var winner: Player {
        switch self {
        case .opponentHasNoSource(let winner), .opponentCannotKeepSourceAlive(let winner),
             .opponentCannotPlace(let winner):
            winner
        }
    }
}

nonisolated enum PhotonBot {
    /// Shared work counter for the lookahead (the JS `{ n, max }` object).
    nonisolated struct Budget {
        var n = 0
        var max = Int.max
    }

    static func botMove<R: RandomNumberGenerator>(_ board: Board, player: Player, difficulty: Difficulty,
                                                  using rng: inout R) -> Move? {
        // The bot is never forced to escape a check: its evaluation already weighs keeping
        // sources alive, so it may let a doomed source go when it has others.
        switch difficulty {
        case .random: randomMove(board, player, using: &rng)
        case .balanced: greedyMove(board, player, sampleN: 24, lookahead: true, using: &rng)
        case .sharp: greedyMove(board, player, sampleN: 60, lookahead: true, using: &rng)
        }
    }

    static func botMove(_ board: Board, player: Player, difficulty: Difficulty) -> Move? {
        var rng = SystemRandomNumberGenerator()
        return botMove(board, player: player, difficulty: difficulty, using: &rng)
    }

    // MARK: - Move generation

    static func orientations(for kind: PieceKind) -> [Orientation?] {
        switch kind {
        case .mirror: [.slash, .backslash]
        case .lens: [.ne, .nw, .se, .sw]
        default: [nil]
        }
    }

    /// Every placement on `player`'s reach, plus diffusers on the cavity squares only they may
    /// use, shuffled. With `prioritizeDefense`, moves on a laser line come first (diffusers
    /// before other pieces). `cap` keeps only the first moves.
    static func candidateMoves<R: RandomNumberGenerator>(_ board: Board, _ player: Player, cap: Int?,
                                                         prioritizeDefense: Bool = false,
                                                         using rng: inout R) -> [Move] {
        let reach = board.reach(player)
        var shuffledReach = reach
        shuffle(&shuffledReach, using: &rng)
        var moves: [Move] = []
        for cell in shuffledReach {
            for kind in PieceKind.placeable {
                for orientation in orientations(for: kind) {
                    moves.append(Move(cell: cell, kind: kind, orientation: orientation))
                }
            }
        }
        let reachSet = Set(reach)
        for cell in board.reach(player, includeKillzone: true) where !reachSet.contains(cell) {
            for orientation in orientations(for: .lens) {
                moves.append(Move(cell: cell, kind: .lens, orientation: orientation))
            }
        }
        shuffle(&moves, using: &rng)
        if prioritizeDefense {
            func priority(_ move: Move) -> Int {
                let onLaser = !board.laserAxis[move.cell].isEmpty
                return move.kind == .lens ? (onLaser ? 3 : 0) : (onLaser ? 2 : 0)
            }
            // A stable sort, highest priority first.
            moves = moves.filter { priority($0) == 3 } + moves.filter { priority($0) == 2 } + moves.filter { priority($0) == 0 }
        }
        if let cap, cap < moves.count { moves.removeSubrange(cap...) }
        return moves
    }

    /// The first surviving move from a random sample.
    static func randomMove<R: RandomNumberGenerator>(_ board: Board, _ player: Player, using rng: inout R) -> Move? {
        for move in candidateMoves(board, player, cap: 160, using: &rng) {
            var next = board
            if next.apply(move, by: player).survived { return move }
        }
        return nil
    }

    /// Scores a sample of surviving moves on safety, conversions and reach, then (with
    /// `lookahead`) checks whether the best few let the opponent force a source loss.
    static func greedyMove<R: RandomNumberGenerator>(_ board: Board, _ player: Player, sampleN: Int = 24,
                                                     lookahead: Bool, using rng: inout R) -> Move? {
        let opp = 1 - player
        let baseOpp = board.reach(opp).count
        let inCheck = sourcesInCheck(board, player) > 0
        let threatened = inCheck || sourcesUnderLaser(board, player) > 0
        let poolCap: Int? = inCheck ? nil : (threatened ? sampleN * 6 : sampleN * 3)
        let survivorCap = inCheck ? 500 : (threatened ? sampleN * 3 : sampleN)

        var scored: [(move: Move, score: Int, underLaser: Bool)] = []
        var tried = 0
        for move in candidateMoves(board, player, cap: poolCap, prioritizeDefense: threatened, using: &rng) {
            var next = board
            let result = next.apply(move, by: player)
            if !result.survived { continue }
            tried += 1
            let myReach = next.reach(player).count, oppReach = next.reach(opp).count
            let oppDead = next.sources[opp].isEmpty || oppReach == 0 ? 1 : 0
            let score = 100_000 * oppDead + safetyScore(before: board, after: next, player)
                + 300 * result.privGained - 800 * result.oppGained
                + 2 * (baseOpp - oppReach) + myReach + 5 * result.removed.count
            scored.append((move, score, sourcesUnderLaser(next, player) > 0))
            if tried >= survivorCap { break }
        }
        if scored.isEmpty { return randomMove(board, player, using: &rng) }

        if lookahead {
            scored = scored.enumerated()
                .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
                .map(\.element)
            var work = Budget(max: 5000)
            for i in 0..<min(scored.count, 8) {
                if !scored[i].underLaser || work.n > work.max { continue }
                var next = board
                next.apply(scored[i].move, by: player)
                if oppForcesSourceLoss(next, player, work: &work, using: &rng) { scored[i].score -= 40_000 }
            }
        }
        var best = scored[0]
        for candidate in scored where candidate.score > best.score { best = candidate }
        return best.move
    }

    /// Where the bot puts a source during setup: the free square closest (Manhattan) to the
    /// point reflection of the human's matching source.
    static func setupSource(on board: Board) -> Int? {
        var candidates = board.setupCells()
        if candidates.isEmpty { candidates = board.grid.indices.filter { board.grid[$0] == nil } }
        guard let firstHuman = board.sources[0].first else { return candidates.first }
        let index = board.sources[1].count
        let from = index < board.sources[0].count ? board.sources[0][index] : firstHuman
        let n = board.size
        let targetRow = n - 1 - from / n, targetCol = n - 1 - from % n
        func distance(_ cell: Int) -> Int { abs(cell / n - targetRow) + abs(cell % n - targetCol) }
        return candidates.min { distance($0) < distance($1) }
    }

    // MARK: - Check and safety

    static func sourcesInCheck(_ board: Board, _ player: Player) -> Int {
        board.sources[player].count(where: { board.killzone[$0] })
    }

    /// Sources on exactly one beam: one more beam across them makes a cavity.
    static func sourcesUnderLaser(_ board: Board, _ player: Player) -> Int {
        board.sources[player].count(where: { board.laserCov[$0] == 1 })
    }

    static func safetyScore(before: Board, after: Board, _ player: Player) -> Int {
        let sourcesLost = before.sources[player].count - after.sources[player].count
        return -50_000 * sourcesLost - 8000 * sourcesInCheck(after, player) - 1500 * sourcesUnderLaser(after, player)
    }

    /// A player must act when one of their (or a shared) sources sits in a cavity, or when no
    /// source of theirs can shine.
    static func needsSave(_ board: Board, _ player: Player) -> Bool {
        if !board.sourceAlive(player) { return true }
        return board.sources[player].contains { board.killzone[$0] }
            || board.sources[Owners.sharedIndex].contains { board.killzone[$0] }
    }

    /// Whether `move` leaves `player` with a shining source and none of theirs in a cavity.
    static func isSafeMove(_ board: Board, _ player: Player, _ move: Move) -> Bool {
        var next = board
        next.apply(move, by: player)
        if !next.sourceAlive(player) { return false }
        return !next.sources[player].contains { next.killzone[$0] }
            && !next.sources[Owners.sharedIndex].contains { next.killzone[$0] }
    }

    /// Searches every legal move (defensive ones first), so "no safe move" is never a guess.
    static func hasSafeMove<R: RandomNumberGenerator>(_ board: Board, _ player: Player, using rng: inout R) -> Bool {
        candidateMoves(board, player, cap: nil, prioritizeDefense: true, using: &rng).contains {
            isSafeMove(board, player, $0)
        }
    }

    /// Judged at the start of `player`'s turn: they lose if they must act and cannot get safe.
    static func startOfTurnLoss<R: RandomNumberGenerator>(_ board: Board, _ player: Player, using rng: inout R) -> Bool {
        needsSave(board, player) && !hasSafeMove(board, player, using: &rng)
    }

    static func canPlay(_ board: Board, _ player: Player) -> Bool {
        !board.sources[player].isEmpty && !board.reach(player).isEmpty
    }

    /// The game's verdict after `mover` has moved, or nil if play goes on. A check costs a
    /// source, not the game: a player loses when their last source is gone or when, at the start
    /// of their turn, they cannot get safe or cannot place at all.
    static func outcome<R: RandomNumberGenerator>(after mover: Player, on board: Board,
                                                  using rng: inout R) -> GameOutcome? {
        let next = 1 - mover
        if board.sources[mover].isEmpty { return .opponentHasNoSource(winner: next) }
        if board.sources[next].isEmpty { return .opponentHasNoSource(winner: mover) }
        if startOfTurnLoss(board, next, using: &rng) { return .opponentCannotKeepSourceAlive(winner: mover) }
        if !needsSave(board, next) && !canPlay(board, next) { return .opponentCannotPlace(winner: mover) }
        return nil
    }

    static func outcome(after mover: Player, on board: Board) -> GameOutcome? {
        var rng = SystemRandomNumberGenerator()
        return outcome(after: mover, on: board, using: &rng)
    }

    // MARK: - Lookahead

    /// Every square on the four diagonals through `cell`.
    static func diagonalCells(_ board: Board, through cell: Int) -> [Int] {
        let r = cell / board.size, c = cell % board.size
        var out: [Int] = []
        for (dr, dc) in Board.diagonals {
            var rr = r + dr, cc = c + dc
            while board.contains(rr, cc) {
                out.append(board.index(rr, cc))
                rr += dr
                cc += dc
            }
        }
        return out
    }

    /// Whether `me` has a move (from a defensive sample) that keeps all their sources and gets
    /// them out of every cavity. Running out of budget counts as yes.
    static func canEscape<R: RandomNumberGenerator>(_ board: Board, _ me: Player, work: inout Budget,
                                                    using rng: inout R) -> Bool {
        for move in candidateMoves(board, me, cap: 80, prioritizeDefense: true, using: &rng) {
            work.n += 1
            if work.n > work.max { return true }
            var next = board
            if !next.apply(move, by: me).survived { continue }
            if next.sources[me].count < board.sources[me].count { continue }
            if !next.sources[me].contains(where: { next.killzone[$0] }) { return true }
        }
        return false
    }

    /// Whether the opponent can drop a laser that closes a cavity on one of `me`'s sources
    /// (each already on one beam) that `me` cannot then escape.
    static func oppForcesSourceLoss<R: RandomNumberGenerator>(_ board: Board, _ me: Player, work: inout Budget,
                                                              using rng: inout R) -> Bool {
        let opp = 1 - me
        let threatened = board.sources[me].filter { board.laserCov[$0] == 1 }
        if threatened.isEmpty { return false }
        let oppReach = Set(board.reach(opp))
        var candidates: [Int] = []
        var seen = Set<Int>()
        for source in threatened {
            for cell in diagonalCells(board, through: source) where oppReach.contains(cell) && seen.insert(cell).inserted {
                candidates.append(cell)
            }
        }
        var completions = 0
        for cell in candidates {
            if work.n > work.max { break }
            var next = board
            if !next.apply(Move(cell: cell, kind: .laser, orientation: nil), by: opp).survived { continue }
            if next.sources[me].count < board.sources[me].count { return true }
            if !next.sources[me].contains(where: { next.killzone[$0] }) { continue }
            completions += 1
            if completions > 8 { break }
            work.n += 1
            if !canEscape(next, me, work: &work, using: &rng) { return true }
        }
        return false
    }

    // MARK: - Randomness

    /// Fisher–Yates, drawing exactly like the JS `shuffle` (`(Math.random() * (i + 1)) | 0`).
    static func shuffle<T, R: RandomNumberGenerator>(_ array: inout [T], using rng: inout R) {
        var i = array.count - 1
        while i > 0 {
            let j = Int(Double(rng.next() >> 11) * 0x1p-53 * Double(i + 1))
            array.swapAt(i, j)
            i -= 1
        }
    }
}
