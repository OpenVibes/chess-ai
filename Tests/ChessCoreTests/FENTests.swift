import XCTest
@testable import ChessCore

final class FENTests: XCTestCase {
    func testStartFEN() {
        XCTAssertEqual(Position.start.fen, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    }

    func testRoundTrip() throws {
        let fens = [
            PerftTests.startFEN, PerftTests.kiwipete, PerftTests.position3, PerftTests.position4,
            PerftTests.position5,
            "8/8/8/8/k2Pp2Q/8/8/3K4 b - d3 0 1",
            "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2",
            "4k3/8/8/8/8/8/8/4K3 b - - 37 90",
        ]
        for f in fens {
            XCTAssertEqual(try XCTUnwrap(Position(fen: f), f).fen, f)
        }
    }

    func testFieldsParsed() throws {
        let p = try XCTUnwrap(Position(fen: PerftTests.position5))
        XCTAssertEqual(p.sideToMove, .white)
        XCTAssertEqual(p.castling, [.whiteKingside, .whiteQueenside])
        XCTAssertNil(p.enPassant)
        XCTAssertEqual(p.halfmoveClock, 1)
        XCTAssertEqual(p.fullmoveNumber, 8)
        XCTAssertEqual(p[Square("d7")!], Piece(color: .white, kind: .pawn))
        XCTAssertEqual(p[Square("f2")!], Piece(color: .black, kind: .knight))
        XCTAssertNil(p[Square("e5")!])
        let e = try XCTUnwrap(Position(fen: "8/8/8/8/k2Pp2Q/8/8/3K4 b - d3 0 1"))
        XCTAssertEqual(e.enPassant, Square("d3"))
        XCTAssertEqual(e.sideToMove, .black)
    }

    func testMissingClocksDefault() throws {
        let p = try XCTUnwrap(Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -"))
        XCTAssertEqual(p.halfmoveClock, 0)
        XCTAssertEqual(p.fullmoveNumber, 1)
        XCTAssertEqual(p.fen, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    }

    func testMalformedReturnsNil() {
        let bad = [
            "",
            "garbage",
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP w KQkq - 0 1",                   // 7 ranks
            "rnbqkbnr/pppppppp/8/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",        // 9 ranks
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNX w KQkq - 0 1",          // bad piece
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBN w KQkq - 0 1",           // rank sums to 7
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNRR w KQkq - 0 1",         // rank sums to 9
            "rnbqkbnr/pppppppp/9/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",          // digit 9
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR x KQkq - 0 1",          // bad side
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkx - 0 1",          // bad castling
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KKkq - 0 1",          // duplicate castling
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq e9 0 1",         // bad ep square
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq e3 0 1",         // ep on wrong rank for side
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - x 1",          // bad halfmove
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 0",          // bad fullmove
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0",            // 5 fields
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w",                     // 2 fields
            "pnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",          // pawn on back rank
        ]
        for f in bad { XCTAssertNil(Position(fen: f), f) }
    }
}
