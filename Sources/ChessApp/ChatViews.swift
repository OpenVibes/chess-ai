import SwiftUI
import ChessCore
import ChessCoach

// MARK: - Avatar

/// A round face for a player. The AI model's face follows its mood; a small dot shows the colour it plays.
struct PlayerAvatar: View {
    let model: GameModel
    let color: PieceColor
    var size: CGFloat = 30

    private enum Kind { case human, aiModel, computer, seat }

    private var kind: Kind {
        switch model.mode {
        case .twoPlayers: return .seat
        case .versusComputer: return color == model.humanColor ? .human : .computer
        case .versusModel: return color == model.humanColor ? .human : .aiModel
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(background)
            face
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if size >= 26 { colorDot }
        }
        .accessibilityLabel(color == .white ? "Plays White" : "Plays Black")
    }

    private var colorDot: some View {
            Circle()
                .fill(color == .white ? Color.white : Color.black)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1))
                .frame(width: size * 0.34, height: size * 0.34)
                .offset(x: 2, y: 2)
    }

    private var background: LinearGradient {
        let base: Color
        switch kind {
        case .human: base = .accentColor
        case .aiModel: base = Self.providerColor(model.coach.settings.selectedPresetID)
        case .computer: base = Color(white: 0.45)
        case .seat: base = color == .white ? Color(white: 0.85) : Color(white: 0.25)
        }
        return LinearGradient(colors: [base.opacity(0.75), base], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @ViewBuilder
    private var face: some View {
        switch kind {
        case .human:
            Image(systemName: "person.fill").font(.system(size: size * 0.5)).foregroundStyle(.white)
        case .computer:
            Image(systemName: "cpu").font(.system(size: size * 0.5)).foregroundStyle(.white)
        case .seat:
            Text(color == .white ? "\u{2654}" : "\u{265A}")
                .font(.system(size: size * 0.6))
                .foregroundStyle(color == .white ? Color.black : Color.white)
        case .aiModel:
            Text(Self.emoji(for: displayedMood))
                .font(.system(size: size * 0.6))
        }
    }

    /// The face to show: thinking while it chooses a move, the result when the game is over, otherwise its mood.
    private var displayedMood: String {
        switch model.game.status {
        case .ongoing: break
        case .checkmate(let winner): return winner == color ? "won" : "lost"
        default: return "draw"
        }
        if model.isThinking || model.chatPending > 0 { return OpponentMood.thinking.rawValue }
        return model.mood.rawValue
    }

    static func emoji(for mood: String) -> String {
        switch mood {
        case "confident": return "\u{1F60F}"   // smirk
        case "impressed": return "\u{1F62E}"   // open mouth
        case "amused": return "\u{1F604}"      // grin
        case "nervous": return "\u{1F62C}"     // grimace
        case "thinking": return "\u{1F914}"
        case "won": return "\u{1F60E}"         // sunglasses
        case "lost": return "\u{1F635}"        // dizzy
        case "draw": return "\u{1F91D}"        // handshake
        default: return "\u{1F642}"            // slight smile
        }
    }

    static func providerColor(_ id: String) -> Color {
        switch id {
        case "claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
        case "openai": return Color(red: 0.20, green: 0.62, blue: 0.52)
        case "gemini": return Color(red: 0.26, green: 0.47, blue: 0.93)
        case "openrouter": return Color(red: 0.42, green: 0.36, blue: 0.86)
        case "ollama": return Color(red: 0.45, green: 0.48, blue: 0.55)
        default: return Color(red: 0.62, green: 0.38, blue: 0.80)
        }
    }
}

// MARK: - Turn badge

/// "Your move" or "Thinking…" next to the player whose turn it is.
struct TurnBadge: View {
    let model: GameModel
    let color: PieceColor

    var body: some View {
        if !model.isGameOver, model.sideToMove == color {
            let mine = !model.hasNonHumanOpponent || color == model.humanColor
            HStack(spacing: 4) {
                if mine {
                    Text(model.game.position.isInCheck ? "Check!" : (model.hasNonHumanOpponent ? "Your move" : "To move"))
                } else {
                    Text(model.isThinking ? "Thinking" : "To move")
                    if model.isThinking { TypingDots(size: 3.5, color: .white) }
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(model.game.position.isInCheck ? Color.red : (mine ? Color.accentColor : Color.secondary)))
            .fixedSize()
        }
    }
}

/// Three dots that pulse one after another.
struct TypingDots: View {
    var size: CGFloat = 6
    var color: Color = .secondary

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.6) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (sin((t * 5) - Double(i) * 0.9) + 1) / 2
                    Circle().fill(color).frame(width: size, height: size).opacity(0.35 + 0.65 * phase)
                }
            }
        }
    }
}

