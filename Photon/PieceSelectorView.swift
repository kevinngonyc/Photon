//
//  PiecesView.swift
//  Photon
//
//  Created by Kevin Ngo on 8/5/26.
//

import SwiftUI

let num_pieces = 9

struct PieceSelectorView: View {
    @Binding var selectedPiece: Int
    /// A button to point the player at (the tutorial's), until they pick it.
    var pointedPiece: Int? = nil
    /// While a source is being placed, that's the only piece there is: the label says so and
    /// the piece buttons are off.
    var placesSource = false

    private func isSelected(_ index: Int) -> Bool {
        !placesSource && selectedPiece == index
    }

    private func isPointed(_ index: Int) -> Bool {
        pointedPiece == index && !isSelected(index)
    }

    var body: some View {
        VStack(spacing: 8) {
            Group {
                switch placesSource ? -1 : selectedPiece {
                case -1:
                    Text("Source")
                case 1:
                    Text("Mirror")
                case 2:
                    Text("Mirror")
                case 3:
                    Text("Prism")
                case 4:
                    Text("Chamber")
                case 5:
                    Text("Laser")
                case 6:
                    Text("Diffuser")
                case 7:
                    Text("Diffuser")
                case 8:
                    Text("Diffuser")
                case 9:
                    Text("Diffuser")
                default:
                    Text("None Selected")
                        .foregroundStyle(Color.textMuted)
                }
            }
                
                    .foregroundStyle(Color.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(.gridUIElevated), in: RoundedRectangle(cornerRadius: 25.0))
                    
                    
            
            VStack(spacing: 4) {
                HStack(spacing: 16) {
                    ForEach(1...5, id: \.self) { index in
                        switch index {
                        case 1:
                            Button(action: {
                                selectedPiece = selectedPiece == index ? 0 : index
                            }) {
                                Image(systemName: "line.diagonal")
                                    
                                    .scaleEffect(x: -1, y: 1)
                                    .font(.title)
                            }
                            .padding(16)
                            .glassEffect(isSelected(index) ? .regular.tint(.gridUIHighlight) : .identity, in: RoundedRectangle(cornerRadius: 16.0))
                            .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [])
                            .beacon(isPointed(index))
                            
                            
                        case 2:
                            Button(action: {
                                selectedPiece = selectedPiece == index ? 0 : index
                            }) {
                                    Image(systemName: "line.diagonal")
                                        .font(.title)
                            }
                            .padding(16)
                            .glassEffect(isSelected(index) ? .regular.tint(.gridUIHighlight) : .identity, in: RoundedRectangle(cornerRadius: 16.0))
                            .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [])
                            .beacon(isPointed(index))
                            
                        case 3:
                            Button(action: {
                                selectedPiece = selectedPiece == index ? 0 : index
                            }) {
                                    Image(systemName: "triangle")
                                        .font(.title)
                            }
                            .padding(16)
                            .glassEffect(isSelected(index) ? .regular.tint(.gridUIHighlight) : .identity, in: RoundedRectangle(cornerRadius: 16.0))
                            .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [])
                            .beacon(isPointed(index))
                            
                        case 4:
                            Button(action: {
                                selectedPiece = selectedPiece == index ? 0 : index
                            }) {
                                    Image(systemName: "square")
                                        .font(.title)
                            }
                            .padding(16)
                            .glassEffect(isSelected(index) ? .regular.tint(.gridUIHighlight) : .identity, in: RoundedRectangle(cornerRadius: 16.0))
                            .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [])
                            .beacon(isPointed(index))
                            
                        case 5:
                            
                            Button(action: {
                                selectedPiece = selectedPiece == index ? 0 : index
                            }) {
                                    Image(systemName: "rhombus")
                                        .font(.title)
                            }
                            .padding(16)
                            .glassEffect(isSelected(index) ? .regular.tint(.gridUIHighlight) : .identity, in: RoundedRectangle(cornerRadius: 16.0))
                            .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [])
                            .beacon(isPointed(index))
                            
                        default:
                            Text("Placeholder")
                        }
                    }
                }
                    
                    HStack(spacing: 16) {
                        ForEach(6...9, id: \.self) { index in
                            switch index {
                                
                            case 6:
                                
                                Button(action: {
                                    selectedPiece = selectedPiece == index ? 0 : index
                                }) {
                                        DiffuserShape()
                                            .frame(width: 24, height: 24)
                                }
                                .padding(16)
                                .glassEffect(isSelected(index) ? .regular.tint(.gridUIHighlight) : .identity, in: RoundedRectangle(cornerRadius: 16.0))
                                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [])
                                .beacon(isPointed(index))
                                
                            case 7:
                                
                                Button(action: {
                                    selectedPiece = selectedPiece == index ? 0 : index
                                }) {
                                        DiffuserShape()
                                            .frame(width: 24, height: 24)
                                            .rotationEffect(.degrees(180))
                                    
                                }
                                .padding(16)
                                .glassEffect(isSelected(index) ? .regular.tint(.gridUIHighlight) : .identity, in: RoundedRectangle(cornerRadius: 16.0))
                                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [])
                                .beacon(isPointed(index))
                                
                            case 8:
                                
                                Button(action: {
                                    selectedPiece = selectedPiece == index ? 0 : index
                                }) {
                                        DiffuserShape()
                                            .frame(width: 24, height: 24)
                                            .rotationEffect(.degrees(90))
                                }
                                .padding(16)
                                .glassEffect(isSelected(index) ? .regular.tint(.gridUIHighlight) : .identity, in: RoundedRectangle(cornerRadius: 16.0))
                                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [])
                                .beacon(isPointed(index))
                                
                            case 9:
                                
                                Button(action: {
                                    selectedPiece = selectedPiece == index ? 0 : index
                                }) {
                                        DiffuserShape()
                                            .frame(width: 24, height: 24)
                                            .rotationEffect(.degrees(270))
                                }
                                .padding(16)
                                .glassEffect(isSelected(index) ? .regular.tint(.gridUIHighlight) : .identity, in: RoundedRectangle(cornerRadius: 16.0))
                                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [])
                                .beacon(isPointed(index))
                                
                                
                            default:
                                Text("Placeholder")
                            }
                        }
                            
                    }
            }
            .disabled(placesSource)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity) // Expands layout to fill screen
            .background(
                LinearGradient(
                    colors: [Color.gridUIBackground, Color.gridUIElevated],
                    startPoint: .top,
                    endPoint: .bottom
                ))                                // Sets background color
            .ignoresSafeArea()
            .tint(Color.textPrimary)
            
        }
    }
}

private extension View {
    /// A pulsing outline around a piece button.
    func beacon(_ isOn: Bool) -> some View {
        overlay {
            if isOn {
                RoundedRectangle(cornerRadius: 16.0)
                    .strokeBorder(Color.gridCyanBlue, lineWidth: 2)
                    .phaseAnimator([false, true]) { outline, lit in
                        outline.opacity(lit ? 1 : 0.2)
                    } animation: { _ in .easeInOut(duration: 0.7) }
                    .allowsHitTesting(false)
            }
        }
    }
}

#Preview {
    PieceSelectorView(selectedPiece: .constant(0), pointedPiece: 3)
}
