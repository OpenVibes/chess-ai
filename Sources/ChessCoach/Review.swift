import ChessCore
import ChessEngine

public enum MoveQuality: String, Sendable, CaseIterable { case best, excellent, good, inaccuracy, mistake, blunder }

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

    /// Rule-based sentence. Filled in by the move review task.
    public var summary: String { "" }
}
