//
//  TutorialView.swift
//  Photon
//
//  The tutorial's screen: a card with the step's lesson, over a board and piece selector laid
//  out like the game's.
//

import SwiftUI

struct TutorialView: View {
    @State private var tutorial = Tutorial()
    @AppStorage(Tutorial.completedKey) private var hasCompleted = false
    @Environment(\.dismiss) private var dismiss

    /// The card's border flashes red on a tap that doesn't count, green on a goal met.
    @State private var flashColor = Color.gridRed
    @State private var flashing = false
    /// The board fades out and back in when a step swaps it for a new position.
    @State private var boardOpacity = 1.0

    /// As in ContentView: the piece selector's label rides up over the bottom of the board area.
    private let selectorOverlap: CGFloat = 54

    var body: some View {
        VStack(spacing: 12) {
            card
                .padding(.horizontal, 16)
            VStack(spacing: -selectorOverlap) {
                BoardView(model: tutorial, bottomOverlap: selectorOverlap)
                    .opacity(boardOpacity)
                PieceSelectorView(selectedPiece: $tutorial.selectedPiece, pointedPiece: tutorial.pointedButton,
                                  placesSource: tutorial.placesSource)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gridUIBackground)
        .ignoresSafeArea(edges: .bottom)
        .preferredColorScheme(.dark)
        .sensoryFeedback(.error, trigger: tutorial.misses)
        .sensoryFeedback(.success, trigger: tutorial.hits)
        .onChange(of: tutorial.misses) { flash(.gridRed) }
        .onChange(of: tutorial.hits) { flash(.gridGreen) }
        // Getting to the end is what counts as having done the tutorial.
        .onChange(of: tutorial.isLastStep) { if tutorial.isLastStep { hasCompleted = true } }
    }

    private var card: some View {
        let step = tutorial.step
        return VStack(alignment: .leading, spacing: 8) {
            progress
            HStack(spacing: 12) {
                Text(step.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: 0)
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Close Tutorial")
                .foregroundStyle(Color.textSecondary)
                .glassEffect(.regular.tint(.gridUIHighlight).interactive(), in: Circle())
            }
            // As tall as the tutorial's longest text, so the board below doesn't shift between steps.
            ZStack(alignment: .topLeading) {
                ForEach(tutorial.steps.indices, id: \.self) { i in
                    lesson(tutorial.steps[i].text, done: false).hidden()
                    lesson(tutorial.steps[i].done, done: true).hidden()
                }
                let showsDone = tutorial.isDone && step.goal != nil
                lesson(showsDone ? step.done : step.text, done: showsDone)
            }
            .font(.subheadline)
            .foregroundStyle(Color.textPrimary)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: 560)
        .glassEffect(.regular.tint(.gridUIElevated), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(flashColor, lineWidth: 1.5)
                .opacity(flashing ? 1 : 0)
        }
    }

    /// A step's text, or what it says once its move is made, marked with a check.
    @ViewBuilder
    private func lesson(_ text: String, done: Bool) -> some View {
        if done {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.gridGreen)
                Text(text)
            }
        } else {
            Text(text)
        }
    }

    private var progress: some View {
        HStack(spacing: 4) {
            ForEach(tutorial.steps.indices, id: \.self) { i in
                Capsule()
                    .fill(i <= tutorial.index ? Color.gridCyanBlue : Color.textMuted.opacity(0.45))
                    .frame(height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(tutorial.index + 1) of \(tutorial.steps.count)")
    }

    /// Back, then a hint while the step's move hasn't been made, or the way on once it has.
    private var footer: some View {
        HStack(spacing: 10) {
            if tutorial.index > 0 {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Back")
                .foregroundStyle(Color.textPrimary)
                .glassEffect(.regular.tint(.gridUIHighlight).interactive(), in: Circle())
            }
            if let hint = tutorial.hint {
                Text(hint)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.gridRed)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            if tutorial.isDone {
                Button(action: next) {
                    HStack(spacing: 4) {
                        Text(tutorial.isLastStep ? "Start Playing" : "Next")
                        Image(systemName: tutorial.isLastStep ? "play.fill" : "chevron.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.gridUIBackground)
                    .padding(.horizontal, 18)
                    .frame(height: 36)
                }
                .glassEffect(.regular.tint(.gridCyanBlue).interactive(), in: Capsule())
            }
        }
        .frame(height: 36)
    }

    private func next() {
        if tutorial.isLastStep { return dismiss() }
        change(fading: tutorial.nextStepHasNewBoard) { tutorial.advance() }
    }

    private func back() {
        change(fading: true) { tutorial.goBack() }
    }

    /// Moves between steps, fading the board out first when it's about to be swapped.
    private func change(fading: Bool, _ update: @escaping () -> Void) {
        guard fading else { return withAnimation(.snappy) { update() } }
        withAnimation(.easeIn(duration: 0.15)) {
            boardOpacity = 0
        } completion: {
            withAnimation(.snappy) { update() }
            withAnimation(.easeOut(duration: 0.25)) { boardOpacity = 1 }
        }
    }

    private func flash(_ color: Color) {
        flashColor = color
        flashing = true
        withAnimation(.easeOut(duration: 0.26).delay(0.26)) { flashing = false }
    }
}

#Preview {
    TutorialView()
}
