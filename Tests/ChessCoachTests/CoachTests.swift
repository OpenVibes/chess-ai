import XCTest
import ChessCore
import ChessEngine
@testable import ChessCoach

final class CoachTests: XCTestCase {
    private func pos(_ fen: String) -> Position { Position(fen: fen)! }

    private func move(_ uci: String, in p: Position) -> Move {
        p.legalMoves().first { $0.uci == uci }!
    }

    private func record(_ fen: String, _ uci: String) -> (MoveRecord, Position) {
        var g = Game(position: pos(fen))
        let m = move(uci, in: g.position)
        XCTAssertTrue(g.play(m))
        return (g.history.last!, g.position)
    }

    private func pa(_ best: Move?, _ score: Score, pv: [Move]? = nil) -> PositionAnalysis {
        PositionAnalysis(bestMove: best, score: score, principalVariation: pv ?? (best.map { [$0] } ?? []), depth: 6)
    }

    func testWinChance() {
        XCTAssertEqual(Coach.winChance(.centipawns(0), for: .white), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Coach.winChance(.centipawns(0), for: .black), 0.5, accuracy: 1e-9)
        let w = Coach.winChance(.centipawns(200), for: .white)
        let b = Coach.winChance(.centipawns(-200), for: .white)
        XCTAssertEqual(w + b, 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(w, 0.6)
        XCTAssertEqual(Coach.winChance(.centipawns(200), for: .black), b, accuracy: 1e-9)
        XCTAssertEqual(Coach.winChance(.mate(3), for: .white), 1)
        XCTAssertEqual(Coach.winChance(.mate(-3), for: .white), 0)
        XCTAssertEqual(Coach.winChance(.mate(2), for: .black), 0)
        XCTAssertEqual(Coach.winChance(.centipawns(100_000), for: .white), 1)
        XCTAssertEqual(Coach.winChance(.centipawns(-100_000), for: .white), 0)
    }

    func testThresholds() {
        let c = { Coach.classify(winChanceLost: $0, playedBest: false) }
        XCTAssertEqual(c(0), .best)
        XCTAssertEqual(c(0.0049), .best)
        XCTAssertEqual(c(0.005), .excellent)
        XCTAssertEqual(c(0.0199), .excellent)
        XCTAssertEqual(c(0.02), .good)
        XCTAssertEqual(c(0.0499), .good)
        XCTAssertEqual(c(0.05), .inaccuracy)
        XCTAssertEqual(c(0.0999), .inaccuracy)
        XCTAssertEqual(c(0.10), .mistake)
        XCTAssertEqual(c(0.1999), .mistake)
        XCTAssertEqual(c(0.20), .blunder)
        XCTAssertEqual(Coach.classify(winChanceLost: 0.9, playedBest: true), .best)
    }

    func testPlayingEngineMoveIsBest() {
        let (rec, _) = record("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "e2e4")
        let r = Coach.review(record: rec, before: pa(rec.move, .centipawns(30)), after: pa(nil, .centipawns(-900)))
        XCTAssertEqual(r.quality, .best)
        XCTAssertEqual(r.winChanceLost, 0)
        XCTAssertEqual(r.summary, "Best move.")
    }

    func testSingleLegalMoveIsBest() {
        // White king a1 in check from rook on h1... only Kb2 is legal? use a known forced position.
        let fen = "7k/8/8/8/8/8/1r6/K7 w - - 0 1"
        let p = pos(fen)
        let legal = p.legalMoves()
        XCTAssertEqual(legal.count, 1)
        let (rec, _) = record(fen, legal[0].uci)
        let other = move("a1a2", in: pos("7k/8/8/8/8/8/8/K7 w - - 0 1"))
        let r = Coach.review(record: rec, before: pa(other, .centipawns(-500)), after: pa(nil, .centipawns(-900)))
        XCTAssertEqual(r.quality, .best)
        XCTAssertEqual(r.winChanceLost, 0)
    }

    func testBlackPointOfView() {
        let fen = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        let (rec, _) = record(fen, "a7a6")
        let best = move("e7e5", in: pos(fen))
        // Black loses 300 cp relative to best: White's score rises.
        let r = Coach.review(record: rec, before: pa(best, .centipawns(-20)), after: pa(nil, .centipawns(300)))
        XCTAssertEqual(r.mover, .black)
        let expected = Coach.winChance(.centipawns(-20), for: .black) - Coach.winChance(.centipawns(300), for: .black)
        XCTAssertEqual(r.winChanceLost, expected, accuracy: 1e-9)
        XCTAssertGreaterThan(r.winChanceLost, 0.2)
        XCTAssertEqual(r.quality, .blunder)
        XCTAssertEqual(r.bestSAN, "e5")
        XCTAssertEqual(r.summary, "Blunder. e5 was better.")
        // An improvement for Black never gives negative loss.
        let r2 = Coach.review(record: rec, before: pa(best, .centipawns(-20)), after: pa(nil, .centipawns(-400)))
        XCTAssertEqual(r2.winChanceLost, 0)
        XCTAssertEqual(r2.quality, .best)
    }

    func testBestLineWalksAndStopsAtIllegal() {
        let start = Position.start
        let e4 = move("e2e4", in: start)
        let e5 = move("e7e5", in: start.applying(e4))
        let nf3 = move("g1f3", in: start.applying(e4).applying(e5))
        let bogus = Move(from: Square(file: 0, rank: 0), to: Square(file: 7, rank: 7))
        let (rec, _) = record("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "d2d4")
        let r = Coach.review(record: rec, before: pa(e4, .centipawns(30), pv: [e4, e5, nf3, bogus, e4]), after: pa(nil, .centipawns(30)))
        XCTAssertEqual(r.bestLine, ["e4", "e5", "Nf3"])
        let r2 = Coach.review(record: rec, before: pa(e4, .centipawns(30), pv: [e4, e5, nf3, move("b8c6", in: start.applying(e4).applying(e5).applying(nf3)), e4]), after: pa(nil, .centipawns(30)))
        XCTAssertEqual(r2.bestLine.count, 4)
    }

    func testMissedMateCopy() {
        let fen = "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1"
        let (rec, _) = record(fen, "g1h1")
        let mate = move("a1a8", in: pos(fen))
        let r = Coach.review(record: rec, before: pa(mate, .mate(1)), after: pa(nil, .centipawns(0)))
        XCTAssertEqual(r.quality, .blunder)
        XCTAssertEqual(r.summary, "Blunder. You missed mate in 1 with Ra8#.")
        // Black missing its own mate (negative score).
        let bfen = "r5k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 1"
        let (brec, _) = record(bfen, "g8h8")
        let bm = move("a8a1", in: pos(bfen))
        let br = Coach.review(record: brec, before: pa(bm, .mate(-1)), after: pa(nil, .centipawns(0)))
        XCTAssertEqual(br.summary, "Blunder. You missed mate in 1 with Ra1#.")
    }

    func testAllowedMateCopy() {
        let fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        let (rec, _) = record(fen, "f2f3")
        let best = move("e2e4", in: pos(fen))
        let r = Coach.review(record: rec, before: pa(best, .centipawns(20)), after: pa(nil, .mate(-2)))
        XCTAssertEqual(r.quality, .blunder)
        XCTAssertEqual(r.summary, "Blunder. This allows mate in 2.")
        // Already lost to mate before: plain copy.
        let r2 = Coach.review(record: rec, before: pa(best, .mate(-3)), after: pa(nil, .mate(-2)))
        XCTAssertFalse(r2.summary.contains("allows"))
    }

    func testSummaryCopyAllQualities() {
        func review(_ q: MoveQuality) -> MoveReview {
            MoveReview(move: Move(from: Square(file: 4, rank: 1), to: Square(file: 4, rank: 3)), san: "e4", mover: .white, quality: q,
                       scoreBefore: .centipawns(0), scoreAfter: .centipawns(0),
                       bestMove: nil, bestSAN: "Nf3", bestLine: [], winChanceLost: 0)
        }
        XCTAssertEqual(review(.best).summary, "Best move.")
        XCTAssertEqual(review(.excellent).summary, "Excellent move.")
        XCTAssertEqual(review(.good).summary, "Good move.")
        XCTAssertEqual(review(.inaccuracy).summary, "Inaccuracy. Nf3 was better.")
        XCTAssertEqual(review(.mistake).summary, "Mistake. Nf3 was better.")
        XCTAssertEqual(review(.blunder).summary, "Blunder. Nf3 was better.")
        XCTAssertEqual(MoveQuality.allCases.map(\.displayName),
                       ["Best", "Excellent", "Good", "Inaccuracy", "Mistake", "Blunder"])
    }

    func testFormat() {
        XCTAssertEqual(Coach.format(.centipawns(130)), "+1.3")
        XCTAssertEqual(Coach.format(.centipawns(-40)), "\u{2212}0.4")
        XCTAssertEqual(Coach.format(.centipawns(0)), "0.0")
        XCTAssertEqual(Coach.format(.centipawns(3)), "0.0")
        XCTAssertEqual(Coach.format(.centipawns(-3)), "0.0")
        XCTAssertEqual(Coach.format(.mate(3)), "M3")
        XCTAssertEqual(Coach.format(.mate(-2)), "\u{2212}M2")
        XCTAssertEqual(Coach.format(.centipawns(100_000)), "1-0")
        XCTAssertEqual(Coach.format(.centipawns(-100_000)), "0-1")
    }

    func testEndToEndQueenHang() {
        // Qg4?? walks the queen into Bc8xg4.
        let fen = "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 1"
        var g = Game(position: pos(fen))
        let hang = move("d1g4", in: g.position)
        let before = Engine.analyse(g, limits: AnalysisLimits(maxDepth: 4, budgetSeconds: 2))
        XCTAssertTrue(g.play(hang))
        let after = Engine.analyse(g, limits: AnalysisLimits(maxDepth: 4, budgetSeconds: 2))
        let r = Coach.review(record: g.history.last!, before: before, after: after)
        XCTAssertEqual(r.quality, .blunder)
        XCTAssertNotNil(r.bestSAN)
        XCTAssertNotEqual(r.bestSAN, r.san)
        XCTAssertTrue(r.summary.hasPrefix("Blunder. "))
        XCTAssertTrue(r.summary.hasSuffix("was better.") || r.summary.contains("mate"))
        XCTAssertFalse(r.bestLine.isEmpty)
    }

    func testEndToEndBlackQueenHang() {
        let fen = "rnbqkbnr/ppp2ppp/8/3pp3/3PP3/8/PPP2PPP/RNBQKBNR b KQkq - 0 1"
        var g = Game(position: pos(fen))
        let before = Engine.analyse(g, limits: AnalysisLimits(maxDepth: 4, budgetSeconds: 2))
        // Qg5?? hangs the queen to Bc1xg5.
        let hang = move("d8g5", in: g.position)
        XCTAssertTrue(g.play(hang))
        let after = Engine.analyse(g, limits: AnalysisLimits(maxDepth: 4, budgetSeconds: 2))
        let r = Coach.review(record: g.history.last!, before: before, after: after)
        XCTAssertEqual(r.mover, .black)
        XCTAssertEqual(r.quality, .blunder)
        XCTAssertTrue(r.summary.hasPrefix("Blunder. "))
    }
}
