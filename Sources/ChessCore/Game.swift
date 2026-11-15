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
        self.keys = [position.repetitionKey]
        self.cachedStatus = Game.computeStatus(position, keys: keys)
    }

    public private(set) var position: Position
    public private(set) var history: [MoveRecord]
    private var keys: [RepetitionKey]
    private var cachedStatus: GameStatus

    public var status: GameStatus { cachedStatus }
    public var lastMove: Move? { history.last?.move }
    /// Keys of all positions in the game so far, oldest first, including the current one.
    public var repetitionKeys: [RepetitionKey] { keys }

    /// Pieces this colour has taken, in the order they were taken.
    public func captured(by color: PieceColor) -> [Piece] {
        history.compactMap { $0.piece.color == color ? $0.captured : nil }
    }

    /// False and no change if illegal or game over.
    @discardableResult public mutating func play(_ move: Move) -> Bool {
        guard cachedStatus == .ongoing, position.legalMoves().contains(move),
              let piece = position[move.from] else { return false }
        var captured = position[move.to]
        if captured == nil, piece.kind == .pawn, move.from.file != move.to.file {
            captured = Piece(color: piece.color.opposite, kind: .pawn)
        }
        let record = MoveRecord(move: move, san: san(for: move, in: position), piece: piece,
                                captured: captured, positionBefore: position)
        history.append(record)
        position = position.applying(move)
        keys.append(position.repetitionKey)
        cachedStatus = Game.computeStatus(position, keys: keys)
        return true
    }

    @discardableResult public mutating func undo() -> Bool {
        guard let record = history.popLast() else { return false }
        position = record.positionBefore
        keys.removeLast()
        cachedStatus = Game.computeStatus(position, keys: keys)
        return true
    }

    private static func computeStatus(_ position: Position, keys: [RepetitionKey]) -> GameStatus {
        if position.legalMoves().isEmpty {
            return position.isInCheck ? .checkmate(winner: position.sideToMove.opposite) : .stalemate
        }
        if position.hasInsufficientMaterial { return .drawInsufficientMaterial }
        if let current = keys.last, keys.reduce(0, { $0 + ($1 == current ? 1 : 0) }) >= 3 {
            return .drawRepetition
        }
        if position.halfmoveClock >= 100 { return .drawFiftyMove }
        return .ongoing
    }
}
