import Foundation
import ChessCore
import ChessEngine

public enum CoachPrompts {
    public static let coachSystem = """
    You are a friendly chess coach talking to a learner. You are given facts that a chess engine has already worked out: \
    the position, the move played, the engine's verdict and the better move. Do not judge the move yourself and do not \
    change the verdict. Explain in plain words why the verdict makes sense. Reply with at most two short sentences. \
    Do not use evaluation numbers or scores. Only mention moves that appear in the facts; do not invent other moves or lines. \
    Reply with the explanation only, with no greeting and no formatting.
    """

    public static func explainMove(review: MoveReview, positionBefore: Position, recentSAN: [String]) -> String {
        var lines: [String] = []
        lines.append("Position before the move (FEN): \(positionBefore.fen)")
        lines.append("\(name(review.mover)) played \(review.san).")
        if !recentSAN.isEmpty { lines.append("Recent moves: \(recentSAN.joined(separator: " "))") }
        lines.append("The engine's verdict on the move: \(review.quality.rawValue).")
        if let best = review.bestSAN, best != review.san {
            lines.append("The engine's preferred move was \(best).")
        } else if review.bestSAN != nil {
            lines.append("This was the engine's preferred move.")
        }
        if !review.bestLine.isEmpty { lines.append("The engine's line: \(review.bestLine.joined(separator: " "))") }
        lines.append("Before the move: \(describe(review.scoreBefore)).")
        lines.append("After the move: \(describe(review.scoreAfter)).")
        lines.append("Explain to a learner, in at most two short sentences, why the move got this verdict. Do not use evaluation numbers and do not mention any move other than those given above.")
        return lines.joined(separator: "\n")
    }

    public static func explainHint(position: Position, bestSAN: String, line: [String], recentSAN: [String]) -> String {
        var lines: [String] = []
        lines.append("Position (FEN): \(position.fen)")
        lines.append("\(name(position.sideToMove)) is to move.")
        if !recentSAN.isEmpty { lines.append("Recent moves: \(recentSAN.joined(separator: " "))") }
        lines.append("The engine recommends \(bestSAN).")
        if !line.isEmpty { lines.append("The engine's line: \(line.joined(separator: " "))") }
        lines.append("Explain to a learner, in at most two short sentences, the idea behind \(bestSAN). Do not use evaluation numbers and do not mention any move other than those given above.")
        return lines.joined(separator: "\n")
    }

    public static let opponentSystem = """
    You are playing a game of chess. You will be given the position as a FEN string, the side you play, the moves so far \
    and the complete list of legal moves in standard algebraic notation (SAN). Choose one move from the list of legal moves. \
    You may reason briefly, but the last line of your reply must be exactly `MOVE: <san>`, with the move copied from the list.
    """

    public static func opponentTurn(game: Game) -> String {
        let position = game.position
        var lines: [String] = []
        lines.append("Position (FEN): \(position.fen)")
        lines.append("Side to move: \(name(position.sideToMove)). You play \(name(position.sideToMove)).")
        lines.append("Moves so far: \(moveList(game))")
        let legal = position.legalMoves().map { san(for: $0, in: position) }
        lines.append("Legal moves: \(legal.joined(separator: " "))")
        lines.append("Choose one legal move. End your reply with a final line `MOVE: <san>`.")
        return lines.joined(separator: "\n")
    }

    public static func opponentRetry(rejected: String, legalSAN: [String]) -> String {
        let shown = rejected.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        That reply did not contain a legal move (\(shown.isEmpty ? "empty" : "I read: \(String(shown.prefix(60)))")). \
        Legal moves: \(legalSAN.joined(separator: " "))
        Choose one of them. End your reply with a final line `MOVE: <san>`.
        """
    }

    // MARK: helpers

    private static func name(_ color: PieceColor) -> String { color == .white ? "White" : "Black" }

    private static func moveList(_ game: Game) -> String {
        guard let first = game.history.first else { return "none (the game has just started)" }
        var number = first.positionBefore.fullmoveNumber
        var white = first.positionBefore.sideToMove == .white
        var parts: [String] = []
        for (i, record) in game.history.enumerated() {
            if white { parts.append("\(number).") } else if i == 0 { parts.append("\(number)...") }
            parts.append(record.san)
            if !white { number += 1 }
            white.toggle()
        }
        return parts.joined(separator: " ")
    }

    /// A score in words, from White's point of view, with no numbers.
    private static func describe(_ score: Score) -> String {
        switch score {
        case .mate(let n):
            if n > 0 { return "White has a forced mate" }
            if n < 0 { return "Black has a forced mate" }
            return "the game is over by checkmate"
        case .centipawns(let cp):
            let size = abs(cp)
            if size < 30 { return "roughly equal" }
            let side = cp > 0 ? "White" : "Black"
            if size < 100 { return "\(side) is slightly better" }
            if size < 300 { return "\(side) is clearly better" }
            return "\(side) is winning"
        }
    }
}
