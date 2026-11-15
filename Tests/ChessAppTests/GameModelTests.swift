import XCTest
import ChessCore
import ChessEngine
@testable import ChessApp

@MainActor
final class GameModelTests: XCTestCase {
    private func sq(_ s: String) -> Square { Square(s)! }
    private func mv(_ s: String) -> Move {
        let u = Array(s)
        var promo: PieceKind?
        if u.count > 4 {
            promo = ["q": PieceKind.queen, "r": .rook, "b": .bishop, "n": .knight][u[4]]
        }
        return Move(from: sq(String(u[0..<2])), to: sq(String(u[2..<4])), promotion: promo)
    }
    private func play(_ model: GameModel, _ moves: String) {
        for m in moves.split(separator: " ") { XCTAssertTrue(model.perform(mv(String(m))), "illegal \(m)") }
    }

    /// Polls until the condition holds or the timeout passes.
    private func wait(_ timeout: Double = 5, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func assertPiecesMatch(_ model: GameModel, file: StaticString = #filePath, line: UInt = #line) {
        let pos = model.game.position
        var expected: [Square: Piece] = [:]
        for i in 0..<64 {
            let s = Square(file: i & 7, rank: i >> 3)
            if let p = pos[s] { expected[s] = p }
        }
        XCTAssertEqual(model.pieces.count, expected.count, file: file, line: line)
        for item in model.pieces {
            XCTAssertEqual(expected[item.square], item.piece, "at \(item.square.algebraic)", file: file, line: line)
        }
        XCTAssertEqual(Set(model.pieces.map(\.id)).count, model.pieces.count, "ids unique", file: file, line: line)
        XCTAssertEqual(Set(model.pieces.map(\.square)).count, model.pieces.count, "squares unique", file: file, line: line)
    }

    private func id(at square: String, _ model: GameModel) -> Int? {
        model.pieces.first { $0.square == sq(square) }?.id
    }

    // MARK: Selection

    func testSelectionFlow() {
        let m = GameModel()
        m.tap(sq("e2"))
        XCTAssertEqual(m.selected, sq("e2"))
        XCTAssertEqual(m.legalTargets, [sq("e3"), sq("e4")])
        m.tap(sq("e2"))
        XCTAssertNil(m.selected)
        m.tap(sq("e2"))
        m.tap(sq("d2"))
        XCTAssertEqual(m.selected, sq("d2"))
        m.tap(sq("e5"))
        XCTAssertNil(m.selected)
        m.tap(sq("e7"))
        XCTAssertNil(m.selected)
        XCTAssertTrue(m.game.history.isEmpty)
        m.tap(sq("e2"))
        m.tap(sq("e4"))
        XCTAssertEqual(m.game.history.count, 1)
        XCTAssertNil(m.selected)
        XCTAssertEqual(m.sideToMove, .black)
    }

    func testIllegalTryMoveChangesNothing() {
        let m = GameModel()
        let fen = m.game.position.fen
        XCTAssertFalse(m.tryMove(from: sq("e2"), to: sq("e5")))
        XCTAssertFalse(m.tryMove(from: sq("e4"), to: sq("e5")))
        XCTAssertEqual(m.game.position.fen, fen)
        XCTAssertTrue(m.game.history.isEmpty)
        XCTAssertNil(m.pendingPromotion)
    }

    // MARK: Promotion

    func testPromotion() {
        let fen = "8/4P3/8/8/8/8/8/k6K w - - 0 1"
        let m = GameModel(position: Position(fen: fen)!)
        XCTAssertTrue(m.tryMove(from: sq("e7"), to: sq("e8")))
        XCTAssertEqual(m.pendingPromotion, PendingPromotion(from: sq("e7"), to: sq("e8")))
        XCTAssertEqual(m.game.position.fen, fen)
        m.choosePromotion(.knight)
        XCTAssertNil(m.pendingPromotion)
        XCTAssertEqual(m.game.history.last?.san, "e8=N")
        XCTAssertEqual(m.game.position[sq("e8")], Piece(color: .white, kind: .knight))
        assertPiecesMatch(m)

        let c = GameModel(position: Position(fen: fen)!)
        c.tryMove(from: sq("e7"), to: sq("e8"))
        c.cancelPromotion()
        XCTAssertNil(c.pendingPromotion)
        XCTAssertEqual(c.game.position.fen, fen)
        XCTAssertTrue(c.game.history.isEmpty)
    }

    // MARK: Piece identity

    func testIdentityCastling() {
        let m = GameModel(position: Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")!)
        let king = id(at: "e1", m), rook = id(at: "h1", m)
        let before = m.pieces
        XCTAssertTrue(m.perform(mv("e1g1")))
        assertPiecesMatch(m)
        XCTAssertEqual(id(at: "g1", m), king)
        XCTAssertEqual(id(at: "f1", m), rook)
        m.undo()
        XCTAssertEqual(m.pieces, before)
    }

    func testIdentityEnPassant() {
        let m = GameModel()
        play(m, "e2e4 a7a6 e4e5 d7d5")
        let pawn = id(at: "e5", m)
        let before = m.pieces
        XCTAssertTrue(m.perform(mv("e5d6")))
        assertPiecesMatch(m)
        XCTAssertEqual(id(at: "d6", m), pawn)
        XCTAssertNil(m.pieces.first { $0.square == sq("d5") })
        XCTAssertEqual(m.pieces.count, before.count - 1)
        m.undo()
        XCTAssertEqual(m.pieces, before)
    }

    func testIdentityCapture() {
        let m = GameModel()
        play(m, "e2e4 d7d5")
        let pawn = id(at: "e4", m)
        let before = m.pieces
        XCTAssertTrue(m.perform(mv("e4d5")))
        assertPiecesMatch(m)
        XCTAssertEqual(id(at: "d5", m), pawn)
        XCTAssertEqual(m.pieces.count, 31)
        m.undo()
        XCTAssertEqual(m.pieces, before)
    }

    func testIdentityPromotion() {
        let m = GameModel(position: Position(fen: "1n2k3/P7/8/8/8/8/8/4K3 w - - 0 1")!)
        let pawn = id(at: "a7", m)
        let before = m.pieces
        XCTAssertTrue(m.perform(mv("a7b8q")))
        assertPiecesMatch(m)
        XCTAssertEqual(id(at: "b8", m), pawn)
        XCTAssertEqual(m.pieces.first { $0.id == pawn }?.piece, Piece(color: .white, kind: .queen))
        XCTAssertEqual(m.pieces.count, before.count - 1)
        m.undo()
        XCTAssertEqual(m.pieces, before)
    }

    // MARK: Undo, game over

    func testTwoPlayerUndo() {
        let m = GameModel()
        XCTAssertFalse(m.canUndo)
        play(m, "e2e4 e7e5")
        XCTAssertTrue(m.canUndo)
        m.undo()
        XCTAssertEqual(m.game.history.count, 1)
        XCTAssertEqual(m.sideToMove, .black)
        assertPiecesMatch(m)
    }

    func testGameOver() {
        let m = GameModel()
        play(m, "f2f3 e7e5 g2g4 d8h4")
        XCTAssertFalse(m.canInteract)
        XCTAssertTrue(m.showGameOverCard)
        XCTAssertEqual(m.resultText, "Checkmate. Black wins")
        XCTAssertEqual(m.statusText, "Checkmate. Black wins")
        m.gameOverDismissed = true
        XCTAssertFalse(m.showGameOverCard)
        XCTAssertFalse(m.canInteract)
        m.newGame(mode: .twoPlayers, humanColor: .white, difficulty: .medium)
        XCTAssertFalse(m.isGameOver)
        XCTAssertFalse(m.gameOverDismissed)
        XCTAssertNil(m.resultText)
        XCTAssertTrue(m.canInteract)
        XCTAssertEqual(m.statusText, "White to move")
    }

    func testPlayerNames() {
        let m = GameModel()
        XCTAssertEqual(m.playerName(.white), "White")
        XCTAssertEqual(m.playerName(.black), "Black")
        m.newGame(mode: .versusComputer, humanColor: .white, difficulty: .hard)
        XCTAssertEqual(m.playerName(.white), "You")
        XCTAssertEqual(m.playerName(.black), "Computer · Hard")
    }

    // MARK: Versus computer

    func testComputerReplies() async {
        let m = GameModel()
        m.newGame(mode: .versusComputer, humanColor: .white, difficulty: .easy)
        m.tap(sq("e2")); m.tap(sq("e4"))
        XCTAssertTrue(m.isThinking)
        XCTAssertEqual(m.statusText, "Computer is thinking…")
        XCTAssertFalse(m.canInteract)
        await wait { m.game.history.count == 2 && !m.isThinking }
        XCTAssertEqual(m.game.history.count, 2)
        XCTAssertFalse(m.isThinking)
        XCTAssertEqual(m.sideToMove, .white)
        XCTAssertTrue(m.canInteract)
        assertPiecesMatch(m)
    }

    func testComputerMovesFirstWhenHumanIsBlack() async {
        let m = GameModel()
        m.newGame(mode: .versusComputer, humanColor: .black, difficulty: .easy)
        XCTAssertTrue(m.isThinking)
        await wait { m.game.history.count == 1 && !m.isThinking }
        XCTAssertEqual(m.game.history.count, 1)
        XCTAssertEqual(m.sideToMove, .black)
        XCTAssertFalse(m.isThinking)
        XCTAssertFalse(m.whiteAtBottom)
    }

    func testUndoWhileThinkingCancels() async {
        let m = GameModel()
        m.newGame(mode: .versusComputer, humanColor: .white, difficulty: .hard)
        m.tap(sq("e2")); m.tap(sq("e4"))
        XCTAssertTrue(m.isThinking)
        XCTAssertTrue(m.canUndo)
        m.undo()
        XCTAssertTrue(m.game.history.isEmpty)
        XCTAssertFalse(m.isThinking)
        XCTAssertEqual(m.game.position, Position.start)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertTrue(m.game.history.isEmpty)
        XCTAssertFalse(m.isThinking)
    }

    func testUndoOnHumanTurnRemovesTwoPlies() async {
        let m = GameModel()
        m.newGame(mode: .versusComputer, humanColor: .white, difficulty: .easy)
        m.tap(sq("e2")); m.tap(sq("e4"))
        await wait { m.game.history.count == 2 && !m.isThinking }
        m.tap(sq("d2")); m.tap(sq("d4"))
        await wait { m.game.history.count == 4 && !m.isThinking }
        XCTAssertEqual(m.game.history.count, 4)
        m.undo()
        XCTAssertEqual(m.game.history.count, 2)
        XCTAssertEqual(m.sideToMove, .white)
        XCTAssertFalse(m.isThinking)
        assertPiecesMatch(m)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(m.game.history.count, 2)
    }

    func testNewGameWhileThinkingDiscardsOldResult() async {
        let m = GameModel()
        m.newGame(mode: .versusComputer, humanColor: .white, difficulty: .hard)
        m.tap(sq("e2")); m.tap(sq("e4"))
        XCTAssertTrue(m.isThinking)
        m.newGame(mode: .twoPlayers, humanColor: .white, difficulty: .easy)
        XCTAssertFalse(m.isThinking)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertTrue(m.game.history.isEmpty)
        XCTAssertFalse(m.isThinking)
        XCTAssertEqual(m.game.position, Position.start)
    }

    func testDisabledComputerDoesNotMove() async {
        let m = GameModel()
        m.computerEnabled = false
        m.newGame(mode: .versusComputer, humanColor: .black, difficulty: .easy)
        XCTAssertFalse(m.isThinking)
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(m.game.history.isEmpty)
    }
}
