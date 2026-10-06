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

    /// The piece selector's label rides up over the bottom of the board area.
    private let selectorOverlap: CGFloat = 54
    /// Space between the HUD row and the top of the board.
    private let hudGap: CGFloat = 32

    var body: some View {
        VStack(spacing: -selectorOverlap) {
            BoardView(game: game, bottomOverlap: selectorOverlap, headerHeight: GameHUDView.height + hudGap) {
                GameHUDView(game: game)
                    .padding(.bottom, hudGap)
            }
            PieceSelectorView(selectedPiece: $game.selectedPiece)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // Expands layout to fill screen
        .background(Color.gridUIBackground)                                // Sets background color
        .ignoresSafeArea(edges: .bottom)
        .onAppear { game.online.authenticate() }
        // Turns taken while the app was in the background arrive here.
        .onChange(of: scenePhase) { if scenePhase == .active { game.online.refresh() } }
    }
}

#Preview {
    ContentView()
}

