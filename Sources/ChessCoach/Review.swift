import ChessCore
import ChessEngine
import Foundation

public enum MoveQuality: String, Sendable, CaseIterable { case best, excellent, good, inaccuracy, mistake, blunder
    public var displayName: String {
        switch self {
        case .best: return "Best"
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .inaccuracy: return "Inaccuracy"
        case .mistake: return "Mistake"
        case .blunder: return "Blunder"
        }
    }
}

public struct MoveReview: Sendable, Equatable {
    public let move: Move, san: String, mover: PieceColor
    public let quality: MoveQuality
    public let scoreBefore: Score             // best play available before the move (White POV)
    public let scoreAfter: Score              // after the move actually played (White POV)
    public let bestMove: Move?, bestSAN: String?      // engine's choice in the position before
    public let bestLine: [String]             // SAN of the engine line, up to 4 plies
    public let winChanceLost: Double          // 0…1, from the mover's point of view

    public init(move: Move, san: String, mover: PieceColor, quality: MoveQuality,
                scoreBefore: Score, scoreAfter: Score, bestMove: Move?, bestSAN: String?,
                bestLine: [String], winChanceLost: Double) {
        self.move = move; self.san = san; self.mover = mover; self.quality = quality
        self.scoreBefore = scoreBefore; self.scoreAfter = scoreAfter
        self.bestMove = bestMove; self.bestSAN = bestSAN
        self.bestLine = bestLine; self.winChanceLost = winChanceLost
    }

    /// Rule-based sentence.
    public var summary: String {
        switch quality {
        case .best: return "Best move."
        case .excellent: return "Excellent move."
        case .good: return "Good move."
        case .inaccuracy, .mistake, .blunder:
            let name = quality.displayName
            if case .mate(let n) = scoreBefore, mateBelongs(n, to: mover) {
                var stillMates = false
                if case .mate(let m) = scoreAfter, mateBelongs(m, to: mover) { stillMates = true }
                if !stillMates, let best = bestSAN {
                    return "\(name). You missed mate in \(abs(n)) with \(best)."
                }
            }
            if case .mate(let m) = scoreAfter, mateBelongs(m, to: mover.opposite) {
                var alreadyLost = false
                if case .mate(let n) = scoreBefore, mateBelongs(n, to: mover.opposite) { alreadyLost = true }
                if !alreadyLost { return "\(name). This allows mate in \(abs(m))." }
            }
            if let best = bestSAN { return "\(name). \(best) was better." }
            return "\(name)."
        }
    }
}

private func mateBelongs(_ n: Int, to color: PieceColor) -> Bool {
    color == .white ? n > 0 : n < 0
}

public enum Coach {
    /// Scores at or beyond this many centipawns are a checkmated position, not an evaluation.
    private static let decidedCentipawns = 90_000

    public static func winChance(_ score: Score, for color: PieceColor) -> Double {
        let white: Double
        switch score {
        case .mate(let n):
            white = n > 0 ? 1.0 : 0.0
        case .centipawns(let cp):
            if cp >= decidedCentipawns { white = 1.0 }
            else if cp <= -decidedCentipawns { white = 0.0 }
            else { white = 0.5 + 0.5 * (2 / (1 + exp(-0.00368208 * Double(cp))) - 1) }
        }
        return color == .white ? white : 1 - white
    }

    public static func classify(winChanceLost: Double, playedBest: Bool) -> MoveQuality {
        if playedBest || winChanceLost < 0.005 { return .best }
        if winChanceLost < 0.02 { return .excellent }
        if winChanceLost < 0.05 { return .good }
        if winChanceLost < 0.10 { return .inaccuracy }
        if winChanceLost < 0.20 { return .mistake }
        return .blunder
    }

    public static func review(record: MoveRecord, before: PositionAnalysis, after: PositionAnalysis) -> MoveReview {
        let position = record.positionBefore
        let mover = position.sideToMove
        let playedBest = record.move == before.bestMove || position.legalMoves().count == 1
        let lost = playedBest
            ? 0
            : max(0, winChance(before.score, for: mover) - winChance(after.score, for: mover))
        let quality = classify(winChanceLost: lost, playedBest: playedBest)

        var line: [String] = []
        var walk = position
        for move in before.principalVariation.prefix(4) {
            guard walk.legalMoves().contains(move) else { break }
            line.append(san(for: move, in: walk))
            walk = walk.applying(move)
        }
        let bestSAN = before.bestMove.map { san(for: $0, in: position) }
        return MoveReview(move: record.move, san: record.san, mover: mover, quality: quality,
                          scoreBefore: before.score, scoreAfter: after.score,
                          bestMove: before.bestMove, bestSAN: bestSAN,
                          bestLine: line, winChanceLost: lost)
    }

    public static func format(_ score: Score) -> String {
        switch score {
        case .mate(let n):
            return n < 0 ? "\u{2212}M\(-n)" : "M\(n)"
        case .centipawns(let cp):
            if cp >= decidedCentipawns { return "1-0" }
            if cp <= -decidedCentipawns { return "0-1" }
            let v = (Double(cp) / 100 * 10).rounded() / 10
            if v == 0 { return "0.0" }
            let body = String(format: "%.1f", abs(v))
            return v > 0 ? "+\(body)" : "\u{2212}\(body)"
        }
    }
}
