//
//  ContentView.swift
//  Photon
//
//  Created by Kevin Ngo on 8/4/26.
//

import SwiftUI

struct ContentView: View {
    @State private var game = PhotonGame()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Tutorial.completedKey) private var hasCompletedTutorial = false
    @AppStorage(Tutorial.declinedKey) private var hasDeclinedTutorial = false
    /// Until players finish the tutorial or turn it down, they're offered it once each launch.
    @State private var hasOfferedTutorial = false
    @State private var offersTutorial = false
    @State private var showsTutorial = false

    /// The piece selector's label rides up over the bottom of the board area.
    private let selectorOverlap: CGFloat = 54
    /// Space between the HUD row and the top of the board.
    private let hudGap: CGFloat = 32

    var body: some View {
        VStack(spacing: -selectorOverlap) {
            BoardView(model: game, bottomOverlap: selectorOverlap, headerHeight: GameHUDView.height + hudGap) {
                GameHUDView(game: game, openTutorial: { showsTutorial = true })
                    .padding(.bottom, hudGap)
            }
            PieceSelectorView(selectedPiece: $game.selectedPiece, placesSource: game.phase == .setup)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // Expands layout to fill screen
        .background(Color.gridUIBackground)                                // Sets background color
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            game.online.authenticate()
            // The full-screen tutorial brings this back into view when it closes, so check
            // that it hasn't been offered already.
            if !hasOfferedTutorial && !hasCompletedTutorial && !hasDeclinedTutorial { offersTutorial = true }
            hasOfferedTutorial = true
        }
        // Turns taken while the app was in the background arrive here.
        .onChange(of: scenePhase) { if scenePhase == .active { game.online.refresh() } }
        .alert("Welcome to Photon", isPresented: $offersTutorial) {
            Button("Start Tutorial") { showsTutorial = true }
                .keyboardShortcut(.defaultAction)
            Button("No Thanks", role: .cancel) { hasDeclinedTutorial = true }
        } message: {
            Text("Learn to play in a few quick, hands-on lessons. You can also find the tutorial in the menu.")
        }
        .fullScreenCover(isPresented: $showsTutorial) {
            TutorialView()
        }
    }
}

#Preview {
    ContentView()
}

