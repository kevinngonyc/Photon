//
//  PhotonEngine.swift
//  Photon
//
//  The rules engine, ported from the web version (projects/photon/index.html, "ENGINE").
//  Squares are addressed by index (row * size + col) and light owners are bitmasks, so the
//  propagation loops never hash. Everything here is nonisolated so the bot can search off
//  the main actor.
//

import Foundation

/// 0 is Photon (blue, moves first); 1 is Amber (orange).
typealias Player = Int

nonisolated enum PieceKind: Sendable, Hashable, CaseIterable, Codable {
    case source, mirror, prism, chamber, laser, lens

    /// What a player may place on their turn. Sources only come from setup or conversion.
    static let placeable: [PieceKind] = [.mirror, .prism, .chamber, .laser, .lens]
}

/// Mirror (`/`, `\`) and diffuser (lens) orientations.
nonisolated enum Orientation: String, Sendable, Hashable, Codable {
    case slash = "/", backslash = "\\", ne = "NE", nw = "NW", se = "SE", sw = "SW"
}

nonisolated struct Piece: Sendable, Hashable {
    var kind: PieceKind
    /// A player, or `Owners.sharedIndex` (the web engine's `'S'`).
    var owner: Int
    var orientation: Orientation?
}

/// A set of light owners: bit 0 is player 0, bit 1 player 1, bit 2 shared.
nonisolated struct Owners: OptionSet, Sendable, Hashable {
    let rawValue: UInt8

    /// Owner index for shared light and sources. The current rules never create any, but the
    /// hooks stay so the engine remains rule-compatible with the JS version.
    static let sharedIndex = 2
    static let shared = Owners(rawValue: 1 << 2)

    static func of(_ owner: Int) -> Owners { Owners(rawValue: 1 << UInt8(owner)) }

    /// True when `owner` may use this light: it is theirs or it is shared.
    func serves(_ owner: Int) -> Bool { !isDisjoint(with: Owners.of(owner).union(.shared)) }
}

/// The diagonals that laser beams run along.
nonisolated struct LaserAxes: OptionSet, Sendable, Hashable {
    let rawValue: UInt8
    /// ╱ — the NE/SW diagonal. NE and SW diffusers sit on these beams.
    static let slash = LaserAxes(rawValue: 1)
    /// ╲ — the NW/SE diagonal.
    static let backslash = LaserAxes(rawValue: 2)
}

nonisolated struct Move: Sendable, Hashable, Codable {
    var cell: Int
    var kind: PieceKind
    var orientation: Orientation?
}

nonisolated struct Removal: Sendable, Hashable {
    nonisolated enum Cause: Sendable, Hashable { case cavity, starved, lensNoLaser }

    var cell: Int
    var piece: Piece
    var cause: Cause
}

nonisolated struct MoveResult: Sendable {
    /// The placed piece is still on its square. As in the web version, a chamber that converts
    /// into a source on the spot does not count as surviving.
    var survived: Bool
    var removed: [Removal]
    /// Chambers converted into the mover's sources / the opponent's sources.
    var privGained: Int
    var oppGained: Int
}

