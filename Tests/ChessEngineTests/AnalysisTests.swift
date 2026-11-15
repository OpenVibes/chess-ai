import XCTest
import ChessCore
@testable import ChessEngine

final class AnalysisTests: XCTestCase {
    private let mateIn1: [(name: String, fen: String)] = [
        ("back rank Ra8", "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1"),
        ("Qxf7 scholar", "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4"),
        ("black back rank Ra1", "r5k1/8/8/8/8/8/5PPP/6K1 b - - 0 1"),
        ("fool's mate Qh4", "rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2"),
    ]

    private let mateIn2: [(name: String, fen: String)] = [
        ("rook + pawn ending", "7k/3p4/8/8/K4R2/8/8/2R5 w - - 0 1"),
        ("two rooks", "8/8/8/7k/3RRK2/8/8/8 w - - 0 1"),
        ("queen + knight", "2k5/8/8/K7/3Q4/3N4/8/8 w - - 0 1"),
        ("rook ladder", "8/8/K7/7k/3R4/8/5R2/8 w - - 0 1"),
        ("king + rook", "k7/8/3K4/7R/8/8/8/8 w - - 0 1"),
        ("queen and king", "8/8/8/8/8/2Q5/7k/4K3 w - - 0 1"),
    ]

    /// Generous limits so results do not depend on machine speed.
    private let deep = AnalysisLimits(maxDepth: 6, budgetSeconds: 60)

    private func analyse(_ fen: String, limits: AnalysisLimits? = nil) -> PositionAnalysis {
        Engine.analyse(Game(position: position(fen)), limits: limits ?? deep)
    }

    private func assertPVLegal(_ a: PositionAnalysis, from fen: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        var p = position(fen)
        for m in a.principalVariation {
            XCTAssertTrue(p.legalMoves().contains(m), "illegal PV move \(m.uci) in \(fen)", file: file, line: line)
            p = p.applying(m)
        }
    }

    func testDefaultLimits() {
        let l = AnalysisLimits()
        XCTAssertEqual(l.maxDepth, 6)
        XCTAssertEqual(l.budgetSeconds, 0.8)
    }

    func testStartPositionIsRoughlyEqual() {
        let a = Engine.analyse(Game(), limits: deep)
        guard case .centipawns(let cp) = a.score else { return XCTFail("score \(a.score)") }
        XCTAssertLessThanOrEqual(abs(cp), 100)
        XCTAssertNotNil(a.bestMove)
        XCTAssertEqual(a.depth, 6)
    }

    func testMateInOneBothColours() {
        for (name, fen) in mateIn1 {
            let a = analyse(fen)
            let whiteToMove = position(fen).sideToMove == .white
            XCTAssertEqual(a.score, .mate(whiteToMove ? 1 : -1), name)
            guard let m = a.bestMove else { XCTFail(name); continue }
            XCTAssertTrue(isMate(position(fen).applying(m)), "\(name): \(m.uci)")
            XCTAssertEqual(a.principalVariation.count, 1, name)
        }
    }

    func testMateInTwoBothColours() {
        for (name, fen) in mateIn2 {
            let white = analyse(fen)
            XCTAssertEqual(white.score, .mate(2), name)
            assertPVLegal(white, from: fen)
            let black = analyse(mirrorFEN(fen))
            XCTAssertEqual(black.score, .mate(-2), "black: \(name)")
            assertPVLegal(black, from: mirrorFEN(fen))
        }
    }

    func testBeingMatedIsReportedForTheOpponent() {
        // Black to move, every move allows mate in 1 for White.
        let forced = "k7/8/1K6/8/8/8/8/7R b - - 0 1"
        let a = analyse(forced)
        XCTAssertEqual(a.score, .mate(1))
        let mirrored = analyse(mirrorFEN(forced))
        XCTAssertEqual(mirrored.score, .mate(-1))
    }

    func testHangingQueenIsTaken() {
        // The capturing side keeps a rook plus a minor piece, so the win stays far above +500
        // even after the queen is gone (bare-king endings would score 0 or a rook's worth).
        let whiteBishop = "4k3/pppp4/8/3q4/8/5B2/PPPP4/R3K3 w - - 0 1"
        let whiteKnight = "4k3/pppp4/8/3q4/8/2N5/PPPP4/R3K3 w - - 0 1"
        let cases: [(String, String, Bool)] = [
            (whiteBishop, "f3d5", true),
            (whiteKnight, "c3d5", true),
            (mirrorFEN(whiteBishop), "f6d4", false),
            (mirrorFEN(whiteKnight), "c6d4", false),
        ]
        for (fen, expected, whiteCaptures) in cases {
            let a = analyse(fen)
            XCTAssertEqual(a.bestMove?.uci, expected, fen)
            guard case .centipawns(let cp) = a.score else { XCTFail("\(fen): \(a.score)"); continue }
            if whiteCaptures { XCTAssertGreaterThan(cp, 500, fen) } else { XCTAssertLessThan(cp, -500, fen) }
        }
    }

