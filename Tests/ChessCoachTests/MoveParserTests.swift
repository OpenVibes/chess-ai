import XCTest
import ChessCore
import ChessEngine
@testable import ChessCoach

final class MoveParserTests: XCTestCase {
    func uci(_ reply: String, _ fen: String? = nil) -> String? {
        let p = fen.flatMap { Position(fen: $0) } ?? .start
        return MoveParser.parse(reply, in: p)?.uci
    }

    func testSAN() {
        XCTAssertEqual(uci("Nf3"), "g1f3")
        XCTAssertEqual(uci("e4"), "e2e4")
        XCTAssertEqual(uci("1. e4"), "e2e4")
        XCTAssertEqual(uci("**Nf3**"), "g1f3")
    }

    func testUCI() {
        XCTAssertEqual(uci("g1f3"), "g1f3")
        XCTAssertEqual(uci("E2E4"), "e2e4")
    }

    func testDecorations() {
        XCTAssertEqual(uci("Nf3!?"), "g1f3")
        XCTAssertEqual(uci("Nf3+"), "g1f3")
        // Qh5 is legal here; trailing marks stripped
        XCTAssertEqual(uci("Qh5#?", "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"), "d1h5")
    }

    func testCastling() {
        let fen = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"
        XCTAssertEqual(uci("O-O", fen), "e1g1")
        XCTAssertEqual(uci("0-0", fen), "e1g1")
        XCTAssertEqual(uci("0-0-0", fen), "e1c1")
        XCTAssertEqual(uci("O-O-O+", fen), "e1c1")
        XCTAssertEqual(uci("MOVE: 0-0", fen), "e1g1")
    }

    func testPromotion() {
        let fen = "8/4P2k/8/8/8/8/8/K7 w - - 0 1"
        XCTAssertEqual(uci("e8=Q", fen), "e7e8q")
        XCTAssertEqual(uci("e8Q", fen), "e7e8q")
        XCTAssertEqual(uci("e8=N+", fen), "e7e8n")
        XCTAssertEqual(uci("e7e8q", fen), "e7e8q")
        XCTAssertEqual(uci("e7e8r", fen), "e7e8r")
        XCTAssertEqual(uci("e8", fen), nil)
    }

    func testMoveLineFirst() {
        XCTAssertEqual(uci("I considered e4 and d4 but prefer this.\nMOVE: Nf3"), "g1f3")
        XCTAssertEqual(uci("move: d4\nthanks"), "d2d4")
        XCTAssertEqual(uci("MOVE: Nf3 (developing)"), "g1f3")
    }

    func testProseFallbackLastLegalToken() {
        XCTAssertEqual(uci("I think the best choice here is Nf3."), "g1f3")
        XCTAssertEqual(uci("Rather than e4, I will play d4, a solid move."), "d2d4")
    }

    func testAmbiguousAndIllegal() {
        XCTAssertNil(uci("Nd2"))                 // not legal at start
        XCTAssertNil(uci("e5"))                  // illegal for white
        XCTAssertNil(uci("Qxf7#"))
        XCTAssertNil(uci(""))
        XCTAssertNil(uci("I resign, there is no move."))
        // two knights can reach d2 without disambiguation
        XCTAssertNil(uci("Nd2", "4k3/8/8/8/8/8/8/1N2KN2 w - - 0 1"))
        XCTAssertEqual(uci("Nbd2", "4k3/8/8/8/8/8/8/1N2KN2 w - - 0 1"), "b1d2")
    }

    func testPromptsMentionFacts() {
        var game = Game()
        game.play(game.position.legalMoves().first { $0.uci == "e2e4" }!)
        let p = CoachPrompts.opponentTurn(game: game)
        XCTAssertTrue(p.contains(game.position.fen))
        XCTAssertTrue(p.contains("Black"))
        XCTAssertTrue(p.contains("1. e4"))
        XCTAssertTrue(p.contains("MOVE: <san>"))
        XCTAssertTrue(p.contains("Nf6"))
        XCTAssertTrue(CoachPrompts.opponentRetry(rejected: "Zz9", legalSAN: ["e4", "d4"]).contains("e4 d4"))
        XCTAssertTrue(CoachPrompts.coachSystem.contains("two short sentences"))
    }

    func testExplainMovePrompt() {
        let before = Position.start
        let e4 = before.legalMoves().first { $0.uci == "e2e4" }!
        let review = MoveReview(move: e4, san: "e4", mover: .white, quality: .mistake,
                                scoreBefore: .centipawns(20), scoreAfter: .centipawns(-250),
                                bestMove: nil, bestSAN: "Nf3", bestLine: ["Nf3", "d5"], winChanceLost: 0.15)
        let p = CoachPrompts.explainMove(review: review, positionBefore: before, recentSAN: [])
        XCTAssertTrue(p.contains(before.fen))
        XCTAssertTrue(p.contains("Nf3"))
        XCTAssertTrue(p.contains("mistake"))
        XCTAssertTrue(p.contains("Black is clearly better"))
        XCTAssertFalse(p.contains("250"))
        let h = CoachPrompts.explainHint(position: before, bestSAN: "Nf3", line: ["Nf3"], recentSAN: [])
        XCTAssertTrue(h.contains("Nf3") && h.contains(before.fen))
    }
}