nonisolated struct Board: Sendable {
    static let prismRange = 4
    /// N, S, E, W — the JS engine's ORTHO_LIST order, so `dir ^ 1` is the opposite direction.
    static let ortho: [(dr: Int, dc: Int)] = [(-1, 0), (1, 0), (0, 1), (0, -1)]
    static let diagonals: [(dr: Int, dc: Int)] = [(-1, 1), (-1, -1), (1, 1), (1, -1)]

    let size: Int
    let fedSurvival: Bool
    let lensPrivate: Bool
    let lifeOwnerRequired: Bool
    /// When on, a source caught in a cavity survives until the end of its owner's next turn.
    let checkMode: Bool

    /// Row-major; `nil` is an empty square.
    private(set) var grid: [Piece?]
    /// Source squares per owner in placement order: player 0, player 1, shared.
    private(set) var sources: [[Int]] = [[], [], []]

    // Light state, recomputed by `resolve()`.

    /// Empty squares crossed by light, and whose light it is.
    private(set) var lit: [Owners]
    /// Empty squares light enters across an empty gap — the squares pieces may be placed on.
    private(set) var emptyFed: [Owners]
    /// Four entries per square (N, S, E, W face): who feeds that face of the piece there.
    private(set) var fedFaces: [Owners]
    /// Squares crossed by two or more laser beams — a cavity.
    private(set) var killzone: [Bool]
    /// Diffusers struck by a laser beam.
    private(set) var lensHits: [Bool]
    /// Number of beams crossing each square.
    private(set) var laserCov: [UInt8]
    private(set) var laserAxis: [LaserAxes]
    /// Lasers that receive light (and so fire), ascending.
    private(set) var activeLasers: [Int] = []

    /// Squares in the order the JS engine walks chambers when converting: sorted by their
    /// "r,c" string key. Which chamber converts first can matter, so the order is kept.
    private let conversionOrder: [Int]

    init(size: Int = 13, fedSurvival: Bool = true, lensPrivate: Bool = false,
         lifeOwnerRequired: Bool = false, checkMode: Bool = false) {
        self.size = size
        self.fedSurvival = fedSurvival
        self.lensPrivate = lensPrivate
        self.lifeOwnerRequired = lifeOwnerRequired
        self.checkMode = checkMode
        let count = size * size
        grid = Array(repeating: nil, count: count)
        lit = Array(repeating: [], count: count)
        emptyFed = Array(repeating: [], count: count)
        fedFaces = Array(repeating: [], count: count * 4)
        killzone = Array(repeating: false, count: count)
        lensHits = Array(repeating: false, count: count)
        laserCov = Array(repeating: 0, count: count)
        laserAxis = Array(repeating: [], count: count)
        conversionOrder = (0..<count).sorted { "\($0 / size),\($0 % size)" < "\($1 / size),\($1 % size)" }
    }

    func index(_ row: Int, _ col: Int) -> Int { row * size + col }
    func contains(_ row: Int, _ col: Int) -> Bool { row >= 0 && row < size && col >= 0 && col < size }

    /// Board coordinate as the web version prints it: column letter, then 1-based row ("C5").
    func coordinate(_ cell: Int) -> String {
        String(Character(UnicodeScalar(UInt8(65 + cell % size)))) + String(cell / size + 1)
    }

    /// Places a source during setup. Call `resolve()` afterwards.
    mutating func addSource(at cell: Int, owner: Int) {
        grid[cell] = Piece(kind: .source, owner: owner, orientation: nil)
        sources[owner].append(cell)
    }

    /// The eight squares around every source, where nothing may be placed.
    func moat() -> [Bool] {
        var moat = [Bool](repeating: false, count: grid.count)
        for list in sources {
            for source in list {
                let r = source / size, c = source % size
                for dr in -1...1 {
                    for dc in -1...1 where (dr != 0 || dc != 0) && contains(r + dr, c + dc) {
                        moat[index(r + dr, c + dc)] = true
                    }
                }
            }
        }
        return moat
    }

    /// Squares open for a source during setup: empty and outside every moat.
    func setupCells() -> [Int] {
        let moat = moat()
        return grid.indices.filter { grid[$0] == nil && !moat[$0] }
    }

    // MARK: - Light

    private struct OrthoLight {
        var lit: [Owners]
        var emptyFed: [Owners]
        var fedFaces: [Owners]
        var laserFed: [Bool]
    }

    private struct LensRay: Equatable {
        var cell: Int
        var owner: Int
        var dirs: [Int]
    }

    private struct Lights {
        var ortho: OrthoLight
        var killzone: [Bool]
        var lensHits: [Bool]
        var laserCov: [UInt8]
        var laserAxis: [LaserAxes]
        var activeLasers: [Int]
    }

    /// Mirror reflection: `/` turns N↔E and S↔W; `\` turns N↔W and S↔E.
    private static func reflect(_ dir: Int, off orientation: Orientation?) -> Int {
        orientation == .slash ? dir ^ 2 : 3 - dir
    }

    /// The two orthogonal directions a struck diffuser emits into.
    private static func lensOutputs(_ orientation: Orientation?) -> [Int] {
        switch orientation {
        case .ne: [0, 2]
        case .nw: [0, 3]
        case .se: [1, 2]
        case .sw: [1, 3]
        default: []
        }
    }

    /// Traces orthogonal light from every source (and every struck diffuser) through mirrors
    /// and prisms until it hits a piece or the edge.
    private func propagateOrtho(_ lensRays: [LensRay]) -> OrthoLight {
        let count = grid.count
        var out = OrthoLight(lit: Array(repeating: [], count: count),
                             emptyFed: Array(repeating: [], count: count),
                             fedFaces: Array(repeating: [], count: count * 4),
                             laserFed: Array(repeating: false, count: count))
        // One flag per (square, direction, owner, ranged) ray start.
        var visited = [Bool](repeating: false, count: count * 24)
        var stack: [(cell: Int, dir: Int, owner: Int, ranged: Bool)] = []
        for cell in 0..<count {
            if let piece = grid[cell], piece.kind == .source {
                for dir in 0..<4 { stack.append((cell, dir, piece.owner, false)) }
            }
        }
        for ray in lensRays {
            for dir in ray.dirs { stack.append((ray.cell, dir, ray.owner, false)) }
        }

        while let ray = stack.popLast() {
            let key = ((ray.cell * 4 + ray.dir) * 3 + ray.owner) * 2 + (ray.ranged ? 1 : 0)
            if visited[key] { continue }
            visited[key] = true

            let (dr, dc) = Board.ortho[ray.dir]
            let bit = Owners.of(ray.owner)
            var r = ray.cell / size, c = ray.cell % size
            var remaining = Board.prismRange
            while true {
                r += dr
                c += dc
                if !contains(r, c) { break }
                if ray.ranged && remaining <= 0 { break }
                let cell = r * size + c
                let crossedGap = grid[cell - dr * size - dc] == nil
                guard let piece = grid[cell] else {
                    out.lit[cell].insert(bit)
                    if crossedGap { out.emptyFed[cell].insert(bit) }
                    if ray.ranged { remaining -= 1 }
                    continue
                }
                if crossedGap { out.fedFaces[cell * 4 + (ray.dir ^ 1)].insert(bit) }
                switch piece.kind {
                case .mirror:
                    stack.append((cell, Board.reflect(ray.dir, off: piece.orientation), ray.owner, false))
                case .prism:
                    // Splits into every direction but back, each with a short range.
                    for dir in 0..<4 where dir != ray.dir ^ 1 { stack.append((cell, dir, ray.owner, true)) }
                case .laser:
                    out.laserFed[cell] = true
                default:
                    break
                }
                break
            }
        }
        return out
    }

    /// Fires every active laser along its four diagonals. Beams pass through pieces and stop
    /// only at a diffuser (which they strike) or another laser.
    private func propagateLasers(_ active: [Int]) -> (cov: [UInt8], lensHits: [Bool], axis: [LaserAxes]) {
        let count = grid.count
        var cov = [UInt8](repeating: 0, count: count)
        var lensHits = [Bool](repeating: false, count: count)
        var axis = [LaserAxes](repeating: [], count: count)
        for laser in active {
            for (dr, dc) in Board.diagonals {
                let beamAxis: LaserAxes = dr == dc ? .backslash : .slash
                var r = laser / size, c = laser % size
                while true {
                    r += dr
                    c += dc
                    if !contains(r, c) { break }
                    let cell = r * size + c
                    cov[cell] += 1
                    axis[cell].insert(beamAxis)
                    if let piece = grid[cell] {
                        if piece.kind == .lens { lensHits[cell] = true; break }
                        if piece.kind == .laser { break }
                    }
                }
            }
        }
        return (cov, lensHits, axis)
    }

    /// Light and beams for the current grid. Struck diffusers emit new light, which can feed
    /// more lasers, so this iterates (at most 8 times) until the set of diffuser rays settles.
    private func resolveLightsOnce() -> Lights {
        var lensRays: [LensRay] = []
        var iteration = 0
        while true {
            let ortho = propagateOrtho(lensRays)
            let active = ortho.laserFed.indices.filter { ortho.laserFed[$0] }
            let beams = propagateLasers(active)
            let lights = Lights(ortho: ortho, killzone: beams.cov.map { $0 >= 2 }, lensHits: beams.lensHits,
                                laserCov: beams.cov, laserAxis: beams.axis, activeLasers: active)
            var newRays: [LensRay] = []
            for cell in beams.lensHits.indices where beams.lensHits[cell] {
                guard let piece = grid[cell] else { continue }
                newRays.append(LensRay(cell: cell, owner: lensPrivate ? piece.owner : Owners.sharedIndex,
                                       dirs: Board.lensOutputs(piece.orientation)))
            }
            iteration += 1
            if newRays == lensRays || iteration == 8 { return lights }
            lensRays = newRays
        }
    }

    private mutating func commit(_ lights: Lights) {
        lit = lights.ortho.lit
        emptyFed = lights.ortho.emptyFed
        fedFaces = lights.ortho.fedFaces
        killzone = lights.killzone
        lensHits = lights.lensHits
        laserCov = lights.laserCov
        laserAxis = lights.laserAxis
        activeLasers = lights.activeLasers
    }

    // MARK: - Resolution

    /// Recomputes light and removes everything that cannot live, repeating until stable:
    /// pieces in a cavity (except lasers, diffusers, and — with check on — sources), diffusers
    /// no beam strikes, and pieces with no light entering a face across an empty gap.
    @discardableResult
    mutating func resolve(maxIterations: Int = 12) -> [Removal] {
        var removed: [Removal] = []
        for _ in 0..<maxIterations {
            let lights = resolveLightsOnce()
            var doomed: [(cell: Int, cause: Removal.Cause)] = []
            var marked = [Bool](repeating: false, count: grid.count)
            for cell in grid.indices where lights.killzone[cell] {
                guard let piece = grid[cell], piece.kind != .laser, piece.kind != .lens else { continue }
                if piece.kind == .source && checkMode { continue }
                doomed.append((cell, .cavity))
                marked[cell] = true
            }
            for cell in grid.indices {
                guard let piece = grid[cell], piece.kind != .source, !marked[cell] else { continue }
                // A diffuser needs both inputs: a beam striking it, and fed light like any piece.
                if piece.kind == .lens && !lights.lensHits[cell] {
                    doomed.append((cell, .lensNoLaser))
                    continue
                }
                if !isFed(cell, piece, lights.ortho) { doomed.append((cell, .starved)) }
            }
            if doomed.isEmpty {
                commit(lights)
                return removed
            }
            for (cell, cause) in doomed {
                guard let piece = grid[cell] else { continue }
                if piece.kind == .source {
                    for owner in sources.indices {
                        if let i = sources[owner].firstIndex(of: cell) { sources[owner].remove(at: i) }
                    }
                }
                removed.append(Removal(cell: cell, piece: piece, cause: cause))
                grid[cell] = nil
            }
        }
        commit(resolveLightsOnce())
        return removed
    }

    private func isFed(_ cell: Int, _ piece: Piece, _ light: OrthoLight) -> Bool {
        guard fedSurvival else { return hasLitEmptyNeighbor(cell, light.lit) }
        let faces = light.fedFaces[(cell * 4)..<(cell * 4 + 4)]
        if lifeOwnerRequired { return faces.contains { $0.serves(piece.owner) } }
        return faces.contains { !$0.isEmpty }
    }

    private func hasLitEmptyNeighbor(_ cell: Int, _ lit: [Owners]) -> Bool {
        let r = cell / size, c = cell % size
        for (dr, dc) in Board.ortho where contains(r + dr, c + dc) {
            let neighbor = index(r + dr, c + dc)
            if grid[neighbor] == nil && !lit[neighbor].isEmpty { return true }
        }
        return false
    }

    // MARK: - Queries

    /// Empty squares `player` may build on: entered by their (or shared) light across an empty
    /// gap, outside every moat and, unless `includeKillzone`, outside cavities. Diffusers opt
    /// into cavity squares since they are exempt from cavity removal. Ascending order.
    func reach(_ player: Player, includeKillzone: Bool = false) -> [Int] {
        let moat = moat()
        var out: [Int] = []
        for cell in grid.indices where grid[cell] == nil && !moat[cell] && emptyFed[cell].serves(player) {
            if !includeKillzone && killzone[cell] { continue }
            out.append(cell)
        }
        return out
    }

    /// Whether any of `player`'s sources still has an open orthogonal neighbor to shine into.
    func sourceAlive(_ player: Player) -> Bool {
        sources[player].contains { source in
            let r = source / size, c = source % size
            return Board.ortho.contains { contains(r + $0.dr, c + $0.dc) && grid[index(r + $0.dr, c + $0.dc)] == nil }
        }
    }

    // MARK: - Moves

    /// Converts chambers with three or more fed faces into sources, one at a time, until none
    /// qualify. Each conversion clears the non-source pieces around the new source. Light from
    /// either player counts, with the mover winning ties.
    @discardableResult
    mutating func convertChambers(mover: Player) -> (converted: Int, privGained: Int, oppGained: Int) {
        var converted = 0, privGained = 0, oppGained = 0
        var changed = true
        while changed {
            changed = false
            resolve()
            for cell in conversionOrder where grid[cell]?.kind == .chamber {
                let other = 1 - mover
                var moverQual = 0, otherQual = 0
                for face in 0..<4 {
                    let owners = fedFaces[cell * 4 + face]
                    if owners.isEmpty { continue }
                    if owners.serves(mover) { moverQual += 1 }
                    if owners.serves(other) { otherQual += 1 }
                }
                let newOwner: Player
                if moverQual >= 3 {
                    newOwner = mover
                } else if otherQual >= 3 {
                    newOwner = other
                } else {
                    continue
                }
                grid[cell] = nil
                let r = cell / size, c = cell % size
                for dr in -1...1 {
                    for dc in -1...1 where (dr != 0 || dc != 0) && contains(r + dr, c + dc) {
                        let neighbor = index(r + dr, c + dc)
                        if let piece = grid[neighbor], piece.kind != .source { grid[neighbor] = nil }
                    }
                }
                grid[cell] = Piece(kind: .source, owner: newOwner, orientation: nil)
                sources[newOwner].append(cell)
                if newOwner == mover { privGained += 1 } else { oppGained += 1 }
                converted += 1
                changed = true
                break
            }
        }
        return (converted, privGained, oppGained)
    }

    /// Places `move` for `mover` and plays out the consequences: removals, conversions and,
    /// with check on, the death of the mover's own sources still trapped in a cavity.
    @discardableResult
    mutating func apply(_ move: Move, by mover: Player) -> MoveResult {
        grid[move.cell] = Piece(kind: move.kind, owner: mover, orientation: move.orientation)
        var removed = resolve()
        let conversion = convertChambers(mover: mover)
        resolve()
        // Check on: the mover had this turn to break any cavity around their own sources.
        // Whatever is still trapped dies now (which can cascade, hence the re-resolve).
        if checkMode {
            for _ in 0..<8 {
                let doomed = sources[mover].filter { killzone[$0] }
                if doomed.isEmpty { break }
                for source in doomed {
                    if let i = sources[mover].firstIndex(of: source) { sources[mover].remove(at: i) }
                    if let piece = grid[source] {
                        removed.append(Removal(cell: source, piece: piece, cause: .cavity))
                        grid[source] = nil
                    }
                }
                removed += resolve()
            }
        }
        return MoveResult(survived: grid[move.cell]?.kind == move.kind, removed: removed,
                          privGained: conversion.privGained, oppGained: conversion.oppGained)
    }
}
