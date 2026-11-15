extension Position {
    /// Parses a FEN string. The halfmove and fullmove fields may be omitted (defaulting to 0 and 1).
    /// Returns nil for malformed input.
    public init?(fen: String) {
        let fields = fen.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 4 || fields.count == 6 else { return nil }
        self.init()

        // Placement.
        let ranks = fields[0].split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == 8 else { return nil }
        for (i, rankText) in ranks.enumerated() {
            let rank = 7 - i
            var file = 0
            var lastWasDigit = false
            for ch in rankText.utf8 {
                if (49...56).contains(ch) {   // "1"..."8"
                    if lastWasDigit { return nil }
                    file += Int(ch) - 48
                    lastWasDigit = true
                } else {
                    lastWasDigit = false
                    guard file < 8, let (color, kind) = Position.pieceFromFEN(ch) else { return nil }
                    if kind == .pawn && (rank == 0 || rank == 7) { return nil }
                    put(kind, color, at: rank * 8 + file)
                    file += 1
                }
                if file > 8 { return nil }
            }
            if file != 8 { return nil }
        }

        // Side to move.
        switch fields[1] {
        case "w": side = .white
        case "b": side = .black
        default: return nil
        }

        // Castling rights.
        if fields[2] != "-" {
            var r: CastlingRights = []
            for ch in fields[2] {
                let flag: CastlingRights
                switch ch {
                case "K": flag = .whiteKingside
                case "Q": flag = .whiteQueenside
                case "k": flag = .blackKingside
                case "q": flag = .blackQueenside
                default: return nil
                }
                if r.contains(flag) { return nil }
                r.insert(flag)
            }
            rights = r
        }

        // En passant target: rank 6 when White is to move, rank 3 when Black is.
        if fields[3] != "-" {
            guard let sq = Square(String(fields[3])),
                  sq.rank == (side == .white ? 5 : 2) else { return nil }
            ep = Int8(sq.index)
        }

        if fields.count == 6 {
            guard let h = Int(fields[4]), h >= 0, let f = Int(fields[5]), f >= 1 else { return nil }
            halfmove = h
            fullmove = f
        }
    }

    private static func pieceFromFEN(_ ch: UInt8) -> (PieceColor, PieceKind)? {
        let color: PieceColor = (65...90).contains(ch) ? .white : .black
        switch ch | 0x20 {
        case UInt8(ascii: "p"): return (color, .pawn)
        case UInt8(ascii: "n"): return (color, .knight)
        case UInt8(ascii: "b"): return (color, .bishop)
        case UInt8(ascii: "r"): return (color, .rook)
        case UInt8(ascii: "q"): return (color, .queen)
        case UInt8(ascii: "k"): return (color, .king)
        default: return nil
        }
    }

    public var fen: String {
        var s = ""
        for rank in stride(from: 7, through: 0, by: -1) {
            var empty = 0
            for file in 0..<8 {
                if let p = piece(at: rank * 8 + file) {
                    if empty > 0 { s += String(empty); empty = 0 }
                    s.unicodeScalars.append(Position.fenLetter(p))
                } else {
                    empty += 1
                }
            }
            if empty > 0 { s += String(empty) }
            if rank > 0 { s += "/" }
        }
        s += side == .white ? " w " : " b "
        if rights.isEmpty {
            s += "-"
        } else {
            if rights.contains(.whiteKingside) { s += "K" }
            if rights.contains(.whiteQueenside) { s += "Q" }
            if rights.contains(.blackKingside) { s += "k" }
            if rights.contains(.blackQueenside) { s += "q" }
        }
        s += " "
        s += ep < 0 ? "-" : Square(index: Int(ep)).algebraic
        s += " \(halfmove) \(fullmove)"
        return s
    }

    private static func fenLetter(_ p: Piece) -> Unicode.Scalar {
        let c: Character
        switch p.kind {
        case .pawn: c = "p"
        case .knight: c = "n"
        case .bishop: c = "b"
        case .rook: c = "r"
        case .queen: c = "q"
        case .king: c = "k"
        }
        let l = c.asciiValue!
        return Unicode.Scalar(p.color == .white ? l - 32 : l)
    }
}
