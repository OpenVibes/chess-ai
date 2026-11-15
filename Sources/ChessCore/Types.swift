public enum PieceColor: Sendable {
    case white, black

    public var opposite: PieceColor { self == .white ? .black : .white }
}

public enum PieceKind: Sendable, CaseIterable {
    case pawn, knight, bishop, rook, queen, king
}

public struct Piece: Hashable, Sendable {
    public let color: PieceColor
    public let kind: PieceKind

    public init(color: PieceColor, kind: PieceKind) {
        self.color = color
        self.kind = kind
    }
}

public struct Square: Hashable, Sendable {
    /// 0 = a1, 1 = b1 ... 7 = h1, 8 = a2 ... 63 = h8
    public let index: Int

    /// 0...7 = a...h
    public var file: Int { index & 7 }
    /// 0...7 = 1...8
    public var rank: Int { index >> 3 }

    public init(file: Int, rank: Int) {
        precondition((0..<8).contains(file) && (0..<8).contains(rank), "square out of range")
        self.index = rank * 8 + file
    }

    public init?(_ algebraic: String) {
        let u = Array(algebraic.utf8)
        guard u.count == 2,
              (97...104).contains(u[0]),
              (49...56).contains(u[1]) else { return nil }
        self.init(file: Int(u[0]) - 97, rank: Int(u[1]) - 49)
    }

    public var algebraic: String {
        let f = Character(UnicodeScalar(UInt8(97 + file)))
        return "\(f)\(rank + 1)"
    }
}

public struct Move: Hashable, Sendable {
    public let from: Square, to: Square
    /// nil unless a pawn reaches the last rank
    public let promotion: PieceKind?

    public init(from: Square, to: Square, promotion: PieceKind? = nil) {
        self.from = from
        self.to = to
        self.promotion = promotion
    }

    /// "e2e4", "e7e8q"
    public var uci: String {
        var s = from.algebraic + to.algebraic
        if let promotion {
            switch promotion {
            case .queen: s += "q"
            case .rook: s += "r"
            case .bishop: s += "b"
            case .knight: s += "n"
            case .pawn, .king: break
            }
        }
        return s
    }
}

public struct CastlingRights: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let whiteKingside = CastlingRights(rawValue: 1 << 0)
    public static let whiteQueenside = CastlingRights(rawValue: 1 << 1)
    public static let blackKingside = CastlingRights(rawValue: 1 << 2)
    public static let blackQueenside = CastlingRights(rawValue: 1 << 3)
}
