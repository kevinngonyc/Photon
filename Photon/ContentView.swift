//
//  ContentView.swift
//  Photon
//
//  Created by Kevin Ngo on 8/4/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: -54) {
            BoardView()
            PieceSelectorView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // Expands layout to fill screen
        .background(Color.gridUIBackground)                                // Sets background color
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}

