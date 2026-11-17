import SwiftUI
import ChessCore
import ChessCoach

struct SidebarView: View {
    let model: GameModel

    enum Panel: Hashable { case chat, coach }
    @State private var panel: Panel = .chat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlayerStrip(model: model, color: model.topColor)
            Text(model.statusText)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.8)
            if model.mode == .versusModel { ThinkingPicker(model: model) }
            if model.chatActive {
                MoveList(model: model)
                    .frame(height: 96)
                Picker("Panel", selection: $panel) {
                    Text("Chat").tag(Panel.chat)
                    Text("Coach").tag(Panel.coach)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if panel == .chat {
                    ChatPanel(model: model)
                } else {
                    CoachCard(model: model, flexible: true)
                }
            } else {
                MoveList(model: model)
                if model.coach.enabled || model.opponentMessage != nil { CoachCard(model: model) }
            }
            PlayerStrip(model: model, color: model.bottomColor)
            HStack(spacing: 8) {
                Button { model.showingNewGame = true } label: {
                    Text("New game").lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                }
                Button { model.undo() } label: {
                    Text("Undo").lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                }
                .disabled(!model.canUndo)
                Button { model.flipBoard() } label: {
                    Text("Flip board").lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: model.chatActive ? 320 : 280)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        // A hint is shown in the coach panel, so switch to it.
        .onChange(of: model.coach.hint != nil) { _, shown in if shown { panel = .coach } }
    }
}

/// Fast / Normal / Deep for the AI model. Works mid-game: a move being thought about starts again at the new pace.
private struct ThinkingPicker: View {
    let model: GameModel

    var body: some View {
        let level = model.coach.settings.opponentThinking
        HStack(spacing: 8) {
            Image(systemName: level == .fast ? "hare" : (level == .deep ? "brain" : "gauge.with.dots.needle.50percent"))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Picker("Thinking", selection: Binding(get: { level }, set: { model.setOpponentThinking($0) })) {
                ForEach(ThinkingLevel.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .help("How long \(model.modelName) may think. \(level.summary) You can change it at any time.")
    }
}

private struct PlayerStrip: View {
    let model: GameModel
    let color: PieceColor

    private var active: Bool { !model.isGameOver && model.sideToMove == color }
    private var isComputer: Bool { model.mode == .versusComputer && color != model.humanColor }
    private var name: String { isComputer ? "Computer" : model.playerName(color) }
    private var subtitle: String {
        let plays = color == .white ? "Plays White" : "Plays Black"
        return isComputer ? "\(model.difficulty.rawValue.capitalized) · \(plays)" : plays
    }

    private static func solidGlyph(_ kind: PieceKind) -> String {
        switch kind {
        case .king: return "\u{265A}"
        case .queen: return "\u{265B}"
        case .rook: return "\u{265C}"
        case .bishop: return "\u{265D}"
        case .knight: return "\u{265E}"
        case .pawn: return "\u{265F}"
        }
    }

    var body: some View {
        let lead = model.lead(color)
        HStack(spacing: 10) {
            PlayerAvatar(model: model, color: color, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    TurnBadge(model: model, color: color)
                    if lead > 0 {
                        Text("+\(lead)")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: -4) {
                    ForEach(Array(model.capturedPieces(by: color).enumerated()), id: \.offset) { _, p in
                        Text(Self.solidGlyph(p.kind) + "\u{FE0E}")
                            .font(.custom("Apple Symbols", size: 16))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: 14, height: 18)
                    }
                    if model.capturedPieces(by: color).isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 18)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(active ? Color.accentColor.opacity(0.12) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor.opacity(active ? 0.55 : 0), lineWidth: 1.5))
        .animation(.easeOut(duration: 0.2), value: active)
    }
}

private struct MoveList: View {
    let model: GameModel

    var body: some View {
        let history = model.game.history
        let rowCount = (history.count + 1) / 2
        ScrollViewReader { proxy in
            ScrollView {
                if history.isEmpty {
                    Text("Moves appear here.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<rowCount, id: \.self) { row in
                            HStack(spacing: 0) {
                                Text("\(row + 1).")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                                    .padding(.trailing, 8)
                                cell(index: row * 2, history: history)
                                cell(index: row * 2 + 1, history: history)
                            }
                            .font(.system(size: 13).monospacedDigit())
                            .padding(.vertical, 2)
                            .id(row)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .onChange(of: history.count) {
                if rowCount > 0 {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(rowCount - 1, anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func cellText(_ san: String, mark: (text: String, quality: MoveQuality)?) -> Text {
        guard let mark else { return Text(san) }
        return Text(san) + Text(mark.text).foregroundColor(mark.quality.color)
    }

    @ViewBuilder
    private func cell(index: Int, history: [MoveRecord]) -> some View {
        if index < history.count {
            let latest = index == history.count - 1
            let mark = model.coach.mark(ply: index)
            let inspected = model.coach.enabled && model.coach.inspectedPly == index
            cellText(history[index].san, mark: mark)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(latest ? Color.accentColor.opacity(0.28) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 1)
                    .opacity(inspected ? 1 : 0))
                .contentShape(Rectangle())
                .onTapGesture { if mark != nil || model.coach.reviews[index] != nil { model.coach.inspect(ply: index) } }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
        }
    }
}