// MARK: - Chat panel

struct ChatPanel: View {
    let model: GameModel
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var typing: Bool { model.isThinking || model.chatPending > 0 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.chat) { entry in
                            row(entry).id(entry.id)
                        }
                        if typing {
                            HStack(alignment: .bottom, spacing: 6) {
                                PlayerAvatar(model: model, color: model.humanColor.opposite, size: 22)
                                TypingDots()
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .background(BubbleShape(mine: false).fill(Color.primary.opacity(0.08)))
                                Spacer(minLength: 0)
                            }
                            .id("typing")
                        }
                        if let message = model.opponentMessage { opponentBanner(message).id("banner") }
                    }
                    .padding(10)
                }
                .onChange(of: model.chat.count) { scrollToEnd(proxy) }
                .onChange(of: typing) { scrollToEnd(proxy) }
                .onChange(of: model.opponentMessage) { scrollToEnd(proxy) }
                .onAppear { scrollToEnd(proxy, animated: false) }
            }
            Divider()
            HStack(spacing: 6) {
                TextField("Say something\u{2026}", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Send")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func send() {
        let text = draft
        draft = ""
        model.sendChat(text)
        focused = true
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let target: AnyHashable? = model.opponentMessage != nil ? "banner" : (typing ? "typing" : model.chat.last.map { AnyHashable($0.id) })
        guard let target else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .bottom) }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    @ViewBuilder
    private func row(_ entry: ChatEntry) -> some View {
        switch entry.kind {
        case .opponent(let text, let move):
            HStack(alignment: .bottom, spacing: 6) {
                PlayerAvatar(model: model, color: model.humanColor.opposite, size: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(BubbleShape(mine: false).fill(Color.primary.opacity(0.08)))
                    if let move {
                        Text("played \(move)").font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 4)
                    }
                }
                Spacer(minLength: 24)
            }
        case .human(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(BubbleShape(mine: true).fill(Color.accentColor))
            }
        case .humanMove(let ply, let label):
            moveChip(prefix: "You played", label: label, review: model.coach.enabled ? model.coach.reviews[ply] : nil)
        case .opponentMove(let label):
            moveChip(prefix: "\(model.modelName) played", label: label, review: nil)
        case .note(let text):
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private func moveChip(prefix: String, label: String, review: MoveReview?) -> some View {
        HStack(spacing: 5) {
            Text(prefix).foregroundStyle(.secondary)
            Text(label).fontWeight(.semibold)
            if let review {
                Circle().fill(review.quality.color).frame(width: 7, height: 7)
                Text(review.quality.displayName).foregroundStyle(review.quality.color)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func opponentBanner(_ message: OpponentMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message {
            case .notice(let text):
                Text(text)
            case .error(let text):
                Text(text).lineLimit(3)
                HStack(spacing: 12) {
                    Button("Try again") { model.retryModelTurn() }
                    Button("Let the engine move") { model.letEngineMove() }
                }
                .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
            }
        }
        .font(.system(size: 12))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
    }
}

/// A rounded bubble with a smaller corner on the speaker's side.
struct BubbleShape: Shape {
    let mine: Bool

    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 12, small: CGFloat = 4
        return Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
            topLeading: big,
            bottomLeading: mine ? big : small,
            bottomTrailing: mine ? small : big,
            topTrailing: big))
    }
}
