import SwiftUI
import ChessCore
import ChessEngine

struct NewGameSheet: View {
    let model: GameModel
    @Environment(\.dismiss) private var dismiss

    enum PlayAs: String, CaseIterable { case white = "White", black = "Black", random = "Random" }

    @State private var mode: GameMode
    @State private var playAs: PlayAs
    @State private var difficulty: Difficulty

    init(model: GameModel) {
        self.model = model
        _mode = State(initialValue: model.mode)
        _playAs = State(initialValue: model.humanColor == .white ? .white : .black)
        _difficulty = State(initialValue: model.difficulty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New game").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Mode")
                Picker("Mode", selection: $mode) {
                    Text("Two players").tag(GameMode.twoPlayers)
                    Text("Versus computer").tag(GameMode.versusComputer)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if mode == .versusComputer {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Play as")
                    Picker("Play as", selection: $playAs) {
                        ForEach(PlayAs.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Difficulty")
                    Picker("Difficulty", selection: $difficulty) {
                        ForEach(Difficulty.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start game") {
                    let color: PieceColor
                    switch playAs {
                    case .white: color = .white
                    case .black: color = .black
                    case .random: color = Bool.random() ? .white : .black
                    }
                    model.newGame(mode: mode, humanColor: color, difficulty: difficulty)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
