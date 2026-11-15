import ChessCore

public enum Difficulty: String, CaseIterable, Sendable { case easy, medium, hard }

public enum Engine {
    /// Wall-clock budget of the hard level.
    static let hardBudgetNanos: UInt64 = 2_000_000_000
    /// Easy picks randomly among root moves within this many centipawns of the best.
    static let easyMargin = 80

    /// Returns nil only when there is no legal move. `shouldStop` is polled during search.
    public static func bestMove(in game: Game, difficulty: Difficulty,
                                shouldStop: @Sendable () -> Bool = { false }) -> Move? {
        var rng = SystemRandomNumberGenerator()
        return analyze(game: game, difficulty: difficulty, shouldStop: shouldStop, using: &rng)?.move
    }

    /// Static score in centipawns from White's point of view.
    public static func evaluate(_ position: Position) -> Int {
        Evaluation.evaluate(position)
    }

    /// Same as `bestMove` with a caller-supplied random generator (easy level) and search details.
    static func analyze<G: RandomNumberGenerator>(
        game: Game, difficulty: Difficulty,
        shouldStop: @Sendable () -> Bool, using rng: inout G
    ) -> (move: Move, info: SearchInfo)? {
        let position = game.position
        let moves = position.legalMoves()
        if moves.isEmpty { return nil }
        if moves.count == 1 { return (moves[0], SearchInfo()) }

        return withoutActuallyEscaping(shouldStop) { stop in
            let searcher = Searcher(game: game, shouldStop: stop)
            switch difficulty {
            case .easy:
                return searcher.pickRandom(root: position, moves: moves, margin: easyMargin, using: &rng)
            case .medium:
                return searcher.iterate(root: position, moves: moves,
                                        limits: SearchLimits(maxDepth: 3, budgetNanos: nil))
            case .hard:
                return searcher.iterate(root: position, moves: moves,
                                        limits: SearchLimits(maxDepth: 60, budgetNanos: hardBudgetNanos))
            }
        }
    }
}
