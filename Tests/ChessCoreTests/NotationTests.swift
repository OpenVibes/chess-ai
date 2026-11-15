import XCTest
@testable import ChessCore

final class NotationTests: XCTestCase {
    private func sanOf(_ fen: String, _ uci: String) -> String {
        let p = Position(fen: fen)!
        return san(for: legalMove(uci, in: p), in: p)
    }

    func testFileDisambiguation() {
        XCTAssertEqual(sanOf("4k3/8/8/8/8/5N2/8/1N2K3 w - - 0 1", "b1d2"), "Nbd2")
        XCTAssertEqual(sanOf("4k3/8/8/8/8/5N2/8/1N2K3 w - - 0 1", "f3d2"), "Nfd2")
    }

    func testRankDisambiguation() {
        XCTAssertEqual(sanOf("4k3/8/8/R7/8/8/8/R3K3 w - - 0 1", "a1a3"), "R1a3")
        XCTAssertEqual(sanOf("4k3/8/8/R7/8/8/8/R3K3 w - - 0 1", "a5a3"), "R5a3")
    }

    func testFileAndRankDisambiguation() {
        XCTAssertEqual(sanOf("8/k7/8/8/4Q2Q/2K5/8/7Q w - - 0 1", "h4e1"), "Qh4e1")
    }

    func testPinnedPieceDoesNotForceDisambiguation() {
        XCTAssertEqual(sanOf("4kr2/8/8/8/8/5N2/8/1N3K2 w - - 0 1", "b1d2"), "Nd2")
    }

    func testCastling() {
        XCTAssertEqual(sanOf("4k3/8/8/8/8/8/8/4K2R w K - 0 1", "e1g1"), "O-O")
        XCTAssertEqual(sanOf("r3k3/8/8/8/8/8/8/4K3 b q - 0 1", "e8c8"), "O-O-O")
    }

    func testEnPassant() {
        XCTAssertEqual(sanOf("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", "e5d6"), "exd6")
    }

    func testPromotionWithCaptureAndCheck() {
        XCTAssertEqual(sanOf("3r2k1/4P3/8/8/8/8/8/4K3 w - - 0 1", "e7d8q"), "exd8=Q+")
        XCTAssertEqual(sanOf("3r2k1/4P3/8/8/8/8/8/4K3 w - - 0 1", "e7d8n"), "exd8=N")
    }

    func testPlainCheckAndPlainMoves() {
        XCTAssertEqual(sanOf("4k3/8/8/8/8/8/8/4K2R w - - 0 1", "h1h8"), "Rh8+")
        XCTAssertEqual(sanOf("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "g1f3"), "Nf3")
        XCTAssertEqual(sanOf("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "e2e4"), "e4")
    }
}