    func testCheckmatedPositions() {
        // White is mated (fool's mate), then Black is mated (scholar's mate).
        let whiteMated = "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3"
        let blackMated = "r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4"
        let w = analyse(whiteMated)
        XCTAssertNil(w.bestMove)
        XCTAssertEqual(w.score, .centipawns(-100_000))
        XCTAssertTrue(w.principalVariation.isEmpty)
        let b = analyse(blackMated)
        XCTAssertNil(b.bestMove)
        XCTAssertEqual(b.score, .centipawns(100_000))
        XCTAssertTrue(b.principalVariation.isEmpty)
    }

    func testStalemate() {
        for fen in ["7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", "7K/5q2/6k1/8/8/8/8/8 w - - 0 1"] {
            let a = analyse(fen)
            XCTAssertNil(a.bestMove, fen)
            XCTAssertEqual(a.score, .centipawns(0), fen)
            XCTAssertTrue(a.principalVariation.isEmpty, fen)
        }
    }

    func testInsufficientMaterialIsZeroButHasAMove() {
        let a = analyse("8/8/8/4k3/8/8/4K3/8 w - - 0 1")
        XCTAssertNotNil(a.bestMove)
        XCTAssertEqual(a.score, .centipawns(0))
        XCTAssertEqual(a.principalVariation, a.bestMove.map { [$0] })
    }

    func testPrincipalVariationStartsWithBestMoveAndIsLegal() {
        let fens = [
            Position.start.fen,
            "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
            "4k3/8/8/3q4/8/8/8/3RK3 w - - 0 1",
        ]
        for fen in fens {
            let a = analyse(fen)
            XCTAssertNotNil(a.bestMove, fen)
            XCTAssertEqual(a.principalVariation.first, a.bestMove, fen)
            assertPVLegal(a, from: fen)
        }
    }

    func testDefaultLimitsReturnQuickly() {
        let fens = [Position.start.fen, "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"]
        for fen in fens {
            let start = now()
            let a = Engine.analyse(Game(position: position(fen)))
            let t = seconds(since: start)
            XCTAssertLessThan(t, 1.5, fen)
            XCTAssertNotNil(a.bestMove)
            XCTAssertGreaterThanOrEqual(a.depth, 1)
            print("analyse default \(fen.prefix(20)): depth \(a.depth) in \(t)s")
        }
    }

    func testShouldStopEndsPromptlyWithLegalMove() {
        let fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
        let p = position(fen)
        let t0 = now()
        let a = Engine.analyse(Game(position: p), limits: AnalysisLimits(maxDepth: 60, budgetSeconds: 60),
                               shouldStop: { seconds(since: t0) > 0.1 })
        XCTAssertLessThan(seconds(since: t0), 1.0)
        XCTAssertNotNil(a.bestMove)
        if let m = a.bestMove { XCTAssertTrue(p.legalMoves().contains(m)) }
        XCTAssertEqual(a.principalVariation.first, a.bestMove)
        assertPVLegal(a, from: fen)

        // Already stopped: still a legal move, depth 0, static score.
        let b = Engine.analyse(Game(position: p), shouldStop: { true })
        XCTAssertNotNil(b.bestMove)
        if let m = b.bestMove { XCTAssertTrue(p.legalMoves().contains(m)) }
        XCTAssertEqual(b.depth, 0)
        XCTAssertEqual(b.principalVariation.first, b.bestMove)
        XCTAssertEqual(b.score, .centipawns(Engine.evaluate(p)))
    }

    func testZeroBudgetStillGivesAMove() {
        let a = Engine.analyse(Game(), limits: AnalysisLimits(maxDepth: 6, budgetSeconds: 0))
        XCTAssertNotNil(a.bestMove)
        XCTAssertGreaterThanOrEqual(a.depth, 1)
    }

    func testDeterministic() {
        let fens = [Position.start.fen,
                    "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
                    "7k/3p4/8/8/K4R2/8/8/2R5 w - - 0 1"]
        let limits = AnalysisLimits(maxDepth: 4, budgetSeconds: 60)
        for fen in fens {
            let g = Game(position: position(fen))
            let a = Engine.analyse(g, limits: limits)
            let b = Engine.analyse(g, limits: limits)
            XCTAssertEqual(a.bestMove, b.bestMove, fen)
            XCTAssertEqual(a.score, b.score, fen)
            XCTAssertEqual(a.principalVariation, b.principalVariation, fen)
            XCTAssertEqual(a.depth, b.depth, fen)
        }
    }

    func testBestMoveUnchangedByAnalysisSupport() {
        // Engine.bestMove (hard) must still find a mate in 1.
        let p = position(mateIn1[0].fen)
        let m = Engine.bestMove(in: Game(position: p), difficulty: .hard)
        XCTAssertTrue(m.map { isMate(p.applying($0)) } ?? false)
    }

    func testScoreConversion() {
        XCTAssertEqual(Engine.whiteScore(Searcher.mate - 1, whiteToMove: true), .mate(1))
        XCTAssertEqual(Engine.whiteScore(Searcher.mate - 3, whiteToMove: true), .mate(2))
        XCTAssertEqual(Engine.whiteScore(Searcher.mate - 1, whiteToMove: false), .mate(-1))
        XCTAssertEqual(Engine.whiteScore(-Searcher.mate + 2, whiteToMove: true), .mate(-1))
        XCTAssertEqual(Engine.whiteScore(-Searcher.mate + 4, whiteToMove: false), .mate(2))
        XCTAssertEqual(Engine.whiteScore(37, whiteToMove: false), .centipawns(-37))
    }
}
