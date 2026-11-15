import ChessCore

public enum Difficulty: String, CaseIterable, Sendable { case easy, medium, hard }

public enum Engine {
    /// Returns nil only when there is no legal move. `shouldStop` is polled during search.
    public static func bestMove(in game: Game, difficulty: Difficulty,
                                shouldStop: @Sendable () -> Bool = { false }) -> Move? {
        fatalError("unimplemented")
    }

    /// Static score in centipawns from White's point of view.
    public static func evaluate(_ position: Position) -> Int {
        fatalError("unimplemented")
    }
}
