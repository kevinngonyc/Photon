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
    /// Who started the match, and the seat they chose; the other player takes the other seat.
    /// Game Center doesn't keep participants in turn order (a rematch can list them either
    /// way), so the seats are stored rather than read off the participant list.
    var hostID: String
    /// Missing in matches from before colors could be chosen, where the host was always seat 0.
    var hostSeat: Player?
    var rules: GameRules
    var actions: [GameAction]
    /// The finished match this one is a rematch of, so the opponent's device can swap it in.
    var rematchOf: String?

    private enum CodingKeys: String, CodingKey {
        case hostID = "firstPlayerID", hostSeat, rules, actions, rematchOf
    }

    func seat(of playerID: String) -> Player {
        let seat = hostSeat ?? 0
        return playerID == hostID ? seat : 1 - seat
    }

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
    /// 0 if this player is cyan (moves first), otherwise 1.
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
    /// Another game waiting on this player, offered in place of the one on the board; the view
    /// clears it once shown.
    var invite: Invite?
    /// A rematch is being set up, so asking again would start a second one.
    private(set) var isStartingRematch = false
    /// Whether the match on the board is a rematch of an earlier one.
    var isRematch: Bool { rematchOf != nil }

    struct Invite: Identifiable, Equatable {
        let matchID: String
        let title: String
        let text: String
        var id: String { matchID }
    }

    /// Called whenever the match on the board is opened or changes. The data is nil for a
    /// match nobody has moved in yet.
    @ObservationIgnored var onLoad: ((_ data: MatchData?, _ isNewMatch: Bool) -> Void)?
    /// Asked when this player starts a match: the rules to play by and the seat they take.
    @ObservationIgnored var onStart: (() -> (rules: GameRules, seat: Player))?

    @ObservationIgnored private var match: GKTurnBasedMatch?
    /// Who started the match on the board, and their seat.
    @ObservationIgnored private var host: (id: String, seat: Player)?
    @ObservationIgnored private var rematchOf: String?
    /// How many actions Game Center is known to have for the match on the board. Game Center
    /// can briefly serve an older turn, and a load that comes back with fewer is one of those.
    @ObservationIgnored private var syncedCount = 0
    /// Loads overlap (a turn event, the app coming back, a send landing) and can finish out of
    /// order; only the most recently started one that finishes is shown.
    @ObservationIgnored private var loadsStarted = 0
    @ObservationIgnored private var loadShown = 0
    @ObservationIgnored private var startingMatchID: String?
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
        // launch would get in the way of a game against the bot.
        signInController = viewController
        if local.isAuthenticated {
            signInController = nil
            local.unregisterAllListeners()
            local.register(self)
            // Sign-in finishes after the app is already active, so this is launch's catch-up.
            refresh()
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
        // Color stays out of the request (no player group or attributes), so it never narrows
        // who automatch pairs this player with: whoever starts a match picks their color, and
        // whoever joins takes the side that's left.
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
        host = nil
        rematchOf = nil
        syncedCount = 0
        isActive = false
        isMyTurn = false
        isOver = false
        forfeitedSeat = nil
        opponentName = nil
    }

    /// Picks up anything that happened while the app was in the background: turns in the
    /// match on the board, a rematch the opponent started, and the badge.
    func refresh() {
        guard isAuthenticated else { return }
        // Game Center's notifications are all caught up on once the app is open; the badge
        // keeps count of the games still waiting.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        Task {
            let matches = (try? await GKTurnBasedMatch.loadMatches()) ?? []
            await setBadge(for: matches)
            // Mid-send, Game Center still has the turn before this one; loading it would roll
            // the board back until the send lands.
            guard let current = match, !isSending else { return }
            if isOver, let rematch = await rematch(of: current, in: matches) {
                await load(rematch)
            } else if let fresh = matches.first(where: { $0.matchID == current.matchID }) {
                await load(fresh)
            } else {
                await load(current, refetch: true)
            }
        }
    }

    /// Fetches a match's latest state and puts it on the board. A match object kept from
    /// earlier still has the turn and status it had then, even after reloading its data, so
    /// `refetch` asks Game Center for the match afresh. `rematchOf` is for a match this player
    /// has just started as a rematch.
    private func load(_ match: GKTurnBasedMatch, refetch: Bool = false, rematchOf: String? = nil) async {
        loadsStarted += 1
        let order = loadsStarted
        var match = match
        var raw: Data?
        for attempt in 0..<3 {
            do {
                if refetch || attempt > 0 { match = try await GKTurnBasedMatch.load(withID: match.matchID) }
                // Opened any way but through the games list (a rematch swapped in, an invite
                // taken up from an alert), the invitation still needs accepting.
                if match.participants.contains(where: { $0.player?.gamePlayerID == localID && $0.status == .invited }) {
                    match = try await match.acceptInvite()
                }
                raw = try await match.loadMatchData()
            } catch {
                alert = "Couldn’t load the game: \(error.localizedDescription)"
                return
            }
            guard isBehind(match, raw) else { break }
            // Still behind after a few tries: keep the board as it is, which is newer.
            if attempt == 2 { return }
            try? await Task.sleep(for: .seconds(1))
        }
        var data = raw.flatMap { $0.isEmpty ? nil : MatchData.decode($0) }
        if let raw, !raw.isEmpty, data == nil {
            alert = "This game was saved by a newer version of Photon."
            return
        }
        var isLocalTurn = match.status == .open && match.currentParticipant?.player?.gamePlayerID == localID
        // Whoever moves while the match is still empty is starting it. Anyone joining, by invite
        // or automatch, only gets the match after that, with the seats already set.
        if data == nil && isLocalTurn, let onStart {
            // Another load of this match is already starting it, and will show it.
            guard startingMatchID != match.matchID else { return }
            startingMatchID = match.matchID
            defer { startingMatchID = nil }
            guard let started = await start(match, onStart(), rematchOf: rematchOf) else { return }
            data = started
            isLocalTurn = started.hostSeat == 0
        }
        // A later load has already shown something newer, or a send on this match is in flight
        // and will load it again once it lands.
        guard order > loadShown, !(isSending && match.matchID == self.match?.matchID) else { return }
        loadShown = order
        let isNew = match.matchID != self.match?.matchID
        if isNew { requestNotifications() }
        self.match = match
        isActive = true
        isOver = match.status == .ended
        isMyTurn = isLocalTurn
        host = data.map { ($0.hostID, $0.hostSeat ?? 0) } ?? (isMyTurn ? (localID, 0) : nil)
        self.rematchOf = data?.rematchOf
        syncedCount = data?.actions.count ?? 0
        localSeat = data?.seat(of: localID) ?? (isMyTurn ? 0 : 1)
        let opponent = opponent(in: match)
        opponentName = opponent?.player?.displayName
        forfeitedSeat = nil
        for participant in match.participants where [.quit, .timeExpired].contains(participant.matchOutcome) {
            forfeitedSeat = participant.player?.gamePlayerID == localID ? localSeat : 1 - localSeat
        }
        if invite?.matchID == match.matchID { invite = nil }
        onLoad?(data, isNew)
        // An opponent who quits out of turn leaves the match open with this player to move;
        // it's up to them to close it as a win.
        if forfeitedSeat == 1 - localSeat && isMyTurn,
           await endMatch(match, data: raw ?? Data(), winner: localSeat, message: nil) {
            await load(match)
            return
        }
        updateBadge()
    }

    /// Whether Game Center served the match on the board at an older turn than one already seen.
    private func isBehind(_ match: GKTurnBasedMatch, _ raw: Data?) -> Bool {
        guard match.matchID == self.match?.matchID else { return false }
        if isOver && match.status != .ended { return true }
        let count = raw.flatMap { $0.isEmpty ? nil : MatchData.decode($0) }?.actions.count ?? 0
        return count < syncedCount
    }

    /// Settles the seats of a match this player is starting, so a random pick isn't drawn
    /// again the next time it loads. As cyan, they keep the turn to place the first source;
    /// as amber, it passes straight to the opponent (or to whoever automatch finds).
    private func start(_ match: GKTurnBasedMatch, _ setup: (rules: GameRules, seat: Player),
                       rematchOf: String?) async -> MatchData? {
        let data = MatchData(hostID: localID, hostSeat: setup.seat, rules: setup.rules, actions: [], rematchOf: rematchOf)
        do {
            let encoded = try data.encoded()
            if setup.seat == 0 {
                try await match.saveCurrentTurn(withMatch: encoded)
            } else {
                let name = GKLocalPlayer.local.displayName
                match.message = rematchOf == nil
                    ? "\(name) is playing amber. You’re cyan — place the first source."
                    : "\(name) wants a rematch, playing amber. You’re cyan — place the first source."
                let others = match.participants.filter { $0.player?.gamePlayerID != localID }
                try await match.endTurn(withNextParticipants: others, turnTimeout: GKTurnTimeoutDefault, match: encoded)
            }
            return data
        } catch {
            alert = "Couldn’t start the game: \(error.localizedDescription)"
            return nil
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

    private func isWaitingOnLocalPlayer(_ match: GKTurnBasedMatch) -> Bool {
        [.open, .matching].contains(match.status) && match.currentParticipant?.player?.gamePlayerID == localID
    }

    // MARK: Badge

    /// Game Center's turn notifications set the app's badge but never clear it, so the app keeps
    /// it at the number of games waiting on this player.
    private func updateBadge() {
        Task {
            guard let matches = try? await GKTurnBasedMatch.loadMatches() else { return }
            await setBadge(for: matches)
        }
    }

    private func setBadge(for matches: [GKTurnBasedMatch]) async {
        let waiting = matches.filter(isWaitingOnLocalPlayer).count
        try? await UNUserNotificationCenter.current().setBadgeCount(waiting)
    }

    // MARK: Turns

    /// Stores the game on Game Center and passes the turn, or ends the match if there is a
    /// winner. `message` is what the opponent sees in the turn notification.
    func submit(rules: GameRules, actions: [GameAction], message: String, winner: Player?) {
        guard let match, isMyTurn, !isOver, !isSending, let host else { return }
        let data: Data
        do {
            data = try MatchData(hostID: host.id, hostSeat: host.seat, rules: rules, actions: actions,
                                 rematchOf: rematchOf).encoded()
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
                if await endMatch(match, data: data, winner: winner, message: message) { syncedCount = actions.count }
            } else {
                match.message = message
                do {
                    let others = match.participants.filter { $0.player?.gamePlayerID != localID }
                    try await match.endTurn(withNextParticipants: others, turnTimeout: GKTurnTimeoutDefault, match: data)
                    syncedCount = actions.count
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

    /// Starts a new match against the same opponent, with this player starting it (and so
    /// picking their color). If the opponent got there first, this joins theirs instead.
    func rematch() {
        guard let match, isOver, !isStartingRematch else { return }
        isStartingRematch = true
        Task {
            defer { isStartingRematch = false }
            let matches = (try? await GKTurnBasedMatch.loadMatches()) ?? []
            if let existing = await rematch(of: match, in: matches) {
                await load(existing)
                return
            }
            do {
                await load(try await match.rematch(), rematchOf: match.matchID)
            } catch {
                alert = "Couldn’t start a rematch: \(error.localizedDescription)"
            }
        }
    }

    /// A match still in play that either player started as a rematch of `finished`.
    private func rematch(of finished: GKTurnBasedMatch, in matches: [GKTurnBasedMatch]) async -> GKTurnBasedMatch? {
        let opponentID = opponent(in: finished)?.player?.gamePlayerID
        let candidates = matches.filter { candidate in
            candidate.matchID != finished.matchID && [.open, .matching].contains(candidate.status)
                && opponentID != nil && self.opponent(in: candidate)?.player?.gamePlayerID == opponentID
        }
        for candidate in candidates {
            guard let raw = try? await candidate.loadMatchData(), let data = MatchData.decode(raw) else { continue }
            if data.rematchOf == finished.matchID { return candidate }
        }
        return nil
    }

    // MARK: Events

    private func turnEvent(_ match: GKTurnBasedMatch, didBecomeActive: Bool) {
        updateBadge()
        if match.matchID == self.match?.matchID {
            // The match on the board moved on. While a send is in flight this is likely its own
            // echo, and the send loads the match once it lands.
            guard !isSending else { return }
            Task { await load(match) }
        } else if didBecomeActive || matchmaker != nil {
            // The player tapped a turn notification, or picked or started a match in the games list.
            dismissMatchmaker()
            Task { await load(match) }
        } else if isWaitingOnLocalPlayer(match) {
            Task { await offer(match) }
        }
    }

    /// A turn came in for a game that isn't on the board. A rematch of the finished game on the
    /// board takes its place right away; anything else is offered.
    private func offer(_ match: GKTurnBasedMatch) async {
        let data = (try? await match.loadMatchData()).flatMap(MatchData.decode)
        if let current = self.match, let incoming = data?.rematchOf {
            if isOver && incoming == current.matchID {
                await load(match)
                return
            }
            // Both players asked for a rematch, and this player's hasn't reached the opponent yet
            // (they're cyan and haven't placed a source): play the opponent's instead.
            if !isOver, incoming == rematchOf, host?.id == localID, isMyTurn, syncedCount == 0, !isSending {
                await abandon(current)
                await load(match)
                return
            }
        }
        // Something else may have opened it in the meantime.
        guard match.matchID != self.match?.matchID else { return }
        let name = opponent(in: match)?.player?.displayName ?? "Your opponent"
        let isNewRematch = data?.rematchOf != nil && (data?.actions.count ?? 0) <= 1
        invite = isNewRematch
            ? Invite(matchID: match.matchID, title: "Rematch", text: "\(name) wants a rematch.")
            : Invite(matchID: match.matchID, title: "Your Turn", text: "It’s your turn in your game with \(name).")
    }

    /// Ends a match nobody has played in yet, with no result for either player, and drops it
    /// from the games list.
    private func abandon(_ match: GKTurnBasedMatch) async {
        for participant in match.participants { participant.matchOutcome = .tied }
        do {
            try await match.endMatchInTurn(withMatch: match.matchData ?? Data())
            try await match.remove()
        } catch {
            print("Couldn’t drop the unplayed rematch: \(error.localizedDescription)")
        }
    }

    /// Puts an offered game on the board.
    func accept(_ invite: Invite) {
        if self.invite == invite { self.invite = nil }
        dismissMatchmaker()
        Task {
            do {
                await load(try await GKTurnBasedMatch.load(withID: invite.matchID))
            } catch {
                alert = "Couldn’t load the game: \(error.localizedDescription)"
            }
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
            self.updateBadge()
            if match.matchID == self.match?.matchID, !self.isSending { await self.load(match) }
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
