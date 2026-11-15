import ChessCore

/// Static evaluation: material, piece-square tables, a tapered king table and a bishop-pair bonus.
///
/// Scores are centipawns from White's point of view. The evaluation is colour-symmetric: a
/// position and its colour-mirrored twin (ranks flipped, colours and side to move swapped) get
/// exactly opposite scores. No tempo term is used so that the start position is exactly 0.
enum Evaluation {
    static let pawnValue = 100
    static let knightValue = 320
    static let bishopValue = 330
    static let rookValue = 500
    static let queenValue = 900
    static let bishopPairBonus = 30

    /// Material of both sides' non-pawn pieces at which the king is fully "middlegame".
    static let maxPhase = 24

    static let squares: [Square] = (0..<64).map { Square(file: $0 & 7, rank: $0 >> 3) }

    // Piece-square tables, written the way a board is drawn: rank 8 first, file a first.
    // They are for White; Black uses the vertically mirrored entry.
    private static let pawnPST: [Int] = [
          0,   0,   0,   0,   0,   0,   0,   0,
         50,  50,  50,  50,  50,  50,  50,  50,
         10,  10,  20,  30,  30,  20,  10,  10,
          5,   5,  10,  25,  25,  10,   5,   5,
          0,   0,   0,  20,  20,   0,   0,   0,
          5,  -5, -10,   0,   0, -10,  -5,   5,
          5,  10,  10, -20, -20,  10,  10,   5,
          0,   0,   0,   0,   0,   0,   0,   0,
    ]
    private static let knightPST: [Int] = [
        -50, -40, -30, -30, -30, -30, -40, -50,
        -40, -20,   0,   0,   0,   0, -20, -40,
        -30,   0,  10,  15,  15,  10,   0, -30,
        -30,   5,  15,  20,  20,  15,   5, -30,
        -30,   0,  15,  20,  20,  15,   0, -30,
        -30,   5,  10,  15,  15,  10,   5, -30,
        -40, -20,   0,   5,   5,   0, -20, -40,
        -50, -40, -30, -30, -30, -30, -40, -50,
    ]
    private static let bishopPST: [Int] = [
        -20, -10, -10, -10, -10, -10, -10, -20,
        -10,   0,   0,   0,   0,   0,   0, -10,
        -10,   0,   5,  10,  10,   5,   0, -10,
        -10,   5,   5,  10,  10,   5,   5, -10,
        -10,   0,  10,  10,  10,  10,   0, -10,
        -10,  10,  10,  10,  10,  10,  10, -10,
        -10,   5,   0,   0,   0,   0,   5, -10,
        -20, -10, -10, -10, -10, -10, -10, -20,
    ]
    private static let rookPST: [Int] = [
          0,   0,   0,   0,   0,   0,   0,   0,
          5,  10,  10,  10,  10,  10,  10,   5,
         -5,   0,   0,   0,   0,   0,   0,  -5,
         -5,   0,   0,   0,   0,   0,   0,  -5,
         -5,   0,   0,   0,   0,   0,   0,  -5,
         -5,   0,   0,   0,   0,   0,   0,  -5,
         -5,   0,   0,   0,   0,   0,   0,  -5,
          0,   0,   0,   5,   5,   0,   0,   0,
    ]
    private static let queenPST: [Int] = [
        -20, -10, -10,  -5,  -5, -10, -10, -20,
        -10,   0,   0,   0,   0,   0,   0, -10,
        -10,   0,   5,   5,   5,   5,   0, -10,
         -5,   0,   5,   5,   5,   5,   0,  -5,
          0,   0,   5,   5,   5,   5,   0,  -5,
        -10,   5,   5,   5,   5,   5,   0, -10,
        -10,   0,   5,   0,   0,   0,   0, -10,
        -20, -10, -10,  -5,  -5, -10, -10, -20,
    ]
    private static let kingMiddlegamePST: [Int] = [
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -20, -30, -30, -40, -40, -30, -30, -20,
        -10, -20, -20, -20, -20, -20, -20, -10,
         20,  20,   0,   0,   0,   0,  20,  20,
         20,  30,  10,   0,   0,  10,  30,  20,
    ]
    private static let kingEndgamePST: [Int] = [
        -50, -40, -30, -20, -20, -30, -40, -50,
        -30, -20, -10,   0,   0, -10, -20, -30,
        -30, -10,  20,  30,  30,  20, -10, -30,
        -30, -10,  30,  40,  40,  30, -10, -30,
        -30, -10,  30,  40,  40,  30, -10, -30,
        -30, -10,  20,  30,  30,  20, -10, -30,
        -30, -30,   0,   0,   0,   0, -30, -30,
        -50, -30, -30, -30, -30, -30, -30, -50,
    ]

    /// Material + piece-square value, indexed by `kindIndex * 64 + squareIndex` (non-king pieces),
    /// for a white piece (`white`) and a black piece (`black`). Both are non-negative-signed
    /// "value for the owner".
    private static let white: [Int] = table(mirror: true)
    private static let black: [Int] = table(mirror: false)
    private static let kingMGWhite: [Int] = (0..<64).map { kingMiddlegamePST[$0 ^ 56] }
    private static let kingMGBlack: [Int] = kingMiddlegamePST
    private static let kingEGWhite: [Int] = (0..<64).map { kingEndgamePST[$0 ^ 56] }
    private static let kingEGBlack: [Int] = kingEndgamePST

    private static func table(mirror: Bool) -> [Int] {
        let psts = [pawnPST, knightPST, bishopPST, rookPST, queenPST]
        let values = [pawnValue, knightValue, bishopValue, rookValue, queenValue]
        var t = [Int](repeating: 0, count: 5 * 64)
        for k in 0..<5 {
            for i in 0..<64 {
                t[k * 64 + i] = values[k] + psts[k][mirror ? i ^ 56 : i]
            }
        }
        return t
    }

    /// Centipawns, White's point of view.
    static func evaluate(_ position: Position) -> Int {
        let squares = Evaluation.squares
        let wt = white, bt = black
        var score = 0
        var phase = 0
        var whiteBishops = 0, blackBishops = 0
        var whiteKing = -1, blackKing = -1

        for i in 0..<64 {
            guard let p = position[squares[i]] else { continue }
            if p.color == .white {
                switch p.kind {
                case .pawn: score += wt[i]
                case .knight: score += wt[64 + i]; phase += 1
                case .bishop: score += wt[128 + i]; phase += 1; whiteBishops += 1
                case .rook: score += wt[192 + i]; phase += 2
                case .queen: score += wt[256 + i]; phase += 4
                case .king: whiteKing = i
                }
            } else {
                switch p.kind {
                case .pawn: score -= bt[i]
                case .knight: score -= bt[64 + i]; phase += 1
                case .bishop: score -= bt[128 + i]; phase += 1; blackBishops += 1
                case .rook: score -= bt[192 + i]; phase += 2
                case .queen: score -= bt[256 + i]; phase += 4
                case .king: blackKing = i
                }
            }
        }

        if whiteBishops >= 2 { score += bishopPairBonus }
        if blackBishops >= 2 { score -= bishopPairBonus }

        let ph = min(phase, maxPhase)
        if whiteKing >= 0 {
            score += (kingMGWhite[whiteKing] * ph + kingEGWhite[whiteKing] * (maxPhase - ph)) / maxPhase
        }
        if blackKing >= 0 {
            score -= (kingMGBlack[blackKing] * ph + kingEGBlack[blackKing] * (maxPhase - ph)) / maxPhase
        }
        return score
    }
}
