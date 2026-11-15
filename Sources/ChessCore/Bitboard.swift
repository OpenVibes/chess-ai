// Bitboard helpers and precomputed attack tables. Internal to ChessCore.
// Square index: 0 = a1, 7 = h1, 63 = h8. Bit i of a bitboard is square i.

typealias Bitboard = UInt64

extension UInt64 {
    /// Removes and returns the index of the lowest set bit. The receiver must be non-zero.
    @inline(__always)
    mutating func popLSB() -> Int {
        let i = trailingZeroBitCount
        self &= self &- 1
        return i
    }

    @inline(__always)
    var hasMoreThanOneBit: Bool { (self & (self &- 1)) != 0 }
}

@inline(__always)
func bit(_ square: Int) -> Bitboard { 1 << UInt64(square) }

enum Tables {
    // Direction indices: 0 N, 1 NE, 2 E, 3 SE, 4 S, 5 SW, 6 W, 7 NW.
    // Directions 0, 1, 2, 7 increase the square index; 3, 4, 5, 6 decrease it.
    static let dFile = [0, 1, 1, 1, 0, -1, -1, -1]
    static let dRank = [1, 1, 0, -1, -1, -1, 0, 1]

    /// rays[dir * 64 + sq]: squares strictly beyond `sq` in direction `dir`, to the board edge.
    static let rays: [Bitboard] = {
        var t = [Bitboard](repeating: 0, count: 8 * 64)
        for d in 0..<8 {
            for sq in 0..<64 {
                var f = sq & 7 + dFile[d], r = sq >> 3 + dRank[d]
                var bb: Bitboard = 0
                while (0..<8).contains(f) && (0..<8).contains(r) {
                    bb |= bit(r * 8 + f)
                    f += dFile[d]; r += dRank[d]
                }
                t[d * 64 + sq] = bb
            }
        }
        return t
    }()

    /// between[a * 64 + b]: squares strictly between `a` and `b` when they share a rank, file or
    /// diagonal; 0 otherwise.
    static let between: [Bitboard] = {
        var t = [Bitboard](repeating: 0, count: 64 * 64)
        for a in 0..<64 {
            for d in 0..<8 {
                var f = a & 7 + dFile[d], r = a >> 3 + dRank[d]
                var acc: Bitboard = 0
                while (0..<8).contains(f) && (0..<8).contains(r) {
                    let s = r * 8 + f
                    t[a * 64 + s] = acc
                    acc |= bit(s)
                    f += dFile[d]; r += dRank[d]
                }
            }
        }
        return t
    }()

    /// line[a * 64 + b]: the whole rank, file or diagonal through both squares (including them);
    /// 0 when they are not aligned.
    static let line: [Bitboard] = {
        var t = [Bitboard](repeating: 0, count: 64 * 64)
        for a in 0..<64 {
            for d in 0..<4 {
                var l = rays[d * 64 + a] | rays[(d + 4) * 64 + a] | bit(a)
                let full = l
                l &= ~bit(a)
                while l != 0 { t[a * 64 + l.popLSB()] = full }
            }
        }
        return t
    }()

    static let knight: [Bitboard] = {
        let df = [1, 2, 2, 1, -1, -2, -2, -1], dr = [2, 1, -1, -2, -2, -1, 1, 2]
        return (0..<64).map { sq in
            var bb: Bitboard = 0
            for i in 0..<8 {
                let f = sq & 7 + df[i], r = sq >> 3 + dr[i]
                if (0..<8).contains(f) && (0..<8).contains(r) { bb |= bit(r * 8 + f) }
            }
            return bb
        }
    }()

    static let king: [Bitboard] = {
        (0..<64).map { sq in
            var bb: Bitboard = 0
            for i in 0..<8 {
                let f = sq & 7 + dFile[i], r = sq >> 3 + dRank[i]
                if (0..<8).contains(f) && (0..<8).contains(r) { bb |= bit(r * 8 + f) }
            }
            return bb
        }
    }()

    /// pawn[color * 64 + sq]: squares attacked by a pawn of `color` (0 white, 1 black) on `sq`.
    static let pawn: [Bitboard] = {
        var t = [Bitboard](repeating: 0, count: 128)
        for sq in 0..<64 {
            let f = sq & 7, r = sq >> 3
            for (c, dr) in [(0, 1), (1, -1)] {
                var bb: Bitboard = 0
                for df in [-1, 1] {
                    let nf = f + df, nr = r + dr
                    if (0..<8).contains(nf) && (0..<8).contains(nr) { bb |= bit(nr * 8 + nf) }
                }
                t[c * 64 + sq] = bb
            }
        }
        return t
    }()
}

@inline(__always)
func rookAttacks(_ sq: Int, _ occ: Bitboard) -> Bitboard {
    let r = Tables.rays
    var n = r[sq], e = r[2 * 64 + sq], s = r[4 * 64 + sq], w = r[6 * 64 + sq]
    var b = n & occ
    if b != 0 { n ^= r[b.trailingZeroBitCount] }
    b = e & occ
    if b != 0 { e ^= r[2 * 64 + b.trailingZeroBitCount] }
    b = s & occ
    if b != 0 { s ^= r[4 * 64 + 63 - b.leadingZeroBitCount] }
    b = w & occ
    if b != 0 { w ^= r[6 * 64 + 63 - b.leadingZeroBitCount] }
    return n | e | s | w
}

@inline(__always)
func bishopAttacks(_ sq: Int, _ occ: Bitboard) -> Bitboard {
    let r = Tables.rays
    var ne = r[1 * 64 + sq], se = r[3 * 64 + sq], sw = r[5 * 64 + sq], nw = r[7 * 64 + sq]
    var b = ne & occ
    if b != 0 { ne ^= r[1 * 64 + b.trailingZeroBitCount] }
    b = nw & occ
    if b != 0 { nw ^= r[7 * 64 + b.trailingZeroBitCount] }
    b = se & occ
    if b != 0 { se ^= r[3 * 64 + 63 - b.leadingZeroBitCount] }
    b = sw & occ
    if b != 0 { sw ^= r[5 * 64 + 63 - b.leadingZeroBitCount] }
    return ne | se | sw | nw
}
