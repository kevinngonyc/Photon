//
//  GameHUDView.swift
//  Photon
//
//  Status, history and game settings above the board.
//

import SwiftUI

struct GameHUDView: View {
    @Bindable var game: PhotonGame
    /// Opens the tutorial, which ContentView presents over everything.
    var openTutorial: () -> Void

    @State private var showsGuide = false
    @State private var flashing = false

    /// Height of the HUD row.
    static let height: CGFloat = 48

    var body: some View {
        let status = game.status
        let warning = game.checkWarning
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Circle()
                    .fill(Color.seat(status.seat))
                    .frame(width: 9, height: 9)
                    .shadow(color: .seat(status.seat), radius: 4)
                Text(warning ?? status.text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(warning == nil ? Color.textPrimary : Color.gridRed)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
            .glassEffect(.regular.tint(.gridUIElevated), in: RoundedRectangle(cornerRadius: 24))
            // Kept apart from the error alert below, so one can't knock the other out.
            .alert(game.online.invite?.title ?? "", isPresented: inviteShown, presenting: game.online.invite) { invite in
                Button("Play") { game.online.accept(invite) }
                    .keyboardShortcut(.defaultAction)
                Button("Later", role: .cancel) {}
            } message: { invite in
                Text(invite.text)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(Color.gridRed, lineWidth: 1.5)
                    .opacity(flashing ? 1 : 0)
            }

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    if game.mode == .online ? game.online.isOver : game.outcome != nil {
                        hudButton(game.mode == .online ? "Rematch" : "New Game", systemImage: "arrow.clockwise",
                                  enabled: !game.online.isStartingRematch) { game.newGame() }
                    }
                    hudButton("Undo", systemImage: "arrow.uturn.backward", enabled: game.canUndo) { game.undo() }
                        .keyboardShortcut("z", modifiers: .command)
                    hudButton("Redo", systemImage: "arrow.uturn.forward", enabled: game.canRedo) { game.redo() }
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                    settingsMenu
                }
            }
        }
        .padding(.horizontal, 16)
        .sensoryFeedback(.error, trigger: game.flashCount)
        .onChange(of: game.flashCount) {
            flashing = true
            withAnimation(.easeOut(duration: 0.26).delay(0.26)) { flashing = false }
        }
        .sheet(isPresented: $showsGuide) {
            GameGuideView(game: game)
                .presentationDetents([.medium, .large])
        }
        .alert("Online", isPresented: alertShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(game.online.alert ?? "")
        }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { game.online.alert != nil }, set: { if !$0 { game.online.alert = nil } })
    }

    private var inviteShown: Binding<Bool> {
        Binding(get: { game.online.invite != nil }, set: { if !$0 { game.online.invite = nil } })
    }

    private func hudButton(_ title: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: Self.height)
        }
        .accessibilityLabel(title)
        .foregroundStyle(enabled ? Color.textPrimary : Color.textMuted)
        .disabled(!enabled)
        .glassEffect(.regular.tint(.gridUIElevated).interactive(), in: RoundedRectangle(cornerRadius: 24))
    }

    /// An online game keeps the rules it started with, and so does its rematch. New online
    /// games take the offline settings.
    private var rulesLocked: Bool { game.mode == .online }

    private var settingsMenu: some View {
        Menu {
            if game.mode != .online {
                Button("New Game", systemImage: "arrow.clockwise") { game.newGame() }
            } else if game.online.isOver {
                Button("Rematch", systemImage: "arrow.clockwise") { game.newGame() }
                    .disabled(game.online.isStartingRematch)
            } else {
                Button("Resign", systemImage: "flag", role: .destructive) { game.online.resign() }
            }
            Section {
                if game.mode == .online {
                    Button("Play Offline", systemImage: "iphone") { game.leaveOnline() }
                } else {
                    Picker("Mode", systemImage: "person.2", selection: $game.mode) {
                        Text("vs Bot").tag(PhotonGame.Mode.bot)
                        Text("2 Players").tag(PhotonGame.Mode.twoPlayer)
                    }
                    .pickerStyle(.menu)
                }
                Button("Online Games", systemImage: "globe") { game.playOnline() }
                if game.mode == .bot {
                    Picker("Bot", systemImage: "cpu", selection: $game.difficulty) {
                        Text("Random").tag(Difficulty.random)
                        Text("Balanced").tag(Difficulty.balanced)
                        Text("Sharp").tag(Difficulty.sharp)
                    }
                    .pickerStyle(.menu)
                }
                // Also the side taken in online games this player hosts.
                Picker("Your Color", systemImage: "paintpalette", selection: $game.colorChoice) {
                    Text("Cyan (first)").tag(PhotonGame.ColorChoice.cyan)
                    Text("Amber (second)").tag(PhotonGame.ColorChoice.amber)
                    Text("Random").tag(PhotonGame.ColorChoice.random)
                }
                .pickerStyle(.menu)
                Picker("Board", systemImage: "square.grid.3x3", selection: $game.boardSize) {
                    ForEach(GameRules.boardSizes, id: \.self) { Text("\($0)×\($0)").tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(rulesLocked)
                Picker("Sources", systemImage: "circle.fill", selection: $game.sourcesPerPlayer) {
                    ForEach(GameRules.sourceCounts, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(rulesLocked)
                Toggle("Check", systemImage: "exclamationmark.shield", isOn: $game.checkMode)
                    .disabled(rulesLocked)
            }
            Button("Moves & Legend", systemImage: "list.bullet.rectangle") { showsGuide = true }
            Button("Tutorial", systemImage: "graduationcap") { openTutorial() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: Self.height)
        }
        .accessibilityLabel("Game settings")
        .foregroundStyle(Color.textPrimary)
        .glassEffect(.regular.tint(.gridUIElevated).interactive(), in: RoundedRectangle(cornerRadius: 24))
    }
}

/// The move log and the legend. The rules are taught by the tutorial.
struct GameGuideView: View {
    var game: PhotonGame

    var body: some View {
        NavigationStack {
            List {
                Section("Moves") {
                    if game.log.isEmpty {
                        Text("No moves yet.").foregroundStyle(Color.textMuted)
                    }
                    ForEach(numberedLog, id: \.entry.id) { item in
                        Text("\(item.label) \(game.label(item.entry.side)) \(item.entry.text)")
                            .font(.footnote.monospaced())
                            .foregroundStyle(Color.seat(item.entry.side))
                    }
                }
                Section("Legend") {
                    legendRow(.seat(game.viewerSeat), "Your light — you may place")
                    legendRow(.seat(1 - game.viewerSeat), "Opponent light")
                    legendRow(.gridGreen, "Shared light — either may place")
                    legendRow(.gridRed, "Laser beam / kill zone")
                    legendRow(Color(hex: 0xFF6B8A), "Removed last turn (ghost)", dashed: true)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.gridUIBackground)
            .navigationTitle("Photon")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    /// Setup moves are marked with a dot; play moves are numbered.
    private var numberedLog: [(label: String, entry: PhotonGame.LogEntry)] {
        var number = 0
        return game.log.map { entry in
            if entry.isSetup { return ("●", entry) }
            number += 1
            return ("\(number).", entry)
        }
    }

    private func legendRow(_ color: Color, _ text: String, dashed: Bool = false) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(dashed ? .clear : color)
                .strokeBorder(color, style: StrokeStyle(lineWidth: dashed ? 1 : 0, dash: [2, 2]))
                .frame(width: 12, height: 12)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.textPrimary)
        }
    }
}

#Preview {
    GameHUDView(game: PhotonGame(), openTutorial: {})
        .background(Color.gridUIBackground)
}
