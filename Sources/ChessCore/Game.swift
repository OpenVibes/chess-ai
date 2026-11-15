public enum GameStatus: Equatable, Sendable {
    case ongoing
    case checkmate(winner: PieceColor)
    case stalemate
    case drawFiftyMove, drawRepetition, drawInsufficientMaterial
}

public struct MoveRecord: Sendable {
    public let move: Move
    /// "Nf3", "exd5", "O-O", "e8=Q+", "Qh4#"
    public let san: String
    public let piece: Piece
    public let captured: Piece?
    public let positionBefore: Position

    public init(move: Move, san: String, piece: Piece, captured: Piece?, positionBefore: Position) {
        self.move = move
        self.san = san
        self.piece = piece
        self.captured = captured
        self.positionBefore = positionBefore
    }
}

public struct Game: Sendable {
    public init(position: Position = .start) {
        self.position = position
        self.history = []
    }

    public private(set) var position: Position
    public private(set) var history: [MoveRecord]
    public var status: GameStatus { fatalError("unimplemented") }
    public var lastMove: Move? { fatalError("unimplemented") }
    /// Pieces this colour has taken.
    public func captured(by: PieceColor) -> [Piece] { fatalError("unimplemented") }
    /// False and no change if illegal or game over.
    @discardableResult public mutating func play(_ move: Move) -> Bool { fatalError("unimplemented") }
    @discardableResult public mutating func undo() -> Bool { fatalError("unimplemented") }
}
