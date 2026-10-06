//
//  OnlineMatch.swift
//  Photon
//
//  Online play as Game Center turn-based matches: sign-in, the games list and invites, and
//  passing turns. Each turn stores the rules and the whole action list on Game Center, so a
//  game survives either player closing the app, and Game Center notifies the player whose
//  turn it is. Several games can run at once; the board shows one at a time.
//

import GameKit
import UIKit
import UserNotifications

/// The settings a game is played by, fixed by whoever starts it.
nonisolated struct GameRules: Codable, Sendable, Equatable {
    static let boardSizes = [13, 15, 17, 19]
    static let sourceCounts = 1...4

    var boardSize: Int
    var sourcesPerPlayer: Int
    var checkMode: Bool

    var isValid: Bool { Self.boardSizes.contains(boardSize) && Self.sourceCounts.contains(sourcesPerPlayer) }
}

/// One step of a game, as replayed from the start on the other device.
nonisolated enum GameAction: Codable, Sendable, Hashable {
    case source(cell: Int, seat: Player)
    case move(Move, mover: Player)
}

/// What a match stores on Game Center.
nonisolated struct MatchData: Codable, Sendable, Equatable {
    /// Who took the match's first turn and so plays seat 0 (blue). Game Center doesn't keep
    /// participants in turn order (a rematch can list them either way), so the seats are
    /// stored rather than read off the participant list.
    var firstPlayerID: String
    var rules: GameRules
    var actions: [GameAction]

    func encoded() throws -> Data {
        try (JSONEncoder().encode(self) as NSData).compressed(using: .zlib) as Data
    }

    static func decode(_ data: Data) -> MatchData? {
        guard let json = try? (data as NSData).decompressed(using: .zlib) as Data else { return nil }
        return try? JSONDecoder().decode(MatchData.self, from: json)
    }
}

@Observable
final class OnlineMatch: NSObject {
    private(set) var isAuthenticated = false
    /// Whether a match is on the board.
    private(set) var isActive = false
    /// 0 if this player took the match's first turn (blue, moves first), otherwise 1.
    private(set) var localSeat: Player = 0
    /// Nil until someone takes the other seat.
    private(set) var opponentName: String?
    private(set) var isMyTurn = false
    /// A turn is on its way to Game Center.
    private(set) var isSending = false
    /// The match has ended on Game Center.
    private(set) var isOver = false
    /// A seat that resigned or let its turn time out.
    private(set) var forfeitedSeat: Player?
    /// A problem to show the player; the view clears it once shown.
    var alert: String?

    /// Called whenever the match on the board is opened or changes. The data is nil for a
    /// match nobody has moved in yet.
    @ObservationIgnored var onLoad: ((_ data: MatchData?, _ isNewMatch: Bool) -> Void)?

    @ObservationIgnored private var match: GKTurnBasedMatch?
    @ObservationIgnored private var firstPlayerID: String?
    @ObservationIgnored private var matchmaker: UIViewController?
    @ObservationIgnored private var signInController: UIViewController?
    @ObservationIgnored private var didStartAuthentication = false

    private var localID: String { GKLocalPlayer.local.gamePlayerID }

    // MARK: Sign-in

    /// Signs in to Game Center. Call once, at launch: the turn notifications a player taps to
    /// open the app are only delivered after sign-in.
    func authenticate() {
        guard !didStartAuthentication else { return }
        didStartAuthentication = true
        GKLocalPlayer.local.authenticateHandler = { @Sendable [weak self] viewController, error in
            let failure = error?.localizedDescription
            guard let self else { return }
            Task { @MainActor in self.authenticationChanged(viewController, failure) }
        }
    }

    private func authenticationChanged(_ viewController: UIViewController?, _ failure: String?) {
        let local = GKLocalPlayer.local
        isAuthenticated = local.isAuthenticated
        // Keep the sign-in screen for when the player asks to play online; popping it up at
        // launch would get in the way of a game against Amber.
        signInController = viewController
        if local.isAuthenticated {
            signInController = nil
            local.unregisterAllListeners()
            local.register(self)
        } else {
            close()
        }
        if let failure, viewController == nil { print("Game Center sign-in failed: \(failure)") }
    }

    // MARK: Opening matches

    /// Shows Game Center's list of this player's games, where they can also start a new one by
    /// inviting a friend or getting matched with anyone.
    func showGames() {
        let local = GKLocalPlayer.local
        guard local.isAuthenticated else {
            if let signInController {
                present(signInController)
            } else {
                alert = "Sign in to Game Center in Settings to play online."
            }
            return
        }
        guard !local.isMultiplayerGamingRestricted else {
            alert = "Multiplayer games are turned off in Screen Time on this device."
            return
        }
        showMatchmaker(recipients: nil)
    }

