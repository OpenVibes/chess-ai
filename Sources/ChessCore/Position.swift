public struct RepetitionKey: Hashable, Sendable {
    // Opaque. Task 2 defines the stored representation.
    var storage: [UInt8] = []
}

public struct Position: Hashable, Sendable {
    // Placeholder storage; task 2 replaces it with the real board.
    var placeholder: Int = 0

    public static let start = Position()

    public init?(fen: String) { fatalError("unimplemented") }
    private init() {}

    public var fen: String { fatalError("unimplemented") }
    public subscript(_ square: Square) -> Piece? { fatalError("unimplemented") }
    public var sideToMove: PieceColor { fatalError("unimplemented") }
    public var castling: CastlingRights { fatalError("unimplemented") }
    /// Target square, only as given by the FEN rules.
    public var enPassant: Square? { fatalError("unimplemented") }
    public var halfmoveClock: Int { fatalError("unimplemented") }
    public var fullmoveNumber: Int { fatalError("unimplemented") }
    public func legalMoves() -> [Move] { fatalError("unimplemented") }
    public func legalMoves(from: Square) -> [Move] { fatalError("unimplemented") }
    /// Precondition: move is legal.
    public func applying(_ move: Move) -> Position { fatalError("unimplemented") }
    /// Side to move.
    public var isInCheck: Bool { fatalError("unimplemented") }
    public func kingSquare(of: PieceColor) -> Square? { fatalError("unimplemented") }
    public func isAttacked(_ square: Square, by: PieceColor) -> Bool { fatalError("unimplemented") }
    public var hasInsufficientMaterial: Bool { fatalError("unimplemented") }
    /// Placement + side + castling + en passant (no clocks).
    public var repetitionKey: RepetitionKey { fatalError("unimplemented") }
}

public func perft(_ position: Position, depth: Int) -> Int { fatalError("unimplemented") }
