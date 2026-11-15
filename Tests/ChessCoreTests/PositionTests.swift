import XCTest
@testable import ChessCore

final class PositionTests: XCTestCase {
    private func pos(_ fen: String, file: StaticString = #filePath, line: UInt = #line) throws -> Position {
        try XCTUnwrap(Position(fen: fen), fen, file: file, line: line)
    }

    private func mv(_ uci: String) -> Move {
        let s = Array(uci)
        let promo: PieceKind?
        if s.count == 5 {
            switch s[4] {
            case "q": promo = .queen
            case "r": promo = .rook
            case "b": promo = .bishop
            default: promo = .knight
            }
        } else { promo = nil }
        return Move(from: Square(String(s[0...1]))!, to: Square(String(s[2...3]))!, promotion: promo)
    }

    private func play(_ p: Position, _ ucis: String...) -> Position {
        var p = p
        for u in ucis {
            let m = mv(u)
            XCTAssertTrue(p.legalMoves().contains(m), "\(u) should be legal in \(p.fen)")
            p = p.applying(m)
        }
        return p
    }

    private func ucis(_ p: Position) -> Set<String> { Set(p.legalMoves().map(\.uci)) }

    // MARK: Castling

    func testCastlingBasicAndRookMove() throws {
        let p = try pos("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        XCTAssertTrue(ucis(p).isSuperset(of: ["e1g1", "e1c1"]))
        let k = p.applying(mv("e1g1"))
        XCTAssertEqual(k.fen, "r3k2r/8/8/8/8/8/8/R4RK1 b kq - 1 1")
        let q = p.applying(mv("e1c1"))
        XCTAssertEqual(q.fen, "r3k2r/8/8/8/8/8/8/2KR3R b kq - 1 1")
        let bk = k.applying(mv("e8g8"))
        XCTAssertEqual(bk.fen, "r4rk1/8/8/8/8/8/8/R4RK1 w - - 2 2")
        let bq = k.applying(mv("e8c8"))
        XCTAssertEqual(bq.fen, "2kr3r/8/8/8/8/8/8/R4RK1 w - - 2 2")
    }

    func testCastlingRightsLostOnKingAndRookMoves() throws {
        let p = try pos("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        XCTAssertEqual(p.applying(mv("e1e2")).castling, [.blackKingside, .blackQueenside])
        XCTAssertEqual(p.applying(mv("h1h2")).castling, [.whiteQueenside, .blackKingside, .blackQueenside])
        XCTAssertEqual(p.applying(mv("a1a2")).castling, [.whiteKingside, .blackKingside, .blackQueenside])
        let b = try pos("r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1")
        XCTAssertEqual(b.applying(mv("a8a7")).castling, [.whiteKingside, .whiteQueenside, .blackKingside])
        XCTAssertEqual(b.applying(mv("e8d8")).castling, [.whiteKingside, .whiteQueenside])
    }

    func testCastlingRightLostWhenRookCapturedOnHomeSquare() throws {
        // White bishop on e5 takes the rook on h8; Black loses kingside castling.
        let p = try pos("r3k2r/8/8/4B3/8/8/8/R3K2R w KQkq - 0 1")
        let after = p.applying(mv("e5h8"))
        XCTAssertEqual(after.castling, [.whiteKingside, .whiteQueenside, .blackQueenside])
        // Black rook takes the rook on a1; White loses queenside castling.
        let q = try pos("r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1")
        let after2 = q.applying(mv("a8a1"))
        XCTAssertEqual(after2.castling, [.whiteKingside, .blackKingside])
        XCTAssertFalse(ucis(after2).contains("e1c1"))
        // A promotion capture on the rook's home square also removes the right.
        let r = try pos("1n2k2r/6P1/8/8/8/8/8/4K3 w k - 0 1")
        XCTAssertEqual(r.applying(mv("g7h8q")).castling, [])
    }

    func testNoCastlingOutOfCheck() throws {
        let p = try pos("4k3/8/8/8/8/8/4r3/R3K2R w KQ - 0 1")
        XCTAssertTrue(p.isInCheck)
        XCTAssertFalse(ucis(p).contains("e1g1"))
        XCTAssertFalse(ucis(p).contains("e1c1"))
    }

    func testNoCastlingThroughCheck() throws {
        // Black rook on f8 attacks f1; black rook on d8 attacks d1.
        let k = try pos("4kr2/8/8/8/8/8/8/R3K2R w KQ - 0 1")
        XCTAssertFalse(ucis(k).contains("e1g1"))
        XCTAssertTrue(ucis(k).contains("e1c1"))
        let q = try pos("3rk3/8/8/8/8/8/8/R3K2R w KQ - 0 1")
        XCTAssertFalse(ucis(q).contains("e1c1"))
        XCTAssertTrue(ucis(q).contains("e1g1"))
    }

    func testNoCastlingIntoCheck() throws {
        let k = try pos("4k1r1/8/8/8/8/8/8/R3K2R w KQ - 0 1")
        XCTAssertFalse(ucis(k).contains("e1g1"))
        XCTAssertTrue(ucis(k).contains("e1c1"))
        let q = try pos("2r1k3/8/8/8/8/8/8/R3K2R w KQ - 0 1")
        XCTAssertFalse(ucis(q).contains("e1c1"))
        XCTAssertTrue(ucis(q).contains("e1g1"))
    }

    func testCastlingAllowedWhenOnlyB1IsAttacked() throws {
        let w = try pos("1r2k3/8/8/8/8/8/8/R3K2R w KQ - 0 1")
        XCTAssertTrue(ucis(w).contains("e1c1"))
        let b = try pos("r3k2r/8/8/8/8/8/8/1R2K3 b kq - 0 1")
        XCTAssertTrue(ucis(b).contains("e8c8"))
    }

    func testNoCastlingThroughPieces() throws {
        let p = try pos("r3k2r/8/8/8/8/8/8/RN2K1NR w KQkq - 0 1")
        XCTAssertFalse(ucis(p).contains("e1g1"))
        XCTAssertFalse(ucis(p).contains("e1c1"))
    }

    func testNoCastlingWithoutRights() throws {
        let p = try pos("r3k2r/8/8/8/8/8/8/R3K2R w - - 0 1")
        XCTAssertFalse(ucis(p).contains("e1g1"))
        XCTAssertFalse(ucis(p).contains("e1c1"))
    }

    // MARK: En passant

    func testEnPassantHorizontalPin() throws {
        // Black pawn e4 capturing d3 e.p. would open the 4th rank: Ka4 vs Qh4.
        let p = try pos("8/8/8/8/k2Pp2Q/8/8/3K4 b - d3 0 1")
        XCTAssertFalse(ucis(p).contains("e4d3"))
        XCTAssertTrue(ucis(p).contains("e4e3"))
    }

    func testEnPassantLegalWhenNotPinned() throws {
        let p = try pos("4k3/8/8/8/3Pp3/8/8/4K3 b - d3 0 1")
        XCTAssertTrue(ucis(p).contains("e4d3"))
        let after = p.applying(mv("e4d3"))
        XCTAssertEqual(after.fen, "4k3/8/8/8/8/3p4/8/4K3 w - - 0 2")
    }

    func testEnPassantCapturesCheckingPawn() throws {
        // White pawn on d4 just pushed from d2... black king e5 is attacked by the d4 pawn; exd3 removes it.
        let p = try pos("8/8/8/4k3/3Pp3/8/8/4K3 b - d3 0 1")
        XCTAssertTrue(p.isInCheck)
        XCTAssertTrue(ucis(p).contains("e4d3"))
    }

    func testEnPassantOnlyImmediately() throws {
        let p = try pos("4k2n/8/8/8/4p3/8/3P4/4K3 w - - 0 1")
        let a = play(p, "d2d4")
        XCTAssertEqual(a.enPassant, Square("d3"))
        XCTAssertTrue(ucis(a).contains("e4d3"))
        // Black plays something else; White plays something; the chance is gone.
        let b = play(a, "h8g6", "e1e2", "g6h8")
        XCTAssertNil(b.enPassant)
        XCTAssertFalse(ucis(b).contains("e4d3"))
    }

    func testEnPassantTargetSetOnlyAfterDoublePush() throws {
        let p = play(.start, "e2e3")
        XCTAssertNil(p.enPassant)
        let q = play(.start, "e2e4")
        XCTAssertEqual(q.enPassant, Square("e3"))
        XCTAssertEqual(q.fen, "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1")
    }

    // MARK: Promotion

    func testPromotionProducesFourMoves() throws {
        let p = try pos("4k3/P7/8/8/8/8/8/4K3 w - - 0 1")
        let promos = p.legalMoves(from: Square("a7")!)
        XCTAssertEqual(Set(promos.map(\.uci)), ["a7a8q", "a7a8r", "a7a8b", "a7a8n"])
        let after = p.applying(mv("a7a8n"))
        XCTAssertEqual(after[Square("a8")!], Piece(color: .white, kind: .knight))
        let c = try pos("1n2k3/P7/8/8/8/8/8/4K3 w - - 0 1")
        XCTAssertEqual(c.legalMoves(from: Square("a7")!).count, 8)   // 4 pushes + 4 captures
    }

    // MARK: Clocks

    func testClocksInApplying() throws {
        var p = Position.start
        p = play(p, "g1f3")
        XCTAssertEqual(p.halfmoveClock, 1)
        XCTAssertEqual(p.fullmoveNumber, 1)
        XCTAssertEqual(p.sideToMove, .black)
        p = play(p, "g8f6")
        XCTAssertEqual(p.halfmoveClock, 2)
        XCTAssertEqual(p.fullmoveNumber, 2)
        p = play(p, "e2e4")
        XCTAssertEqual(p.halfmoveClock, 0, "pawn move resets")
        p = play(p, "f6e4")
        XCTAssertEqual(p.halfmoveClock, 0, "capture resets")
        XCTAssertEqual(p.fullmoveNumber, 3)
        p = play(p, "f1e2")
        XCTAssertEqual(p.halfmoveClock, 1)
        XCTAssertEqual(p.fullmoveNumber, 3)
        let e = try pos("4k3/8/8/8/3Pp3/8/8/4K3 b - d3 7 20")
        XCTAssertEqual(e.applying(mv("e4d3")).halfmoveClock, 0, "en passant resets")
    }

    // MARK: Check and attacks

    func testCheckAndAttackQueries() throws {
        let p = try pos("4k3/8/8/8/8/8/4r3/4K3 w - - 0 1")
        XCTAssertTrue(p.isInCheck)
        XCTAssertEqual(p.kingSquare(of: .white), Square("e1"))
        XCTAssertEqual(p.kingSquare(of: .black), Square("e8"))
        XCTAssertTrue(p.isAttacked(Square("e1")!, by: .black))
        XCTAssertTrue(p.isAttacked(Square("a2")!, by: .black))
        XCTAssertFalse(p.isAttacked(Square("a3")!, by: .black))
        XCTAssertFalse(Position.start.isInCheck)
        XCTAssertTrue(Position.start.isAttacked(Square("e3")!, by: .white))
        XCTAssertTrue(Position.start.isAttacked(Square("f6")!, by: .black))
        XCTAssertFalse(Position.start.isAttacked(Square("e4")!, by: .white))
        XCTAssertNil(Position(fen: "8/8/8/8/8/8/8/4K3 w - - 0 1")!.kingSquare(of: .black))
    }

    func testMateAndStalemateHaveNoMoves() throws {
        let mate = try pos("rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3")
        XCTAssertTrue(mate.isInCheck)
        XCTAssertTrue(mate.legalMoves().isEmpty)
        let stale = try pos("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
        XCTAssertFalse(stale.isInCheck)
        XCTAssertTrue(stale.legalMoves().isEmpty)
    }

    func testPinnedPieceStaysOnLine() throws {
        // Bishop e2 pinned along the e-file by the rook on e8: it cannot move at all.
        let p = try pos("4r1k1/8/8/8/8/8/4B3/4K3 w - - 0 1")
        XCTAssertTrue(p.legalMoves(from: Square("e2")!).isEmpty)
        // A pinned rook can slide along the pin and capture the pinner.
        let r = try pos("4r1k1/8/8/8/8/8/4R3/4K3 w - - 0 1")
        XCTAssertEqual(Set(r.legalMoves(from: Square("e2")!).map(\.uci)),
                       ["e2e3", "e2e4", "e2e5", "e2e6", "e2e7", "e2e8"])
    }

    func testLegalMovesFromSquare() {
        XCTAssertEqual(Set(Position.start.legalMoves(from: Square("e2")!).map(\.uci)), ["e2e3", "e2e4"])
        XCTAssertEqual(Set(Position.start.legalMoves(from: Square("g1")!).map(\.uci)), ["g1f3", "g1h3"])
        XCTAssertTrue(Position.start.legalMoves(from: Square("e4")!).isEmpty)
        XCTAssertTrue(Position.start.legalMoves(from: Square("e7")!).isEmpty)   // not the side to move
    }

    // MARK: Insufficient material

    func testInsufficientMaterial() throws {
        let yes = [
            "4k3/8/8/8/8/8/8/4K3 w - - 0 1",
            "4k3/8/8/8/8/8/8/3BK3 w - - 0 1",
            "4k3/8/8/8/8/8/8/3NK3 w - - 0 1",
            "3bk3/8/8/8/8/8/8/4K3 w - - 0 1",
            "3nk3/8/8/8/8/8/8/4K3 w - - 0 1",
            "1b2k3/8/8/8/8/8/8/2B1K3 w - - 0 1",   // b8 and c1: both dark squares
            "4k3/8/8/8/8/8/8/4KB2 w - - 0 1",
        ]
        for f in yes { XCTAssertTrue(try pos(f).hasInsufficientMaterial, f) }
        let no = [
            "4k1b1/8/8/8/8/8/8/2B1K3 w - - 0 1",       // g8 light, c1 dark: opposite colours
            "4k3/8/8/8/8/8/8/2NNK3 w - - 0 1",
            "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1",
            "4k3/8/8/8/8/8/8/R3K3 w - - 0 1",
            "4k3/8/8/8/8/8/8/Q3K3 w - - 0 1",
            "4k3/8/8/8/8/8/8/2BBK3 w - - 0 1",         // two bishops, one side
            "4k3/8/8/8/8/8/8/2BNK3 w - - 0 1",
            "4k1n1/8/8/8/8/8/8/2B1K3 w - - 0 1",       // B v N
            "4k1n1/8/8/8/8/8/8/4K1N1 w - - 0 1",       // N v N
        ]
        for f in no { XCTAssertFalse(try pos(f).hasInsufficientMaterial, f) }
        XCTAssertFalse(Position.start.hasInsufficientMaterial)
    }

    // MARK: Repetition key

    func testRepetitionKey() throws {
        let start = Position.start
        let back = play(start, "g1f3", "g8f6", "f3g1", "f6g8")
        XCTAssertNotEqual(start, back, "clocks differ")
        XCTAssertEqual(start.repetitionKey, back.repetitionKey)
        let half = play(start, "g1f3", "g8f6", "f3g1")
        XCTAssertNotEqual(start.repetitionKey, half.repetitionKey, "side to move differs")
        let a = try pos("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        let b = try pos("r3k2r/8/8/8/8/8/8/R3K2R w Qkq - 0 1")
        let c = try pos("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 5 9")
        XCTAssertNotEqual(a.repetitionKey, b.repetitionKey)
        XCTAssertEqual(a.repetitionKey, c.repetitionKey)
        let e1 = try pos("4k3/8/8/8/3Pp3/8/8/4K3 b - d3 0 1")
        let e2 = try pos("4k3/8/8/8/3Pp3/8/8/4K3 b - - 0 1")
        XCTAssertNotEqual(e1.repetitionKey, e2.repetitionKey)
        // Losing castling rights by moving a rook out and back changes the key.
        let rooks = play(a, "h1g1", "e8e7", "g1h1", "e7e8")
        XCTAssertNotEqual(a.repetitionKey, rooks.repetitionKey)
    }

    // MARK: Random playout sanity

    func testRandomPlayoutsStayConsistent() throws {
        var seed: UInt64 = 12345
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33)
        }
        for _ in 0..<30 {
            var p = Position.start
            for _ in 0..<120 {
                let moves = p.legalMoves()
                if moves.isEmpty { break }
                let m = moves[next() % moves.count]
                let q = p.applying(m)
                // The side that just moved must never be left in check.
                XCTAssertFalse(q.isAttacked(q.kingSquare(of: p.sideToMove)!, by: q.sideToMove), "\(p.fen) \(m.uci)")
                XCTAssertEqual(Position(fen: q.fen), q)
                p = q
            }
        }
    }
}