    private func showMatchmaker(recipients: [GKPlayer]?) {
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.recipients = recipients
        request.inviteMessage = "Let’s play Photon!"
        let controller = GKTurnBasedMatchmakerViewController(matchRequest: request)
        controller.turnBasedMatchmakerDelegate = self
        controller.showExistingMatches = true
        matchmaker = controller
        present(controller)
    }

    private func dismissMatchmaker() {
        matchmaker?.dismiss(animated: true)
        matchmaker = nil
    }

    /// Takes the match off the board. It carries on in Game Center and can be reopened from
    /// the games list.
    func close() {
        match = nil
        firstPlayerID = nil
        isActive = false
        isMyTurn = false
        isOver = false
        forfeitedSeat = nil
        opponentName = nil
    }

    /// Picks up anything that happened while the app was in the background.
    func refresh() {
        // Mid-send, Game Center still has the turn before this one; loading it would roll the
        // board back until the send lands.
        guard let match, !isSending else { return }
        Task { await load(match) }
    }

    /// Fetches a match's latest state and puts it on the board.
    private func load(_ match: GKTurnBasedMatch) async {
        let raw: Data?
        do {
            raw = try await match.loadMatchData()
        } catch {
            alert = "Couldn’t load the game: \(error.localizedDescription)"
            return
        }
        let isNew = match.matchID != self.match?.matchID
        let data = raw.flatMap { $0.isEmpty ? nil : MatchData.decode($0) }
        if let raw, !raw.isEmpty, data == nil {
            alert = "This game was saved by a newer version of Photon."
            return
        }
        if isNew { requestNotifications() }
        self.match = match
        isActive = true
        isOver = match.status == .ended
        isMyTurn = match.status == .open && match.currentParticipant?.player?.gamePlayerID == localID
        // Whoever moves while the match is still empty is starting it, and so takes seat 0.
        firstPlayerID = data?.firstPlayerID ?? (isMyTurn ? localID : nil)
        localSeat = firstPlayerID == localID ? 0 : 1
        let opponent = opponent(in: match)
        opponentName = opponent?.player?.displayName
        forfeitedSeat = nil
        for participant in match.participants where [.quit, .timeExpired].contains(participant.matchOutcome) {
            forfeitedSeat = participant.player?.gamePlayerID == localID ? localSeat : 1 - localSeat
        }
        onLoad?(data, isNew)
        // An opponent who quits out of turn leaves the match open with this player to move;
        // it's up to them to close it as a win.
        if forfeitedSeat == 1 - localSeat && isMyTurn,
           await endMatch(match, data: raw ?? Data(), winner: localSeat, message: nil) {
            await load(match)
        }
    }

    /// Game Center delivers turn notifications as the app's own, so they need the player's
    /// permission. iOS asks only once; after that this does nothing.
    private func requestNotifications() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    private func opponent(in match: GKTurnBasedMatch) -> GKTurnBasedParticipant? {
        match.participants.first { $0.player?.gamePlayerID != localID }
    }

    // MARK: Turns

    /// Stores the game on Game Center and passes the turn, or ends the match if there is a
    /// winner. `message` is what the opponent sees in the turn notification.
    func submit(rules: GameRules, actions: [GameAction], message: String, winner: Player?) {
        guard let match, isMyTurn, !isOver, !isSending, let firstPlayerID else { return }
        let data: Data
        do {
            data = try MatchData(firstPlayerID: firstPlayerID, rules: rules, actions: actions).encoded()
        } catch {
            alert = "Couldn’t save your move: \(error.localizedDescription)"
            return
        }
        guard data.count <= match.matchDataMaximumSize else {
            alert = "This game has grown too long for Game Center to store."
            return
        }
        isMyTurn = false
        isSending = true
        Task {
            if let winner {
                await endMatch(match, data: data, winner: winner, message: message)
            } else {
                match.message = message
                do {
                    let others = match.participants.filter { $0.player?.gamePlayerID != localID }
                    try await match.endTurn(withNextParticipants: others, turnTimeout: GKTurnTimeoutDefault, match: data)
                } catch {
                    alert = "Couldn’t send your move: \(error.localizedDescription)"
                }
            }
            isSending = false
            // On failure this puts the board back the way Game Center has it.
            await load(match)
        }
    }

