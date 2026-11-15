import SwiftUI

struct GameOverCard: View {
    let model: GameModel

    var body: some View {
        VStack(spacing: 14) {
            Text(model.resultText ?? "")
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("New game") { model.showingNewGame = true }
                    .keyboardShortcut(.defaultAction)
                Button("View board") { model.gameOverDismissed = true }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
    }
}
