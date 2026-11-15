import XCTest
@testable import ChessCore

/// Finds the legal move with this UCI string in `position`.
func legalMove(_ uci: String, in position: Position, file: StaticString = #filePath, line: UInt = #line) -> Move {
    guard let m = position.legalMoves().first(where: { $0.uci == uci }) else {
        XCTFail("\(uci) is not legal in \(position.fen)", file: file, line: line)
        return Move(from: Square(file: 0, rank: 0), to: Square(file: 0, rank: 0))
    }
    return m
}

extension Game {
    @discardableResult
    mutating func play(uci: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        play(legalMove(uci, in: position, file: file, line: line))
    }
}

final class GameTests: XCTestCase {
    func testFoolsMate() {
        var g = Game()
        for m in ["f2f3", "e7e5", "g2g4", "d8h4"] { XCTAssertTrue(g.play(uci: m)) }
        XCTAssertEqual(g.status, .checkmate(winner: .black))
        XCTAssertEqual(g.history.last?.san, "Qh4#")
        XCTAssertEqual(g.lastMove?.uci, "d8h4")
    }

    func testScholarsMate() {
        var g = Game()
        for m in ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7"] { XCTAssertTrue(g.play(uci: m)) }
        XCTAssertEqual(g.status, .checkmate(winner: .white))
        XCTAssertEqual(g.history.last?.san, "Qxf7#")
    }

    func testStalemate() {
        var g = Game(position: Position(fen: "7k/8/4Q1K1/8/8/8/8/8 w - - 0 1")!)
        XCTAssertEqual(g.status, .ongoing)
        XCTAssertTrue(g.play(uci: "e6f7"))
        XCTAssertEqual(g.position.fen, "7k/5Q2/6K1/8/8/8/8/8 b - - 1 1")
        XCTAssertEqual(g.status, .stalemate)
    }

    func testThreefoldRepetitionExactlyOnThirdOccurrence() {
        var g = Game()
        let cycle = ["g1f3", "g8f6", "f3g1", "f6g8"]
        for i in 0..<8 {
            XCTAssertEqual(g.status, .ongoing, "before ply \(i + 1)")
            XCTAssertTrue(g.play(uci: cycle[i % 4]))
            if i < 7 { XCTAssertEqual(g.status, .ongoing, "after ply \(i + 1)") }
        }
        XCTAssertEqual(g.status, .drawRepetition)
        XCTAssertEqual(g.repetitionKeys.count, 9)
    }

    func testFiftyMoveRule() {
        var g = Game(position: Position(fen: "4k3/8/8/8/8/8/8/R3K2R w - - 99 80")!)
        XCTAssertEqual(g.status, .ongoing)
        XCTAssertTrue(g.play(uci: "a1a2"))
        XCTAssertEqual(g.status, .drawFiftyMove)
    }

    func testCheckmateBeatsFiftyMove() {
        var g = Game(position: Position(fen: "6k1/5ppp/8/8/8/8/8/R3K3 w - - 99 80")!)
        XCTAssertTrue(g.play(uci: "a1a8"))
        XCTAssertEqual(g.status, .checkmate(winner: .white))
    }

    func testInsufficientMaterialAfterCapture() {
        var g = Game(position: Position(fen: "4k3/8/8/8/8/8/4r3/4K3 w - - 0 1")!)
        XCTAssertEqual(g.status, .ongoing)
        XCTAssertTrue(g.play(uci: "e1e2"))
        XCTAssertEqual(g.status, .drawInsufficientMaterial)
    }

    func testPlayRejectsIllegalAndAfterGameOver() {
        var g = Game()
        let illegal = Move(from: Square("e2")!, to: Square("e5")!)
        XCTAssertFalse(g.play(illegal))
        XCTAssertEqual(g.history.count, 0)
        XCTAssertEqual(g.position, Position.start)

        for m in ["f2f3", "e7e5", "g2g4", "d8h4"] { g.play(uci: m) }
        let count = g.history.count
        let fen = g.position.fen
        XCTAssertFalse(g.play(Move(from: Square("a2")!, to: Square("a3")!)))
        XCTAssertEqual(g.history.count, count)
        XCTAssertEqual(g.position.fen, fen)
    }

    func testUndoRestoresState() {
        var g = Game()
        XCTAssertFalse(g.undo())
        for m in ["e2e4", "d7d5", "e4d5"] { g.play(uci: m) }
        let snapshot = (g.position, g.history.count, g.status, g.captured(by: .white))
        XCTAssertEqual(snapshot.3, [Piece(color: .black, kind: .pawn)])
        g.play(uci: "d8d5")
        XCTAssertEqual(g.captured(by: .black), [Piece(color: .white, kind: .pawn)])
        XCTAssertTrue(g.undo())
        XCTAssertEqual(g.position, snapshot.0)
        XCTAssertEqual(g.history.count, snapshot.1)
        XCTAssertEqual(g.status, snapshot.2)
        XCTAssertEqual(g.captured(by: .white), snapshot.3)
        XCTAssertEqual(g.captured(by: .black), [])
        XCTAssertEqual(g.repetitionKeys.count, 4)
    }

    func testUndoAfterCheckmate() {
        var g = Game()
        for m in ["f2f3", "e7e5", "g2g4", "d8h4"] { g.play(uci: m) }
        XCTAssertEqual(g.status, .checkmate(winner: .black))
        XCTAssertTrue(g.undo())
        XCTAssertEqual(g.status, .ongoing)
        XCTAssertTrue(g.play(uci: "a7a6"))
    }

    func testCapturedIncludesEnPassant() {
        var g = Game()
        for m in ["e2e4", "a7a6", "e4e5", "d7d5", "e5d6"] { XCTAssertTrue(g.play(uci: m)) }
        XCTAssertEqual(g.history.last?.captured, Piece(color: .black, kind: .pawn))
        XCTAssertEqual(g.history.last?.san, "exd6")
        XCTAssertEqual(g.captured(by: .white), [Piece(color: .black, kind: .pawn)])
        XCTAssertEqual(g.captured(by: .black), [])
    }

    func testCapturedOrder() {
        var g = Game()
        for m in ["e2e4", "d7d5", "e4d5", "d8d5", "b1c3", "d5d8"] { g.play(uci: m) }
        XCTAssertEqual(g.captured(by: .white), [Piece(color: .black, kind: .pawn)])
        XCTAssertEqual(g.captured(by: .black), [Piece(color: .white, kind: .pawn)])
    }
}