    @discardableResult
    private func endMatch(_ match: GKTurnBasedMatch, data: Data, winner: Player, message: String?) async -> Bool {
        let winnerID = winner == localSeat ? localID : opponent(in: match)?.player?.gamePlayerID
        for participant in match.participants where participant.matchOutcome == .none {
            participant.matchOutcome = participant.player?.gamePlayerID == winnerID ? .won : .lost
        }
        if let message { match.message = message }
        do {
            try await match.endMatchInTurn(withMatch: data)
            return true
        } catch {
            alert = "Couldn’t end the game: \(error.localizedDescription)"
            return false
        }
    }

    /// Concedes the match on the board.
    func resign() {
        guard let match, !isOver else { return }
        Task {
            await quit(match, inTurn: isMyTurn)
            await load(match)
        }
    }

    private func quit(_ match: GKTurnBasedMatch, inTurn: Bool) async {
        do {
            if inTurn {
                for participant in match.participants {
                    participant.matchOutcome = participant.player?.gamePlayerID == localID ? .quit : .won
                }
                match.message = "\(GKLocalPlayer.local.displayName) resigned. You win!"
                try await match.endMatchInTurn(withMatch: match.matchData ?? Data())
            } else {
                // The opponent, who is to move, closes the match when they next open it.
                try await match.participantQuitOutOfTurn(with: .quit)
            }
        } catch {
            alert = "Couldn’t resign: \(error.localizedDescription)"
        }
    }

    /// Starts a new match against the same opponent, with this player moving first.
    func rematch() {
        guard let match, isOver else { return }
        Task {
            do {
                await load(try await match.rematch())
            } catch {
                alert = "Couldn’t start a rematch: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Events

    private func turnEvent(_ match: GKTurnBasedMatch, didBecomeActive: Bool) {
        if match.matchID == self.match?.matchID || didBecomeActive || matchmaker != nil {
            // The match on the board moved on, the player tapped a turn notification, or they
            // picked or started a match in the games list.
            dismissMatchmaker()
            Task { await load(match) }
        } else if match.status == .open, match.currentParticipant?.player?.gamePlayerID == localID {
            let name = opponent(in: match)?.player?.displayName ?? "your opponent"
            alert = "It’s your turn in your game with \(name). Open it from Play Online."
        }
    }

    // MARK: Presentation

    private func present(_ controller: UIViewController) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(controller, animated: true)
    }
}

// GameKit calls these on the main thread, but its protocols aren't main-actor isolated, so
// each callback hops over explicitly.

extension OnlineMatch: GKTurnBasedMatchmakerViewControllerDelegate {
    nonisolated func turnBasedMatchmakerViewControllerWasCancelled(_ viewController: GKTurnBasedMatchmakerViewController) {
        Task { @MainActor in self.dismissMatchmaker() }
    }

    nonisolated func turnBasedMatchmakerViewController(_ viewController: GKTurnBasedMatchmakerViewController,
                                                       didFailWithError error: any Error) {
        let failure = error.localizedDescription
        Task { @MainActor in
            self.dismissMatchmaker()
            self.alert = failure
        }
    }
}

extension OnlineMatch: GKLocalPlayerListener {
    /// A turn was taken in one of this player's matches, they tapped a turn notification, or
    /// they picked or started a match in the games list.
    nonisolated func player(_ player: GKPlayer, receivedTurnEventFor match: GKTurnBasedMatch, didBecomeActive: Bool) {
        nonisolated(unsafe) let match = match
        Task { @MainActor in self.turnEvent(match, didBecomeActive: didBecomeActive) }
    }

    nonisolated func player(_ player: GKPlayer, matchEnded match: GKTurnBasedMatch) {
        nonisolated(unsafe) let match = match
        Task { @MainActor in
            if match.matchID == self.match?.matchID { await self.load(match) }
        }
    }

    /// The player quit a match from the games list while it was their turn.
    nonisolated func player(_ player: GKPlayer, wantsToQuitMatch match: GKTurnBasedMatch) {
        nonisolated(unsafe) let match = match
        Task { @MainActor in
            await self.quit(match, inTurn: true)
            if match.matchID == self.match?.matchID { await self.load(match) }
        }
    }

    /// The player started a game with friends from the Games app or Game Center.
    nonisolated func player(_ player: GKPlayer, didRequestMatchWithOtherPlayers playersToInvite: [GKPlayer]) {
        nonisolated(unsafe) let playersToInvite = playersToInvite
        Task { @MainActor in self.showMatchmaker(recipients: playersToInvite) }
    }
}
