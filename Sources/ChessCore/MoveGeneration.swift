// Legal move generation. Pins and checks are computed up front so that every generated
// non-king move is legal without making it on a copy; only en passant (rare) is verified by
// recomputing attacks on the resulting occupancy.

extension Position {
    public func legalMoves(from: Square) -> [Move] {
        legalMoves().filter { $0.from == from }
    }

    public func legalMoves() -> [Move] {
        var moves = [Move]()
        moves.reserveCapacity(48)

        let us = pieces(of: side), them = pieces(of: side.opposite)
        let enemy = side.opposite
        let occ = us | them
        let kbb = us & kings
        let ksq = kbb == 0 ? -1 : kbb.trailingZeroBitCount

        var checkers: Bitboard = 0
        var checkMask: Bitboard = ~0
        var pinned: Bitboard = 0

        if ksq >= 0 {
            checkers = attackers(to: ksq, by: enemy, occ: occ)
            let b = Tables.between
            var snipers = (rookAttacks(ksq, 0) & them & (rooks | queens))
                | (bishopAttacks(ksq, 0) & them & (bishops | queens))
            while snipers != 0 {
                let s = snipers.popLSB()
                let blockers = b[ksq * 64 + s] & occ
                if blockers != 0 && !blockers.hasMoreThanOneBit && (blockers & us) != 0 {
                    pinned |= blockers
                }
            }
            if checkers.hasMoreThanOneBit {
                addKingMoves(&moves, ksq: ksq, us: us, occ: occ)
                return moves
            }
            if checkers != 0 {
                let c = checkers.trailingZeroBitCount
                checkMask = b[ksq * 64 + c] | bit(c)
            }
        }

        let target = ~us & checkMask
        let line = Tables.line

        @inline(__always) func pinMask(_ sq: Int) -> Bitboard {
            (pinned & bit(sq)) != 0 ? line[ksq * 64 + sq] : ~0
        }

        // Knights (a pinned knight can never move).
        var bb = us & knights & ~pinned
        while bb != 0 {
            let sq = bb.popLSB()
            var t = Tables.knight[sq] & target
            while t != 0 { moves.append(Move(from: Square(index: sq), to: Square(index: t.popLSB()))) }
        }

        // Bishops and queens on diagonals.
        bb = us & (bishops | queens)
        while bb != 0 {
            let sq = bb.popLSB()
            var t = bishopAttacks(sq, occ) & target & pinMask(sq)
            while t != 0 { moves.append(Move(from: Square(index: sq), to: Square(index: t.popLSB()))) }
        }

        // Rooks and queens on ranks and files.
        bb = us & (rooks | queens)
        while bb != 0 {
            let sq = bb.popLSB()
            var t = rookAttacks(sq, occ) & target & pinMask(sq)
            while t != 0 { moves.append(Move(from: Square(index: sq), to: Square(index: t.popLSB()))) }
        }

        // Pawns.
        let white = side == .white
        let up = white ? 8 : -8
        let startRank = white ? 1 : 6
        let colorIndex = white ? 0 : 64
        bb = us & pawns
        while bb != 0 {
            let sq = bb.popLSB()
            let mask = checkMask & pinMask(sq)
            let one = sq + up
            if (occ & bit(one)) == 0 {
                if (mask & bit(one)) != 0 { appendPawnMove(&moves, sq, one) }
                if (sq >> 3) == startRank {
                    let two = one + up
                    if (occ & bit(two)) == 0 && (mask & bit(two)) != 0 { appendPawnMove(&moves, sq, two) }
                }
            }
            var caps = Tables.pawn[colorIndex + sq] & them & mask
            while caps != 0 { appendPawnMove(&moves, sq, caps.popLSB()) }
        }

        // En passant.
        if ep >= 0 {
            let epSq = Int(ep)
            let capSq = epSq - up
            if (occ & bit(epSq)) == 0 && capSq >= 0 && capSq < 64 && (them & pawns & bit(capSq)) != 0 {
                // Our pawns that attack the target square.
                var cands = Tables.pawn[(white ? 64 : 0) + epSq] & us & pawns
                while cands != 0 {
                    let from = cands.popLSB()
                    if ksq >= 0 {
                        let newOcc = (occ ^ bit(from) ^ bit(capSq)) | bit(epSq)
                        if attackers(to: ksq, by: enemy, occ: newOcc, exclude: bit(capSq)) != 0 { continue }
                    }
                    moves.append(Move(from: Square(index: from), to: Square(index: epSq)))
                }
            }
        }

        if ksq >= 0 {
            addKingMoves(&moves, ksq: ksq, us: us, occ: occ)
            if checkers == 0 { addCastling(&moves, ksq: ksq, us: us, occ: occ) }
        }
        return moves
    }

    private func appendPawnMove(_ moves: inout [Move], _ from: Int, _ to: Int) {
        let f = Square(index: from), t = Square(index: to)
        let r = to >> 3
        if r == 0 || r == 7 {
            moves.append(Move(from: f, to: t, promotion: .queen))
            moves.append(Move(from: f, to: t, promotion: .rook))
            moves.append(Move(from: f, to: t, promotion: .bishop))
            moves.append(Move(from: f, to: t, promotion: .knight))
        } else {
            moves.append(Move(from: f, to: t))
        }
    }

    private func addKingMoves(_ moves: inout [Move], ksq: Int, us: Bitboard, occ: Bitboard) {
        let enemy = side.opposite
        let occNoKing = occ & ~bit(ksq)
        var t = Tables.king[ksq] & ~us
        while t != 0 {
            let to = t.popLSB()
            if attackers(to: to, by: enemy, occ: occNoKing) == 0 {
                moves.append(Move(from: Square(index: ksq), to: Square(index: to)))
            }
        }
    }

    /// Castling as a two-square king move. The king must not be in check (caller checks).
    private func addCastling(_ moves: inout [Move], ksq: Int, us: Bitboard, occ: Bitboard) {
        let enemy = side.opposite
        let white = side == .white
        let home = white ? 4 : 60
        guard ksq == home else { return }
        let ownRooks = us & rooks
        let kingside: CastlingRights = white ? .whiteKingside : .blackKingside
        let queenside: CastlingRights = white ? .whiteQueenside : .blackQueenside

        if rights.contains(kingside), (ownRooks & bit(home + 3)) != 0,
           (occ & (bit(home + 1) | bit(home + 2))) == 0,
           attackers(to: home + 1, by: enemy, occ: occ) == 0,
           attackers(to: home + 2, by: enemy, occ: occ) == 0 {
            moves.append(Move(from: Square(index: home), to: Square(index: home + 2)))
        }
        // The b-file square only needs to be empty; it may be attacked.
        if rights.contains(queenside), (ownRooks & bit(home - 4)) != 0,
           (occ & (bit(home - 1) | bit(home - 2) | bit(home - 3))) == 0,
           attackers(to: home - 1, by: enemy, occ: occ) == 0,
           attackers(to: home - 2, by: enemy, occ: occ) == 0 {
            moves.append(Move(from: Square(index: home), to: Square(index: home - 2)))
        }
    }
}

extension Square {
    @inline(__always)
    init(index: Int) { self.init(file: index & 7, rank: index >> 3) }
}
