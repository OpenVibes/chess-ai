import ChessCore

/// An evaluation always from White's point of view.
public enum Score: Equatable, Sendable {
    case centipawns(Int)
    /// +n: White mates in n moves (White's own moves, so mate in 1 is `.mate(1)`); -n: Black mates in n.
    case mate(Int)
}

public struct PositionAnalysis: Sendable {
    /// nil when there is no legal move.
    public let bestMove: Move?
    public let score: Score
    /// Starts with `bestMove`; may be just that one move. Empty when `bestMove` is nil.
    public let principalVariation: [Move]
    /// Deepest fully completed search iteration (0 when none, for example if stopped at once).
    public let depth: Int

    public init(bestMove: Move?, score: Score, principalVariation: [Move], depth: Int) {
        self.bestMove = bestMove
        self.score = score
        self.principalVariation = principalVariation
        self.depth = depth
    }
}

public struct AnalysisLimits: Sendable {
    public var maxDepth: Int
    public var budgetSeconds: Double
    public init(maxDepth: Int = 6, budgetSeconds: Double = 0.8) {
        self.maxDepth = maxDepth
        self.budgetSeconds = budgetSeconds
    }
}

extension Engine {
    /// Score used for a side that is already checkmated: the winner's side gets +/- this value.
    static let checkmatedCentipawns = 100_000

    /// Deterministic full-strength search (no easy-level randomness). Scores are from White's
    /// point of view.
    ///
    /// Search stops at `limits.maxDepth` or `limits.budgetSeconds`, whichever comes first, or when
    /// `shouldStop` returns true. Depth 1 always completes (unless `shouldStop` fires first), so a
    /// legal `bestMove` is returned whenever one exists, even with a zero budget.
    ///
    /// Positions with no legal move (deviation from "`.mate(0)`", which has no sign):
    /// - Checkmate: `bestMove` is nil and the score is `.centipawns(-100000)` when White is
    ///   checkmated, `.centipawns(100000)` when Black is checkmated.
    /// - Stalemate: `bestMove` is nil and the score is `.centipawns(0)`.
    ///
    /// A game already drawn by rule (repetition, fifty moves, insufficient material) that still has
    /// legal moves scores `.centipawns(0)` and returns a best move with a one-move variation.
    ///
    /// A forced mate found by the search is `.mate(n)`: n full moves by the mating side, positive
    /// when White mates and negative when Black mates.
    public static func analyse(_ game: Game, limits: AnalysisLimits = .init(),
                               shouldStop: @Sendable () -> Bool = { false }) -> PositionAnalysis {
        let position = game.position
        let moves = position.legalMoves()
        if moves.isEmpty {
            let score: Score
            if position.isInCheck {
                let whiteMated = position.sideToMove == .white
                score = .centipawns(whiteMated ? -checkmatedCentipawns : checkmatedCentipawns)
            } else {
                score = .centipawns(0)
            }
            return PositionAnalysis(bestMove: nil, score: score, principalVariation: [], depth: 0)
        }

        let seconds = limits.budgetSeconds
        let nanos: UInt64
        if seconds.isNaN || seconds <= 0 { nanos = 0 }
        else { nanos = UInt64(min(seconds, 1_000_000) * 1_000_000_000) }
        let searchLimits = SearchLimits(maxDepth: min(max(limits.maxDepth, 1), 60), budgetNanos: nanos)

        let (move, info) = withoutActuallyEscaping(shouldStop) { stop -> (Move, SearchInfo) in
            let searcher = Searcher(game: game, shouldStop: stop)
            return searcher.iterate(root: position, moves: moves, limits: searchLimits)
        }

        let drawnByRule: Bool
        switch game.status {
        case .drawFiftyMove, .drawRepetition, .drawInsufficientMaterial: drawnByRule = true
        default: drawnByRule = false
        }

        var pv = info.pv
        if pv.first != move { pv = [move] }
        if drawnByRule {
            return PositionAnalysis(bestMove: move, score: .centipawns(0),
                                    principalVariation: [move], depth: info.depth)
        }

        // Search score is from the side to move's point of view; convert to White's.
        let white = position.sideToMove == .white
        let score: Score
        if let s = info.bestScore {
            score = whiteScore(s, whiteToMove: white)
        } else {
            score = .centipawns(Evaluation.evaluate(position))
        }
        return PositionAnalysis(bestMove: move, score: score, principalVariation: pv, depth: info.depth)
    }

    /// Converts a search score (side to move's view) into a `Score` from White's view.
    static func whiteScore(_ s: Int, whiteToMove: Bool) -> Score {
        if s >= Searcher.mateBound {
            // Side to move mates; `plies` is the distance to the mated position.
            let plies = Searcher.mate - s
            let n = (plies + 1) / 2
            return .mate(whiteToMove ? n : -n)
        }
        if s <= -Searcher.mateBound {
            // Side to move is mated; the opponent mates.
            let plies = Searcher.mate + s
            let n = max(1, plies / 2)
            return .mate(whiteToMove ? -n : n)
        }
        return .centipawns(whiteToMove ? s : -s)
    }
}
