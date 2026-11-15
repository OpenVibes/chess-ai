/// Opaque key for repetition detection: placement, side to move, castling rights and en passant
/// square. The clocks are not part of it.
public struct RepetitionKey: Hashable, Sendable {
    var white: UInt64, black: UInt64
    var pawns: UInt64, knights: UInt64, bishops: UInt64, rooks: UInt64, queens: UInt64, kings: UInt64
    /// bit 0: black to move, bits 1...4: castling rights, bits 5...: en passant square + 1 (0 = none).
    var state: UInt32
}

public struct Position: Hashable, Sendable {
    // Bitboards (bit i = square i, 0 = a1).
    var white: Bitboard = 0
    var black: Bitboard = 0
    var pawns: Bitboard = 0
    var knights: Bitboard = 0
    var bishops: Bitboard = 0
    var rooks: Bitboard = 0
    var queens: Bitboard = 0
    var kings: Bitboard = 0

    var side: PieceColor = .white
    var rights: CastlingRights = []
    /// En passant target square index, or -1.
    var ep: Int8 = -1
    var halfmove: Int = 0
    var fullmove: Int = 1

    public static let start: Position = {
        guard let p = Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1") else {
            preconditionFailure("start FEN must parse")
        }
        return p
    }()

    init() {}

    // MARK: Accessors

    public subscript(_ square: Square) -> Piece? { piece(at: square.index) }

    public var sideToMove: PieceColor { side }
    public var castling: CastlingRights { rights }
    /// Target square, only as given by the FEN rules.
    public var enPassant: Square? { ep < 0 ? nil : Square(file: Int(ep) & 7, rank: Int(ep) >> 3) }
    public var halfmoveClock: Int { halfmove }
    public var fullmoveNumber: Int { fullmove }

    @inline(__always)
    var occupied: Bitboard { white | black }

    @inline(__always)
    func pieces(of color: PieceColor) -> Bitboard { color == .white ? white : black }

    func kind(at sq: Int) -> PieceKind? {
        let b = bit(sq)
        if (pawns & b) != 0 { return .pawn }
        if (knights & b) != 0 { return .knight }
        if (bishops & b) != 0 { return .bishop }
        if (rooks & b) != 0 { return .rook }
        if (queens & b) != 0 { return .queen }
        if (kings & b) != 0 { return .king }
        return nil
    }

    func piece(at sq: Int) -> Piece? {
        let b = bit(sq)
        let color: PieceColor
        if (white & b) != 0 { color = .white } else if (black & b) != 0 { color = .black } else { return nil }
        guard let k = kind(at: sq) else { return nil }
        return Piece(color: color, kind: k)
    }

    mutating func remove(_ b: Bitboard) {
        let m = ~b
        white &= m; black &= m
        pawns &= m; knights &= m; bishops &= m; rooks &= m; queens &= m; kings &= m
    }

    mutating func put(_ kind: PieceKind, _ color: PieceColor, at sq: Int) {
        let b = bit(sq)
        if color == .white { white |= b } else { black |= b }
        switch kind {
        case .pawn: pawns |= b
        case .knight: knights |= b
        case .bishop: bishops |= b
        case .rook: rooks |= b
        case .queen: queens |= b
        case .king: kings |= b
        }
    }

    public func kingSquare(of color: PieceColor) -> Square? {
        let k = pieces(of: color) & kings
        if k == 0 { return nil }
        let i = k.trailingZeroBitCount
        return Square(file: i & 7, rank: i >> 3)
    }

    // MARK: Attacks

    /// Pieces of `color` attacking `sq`, given occupancy `occ`. Pieces in `exclude` are ignored.
    func attackers(to sq: Int, by color: PieceColor, occ: Bitboard, exclude: Bitboard = 0) -> Bitboard {
        let theirs = pieces(of: color) & ~exclude
        let pawnTable = color == .white ? 64 : 0   // a white pawn attacks sq if a black pawn on sq would attack it
        var a = Tables.pawn[pawnTable + sq] & theirs & pawns
        a |= Tables.knight[sq] & theirs & knights
        a |= Tables.king[sq] & theirs & kings
        let rq = theirs & (rooks | queens)
        if rq != 0 { a |= rookAttacks(sq, occ) & rq }
        let bq = theirs & (bishops | queens)
        if bq != 0 { a |= bishopAttacks(sq, occ) & bq }
        return a
    }

    public func isAttacked(_ square: Square, by color: PieceColor) -> Bool {
        attackers(to: square.index, by: color, occ: occupied) != 0
    }

    /// Side to move.
    public var isInCheck: Bool {
        let k = pieces(of: side) & kings
        if k == 0 { return false }
        return attackers(to: k.trailingZeroBitCount, by: side.opposite, occ: occupied) != 0
    }

    // MARK: Applying moves

    /// Precondition: move is legal.
    public func applying(_ move: Move) -> Position {
        let from = move.from.index, to = move.to.index
        guard let moving = piece(at: from), moving.color == side, let kind = kind(at: from) else {
            preconditionFailure("no piece of the side to move on \(move.from.algebraic)")
        }
        var p = self
        let isCapture = (occupied & bit(to)) != 0
        p.remove(bit(from) | bit(to))
        p.put(move.promotion ?? kind, side, at: to)

        if kind == .pawn {
            if Int(ep) == to && (from & 7) != (to & 7) {
                // En passant: the captured pawn stands behind the target square.
                p.remove(bit(side == .white ? to - 8 : to + 8))
            }
        } else if kind == .king && abs(to - from) == 2 {
            let rookFrom = to > from ? from + 3 : from - 4
            let rookTo = (from + to) / 2
            p.remove(bit(rookFrom))
            p.put(.rook, side, at: rookTo)
        }

        p.rights.subtract(Position.rightsLost(from))
        p.rights.subtract(Position.rightsLost(to))
        p.ep = (kind == .pawn && abs(to - from) == 16) ? Int8((from + to) / 2) : -1
        p.halfmove = (kind == .pawn || isCapture) ? 0 : halfmove + 1
        if side == .black { p.fullmove += 1 }
        p.side = side.opposite
        return p
    }

    @inline(__always)
    static func rightsLost(_ sq: Int) -> CastlingRights {
        switch sq {
        case 0: return .whiteQueenside
        case 4: return [.whiteKingside, .whiteQueenside]
        case 7: return .whiteKingside
        case 56: return .blackQueenside
        case 60: return [.blackKingside, .blackQueenside]
        case 63: return .blackKingside
        default: return []
        }
    }

    // MARK: Draw helpers

    /// K v K, K+B v K, K+N v K, and K+B v K+B with both bishops on same-coloured squares.
    public var hasInsufficientMaterial: Bool {
        if (pawns | rooks | queens) != 0 { return false }
        let minors = (knights | bishops).nonzeroBitCount
        if minors == 0 { return true }
        if minors == 1 { return true }
        if knights == 0 && minors == 2 && (white & bishops).nonzeroBitCount == 1 && (black & bishops).nonzeroBitCount == 1 {
            let light: Bitboard = 0x55AA_55AA_55AA_55AA   // a1 (index 0) is a dark square
            let onLight = (bishops & light).nonzeroBitCount
            return onLight == 0 || onLight == 2
        }
        return false
    }

    /// Placement + side + castling + en passant (no clocks).
    public var repetitionKey: RepetitionKey {
        var s: UInt32 = side == .black ? 1 : 0
        s |= UInt32(rights.rawValue & 0xF) << 1
        s |= UInt32(ep + 1) << 5
        return RepetitionKey(white: white, black: black, pawns: pawns, knights: knights,
                             bishops: bishops, rooks: rooks, queens: queens, kings: kings, state: s)
    }
}

public func perft(_ position: Position, depth: Int) -> Int {
    if depth <= 0 { return 1 }
    let moves = position.legalMoves()
    if depth == 1 { return moves.count }
    var total = 0
    for m in moves { total += perft(position.applying(m), depth: depth - 1) }
    return total
}
