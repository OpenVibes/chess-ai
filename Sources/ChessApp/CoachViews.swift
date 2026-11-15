import SwiftUI
import ChessCore
import ChessCoach

extension MoveQuality {
    /// Same in light and dark.
    var color: Color {
        switch self {
        case .best, .excellent: return Color(red: 0x5B / 255, green: 0x8C / 255, blue: 0x3A / 255)
        case .good: return Color(red: 0x7A / 255, green: 0x9A / 255, blue: 0x6A / 255)
        case .inaccuracy: return Color(red: 0xE0 / 255, green: 0xA5 / 255, blue: 0x26 / 255)
        case .mistake: return Color(red: 0xE0 / 255, green: 0x7B / 255, blue: 0x26 / 255)
        case .blunder: return Color(red: 0xD6 / 255, green: 0x45 / 255, blue: 0x45 / 255)
        }
    }
}

extension Palette {
    static let arrow = Color(red: 0x5B / 255, green: 0x8C / 255, blue: 0x3A / 255).opacity(0.8)
}

// MARK: - Evaluation bar

struct EvalBar: View {
    let model: GameModel
    let height: CGFloat

    var body: some View {
        let share = model.coach.whiteShare
        let whiteOnBottom = model.whiteAtBottom
        ZStack(alignment: whiteOnBottom ? .bottom : .top) {
            Palette.ink
            Palette.paper
                .frame(height: height * share)
        }
        .frame(width: 10, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .animation(.easeInOut(duration: 0.3), value: share)
        .animation(.easeInOut(duration: 0.3), value: whiteOnBottom)
        .allowsHitTesting(false)
        .accessibilityLabel("Evaluation bar")
    }
}

// MARK: - Arrow

/// An arrow between two square centres: shaft 0.16 × square wide, triangular head 0.42 × square wide.
struct ArrowShape: Shape {
    let from: CGPoint
    let to: CGPoint
    let square: CGFloat

    func path(in rect: CGRect) -> Path {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 0 else { return Path() }
        let ux = dx / length, uy = dy / length
        let px = -uy, py = ux
        let shaftHalf = square * 0.16 / 2
        let headHalf = square * 0.42 / 2
        let headLength = min(square * 0.42, length)
        let baseX = to.x - ux * headLength, baseY = to.y - uy * headLength
        var p = Path()
        p.move(to: CGPoint(x: from.x + px * shaftHalf, y: from.y + py * shaftHalf))
        p.addLine(to: CGPoint(x: baseX + px * shaftHalf, y: baseY + py * shaftHalf))
        p.addLine(to: CGPoint(x: baseX + px * headHalf, y: baseY + py * headHalf))
        p.addLine(to: to)
        p.addLine(to: CGPoint(x: baseX - px * headHalf, y: baseY - py * headHalf))
        p.addLine(to: CGPoint(x: baseX - px * shaftHalf, y: baseY - py * shaftHalf))
        p.addLine(to: CGPoint(x: from.x - px * shaftHalf, y: from.y - py * shaftHalf))
        p.closeSubpath()
        return p
    }
}

// MARK: - Coach card

struct CoachCard: View {
    let model: GameModel

    private enum Content {
        case empty
        case opponent(OpponentMessage)
        case hint(HintInfo)
        case review(ply: Int, review: MoveReview, ai: AIText)
    }

    private var content: Content {
        let coach = model.coach
        if let message = model.opponentMessage { return .opponent(message) }
        if let hint = coach.hint { return .hint(hint) }
        if let ply = coach.displayedPly, let review = coach.reviews[ply] {
            return .review(ply: ply, review: review, ai: coach.explanations[ply] ?? .none)
        }
        return .empty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            bodyText
            footer
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 132)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            switch content {
            case .empty:
                Text("Coach").font(.system(size: 13, weight: .semibold))
            case .opponent:
                Text("Opponent").font(.system(size: 13, weight: .semibold))
            case .hint:
                Text("Hint").font(.system(size: 13, weight: .semibold))
            case .review(let ply, let review, _):
                Circle().fill(review.quality.color).frame(width: 9, height: 9)
                Text(review.quality.displayName).font(.system(size: 13, weight: .semibold))
                Text("\(ply / 2 + 1)\(ply % 2 == 0 ? "." : "\u{2026}") \(review.san)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.canHint {
                Button { model.requestHint() } label: { Image(systemName: "lightbulb") }
                    .buttonStyle(.borderless)
                    .help("Hint")
            }
        }
        .frame(height: 18)
    }

    private var bodyText: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                switch content {
                case .empty:
                    Text("Play a move and I will tell you how good it was.")
                case .opponent(let message):
                    switch message {
                    case .notice(let text): Text(text)
                    case .error(let text): Text(text).lineLimit(2).truncationMode(.tail)
                    }
                case .hint(let hint):
                    Text("Try \(hint.san).")
                    aiLines(hint.ai)
                case .review(_, let review, let ai):
                    Text(review.summary)
                    aiLines(ai)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func aiLines(_ ai: AIText) -> some View {
        switch ai {
        case .none:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text("Asking the model\u{2026}").foregroundStyle(.secondary)
            }
        case .text(let text):
            Text(text)
        case .failed(let message):
            Text(message).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if case .opponent(.error) = content {
            HStack(spacing: 12) {
                Button("Try again") { model.retryModelTurn() }
                Button("Let the engine move") { model.letEngineMove() }
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
            .font(.system(size: 12))
            .frame(height: 16)
        } else
        if case .review(let ply, let review, _) = content, review.quality.isBad, let best = review.bestSAN {
            if ply == model.game.history.count - 1, review.bestMove != nil {
                Button("Show better move") { model.coach.showBetterMove(ply: ply) }
                    .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
                    .font(.system(size: 12))
                    .frame(height: 16)
            } else {
                Text("Better: \(best)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(height: 16)
            }
        }
    }
}
