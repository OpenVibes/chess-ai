/// Standard algebraic notation for a legal `move` in `position`.
public func san(for move: Move, in position: Position) -> String {
    guard let piece = position[move.from] else { return move.uci }
    let after = position.applying(move)
    var s = ""

    if piece.kind == .king && abs(move.to.file - move.from.file) == 2 {
        s = move.to.file > move.from.file ? "O-O" : "O-O-O"
    } else {
        let isEnPassant = piece.kind == .pawn && move.from.file != move.to.file && position[move.to] == nil
        let isCapture = position[move.to] != nil || isEnPassant
        let fileLetter = String(UnicodeScalar(UInt8(97 + move.from.file)))
        let rankDigit = String(move.from.rank + 1)

        if piece.kind == .pawn {
            if isCapture { s += fileLetter }
        } else {
            s += pieceLetter(piece.kind)
            let others = position.legalMoves().filter {
                $0.to == move.to && $0.from != move.from && position[$0.from]?.kind == piece.kind
            }
            if !others.isEmpty {
                if !others.contains(where: { $0.from.file == move.from.file }) {
                    s += fileLetter
                } else if !others.contains(where: { $0.from.rank == move.from.rank }) {
                    s += rankDigit
                } else {
                    s += fileLetter + rankDigit
                }
            }
        }
        if isCapture { s += "x" }
        s += move.to.algebraic
        if let promo = move.promotion { s += "=" + pieceLetter(promo) }
    }

    if after.isInCheck {
        s += after.legalMoves().isEmpty ? "#" : "+"
    }
    return s
}

extension Position {
    public func san(for move: Move) -> String { ChessCore.san(for: move, in: self) }
}

private func pieceLetter(_ kind: PieceKind) -> String {
    switch kind {
    case .king: return "K"
    case .queen: return "Q"
    case .rook: return "R"
    case .bishop: return "B"
    case .knight: return "N"
    case .pawn: return ""
    }
}
