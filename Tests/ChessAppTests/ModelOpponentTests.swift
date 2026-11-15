import XCTest
import ChessCore
import ChessEngine
import ChessCoach
@testable import ChessApp

/// Answers with queued replies (Anthropic response shape) or a status, recording each request body.
final class QueuedTransport: LLMTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private var _bodies: [String] = []
    var status: Int
    let delay: Double
    var bodies: [String] { lock.lock(); defer { lock.unlock() }; return _bodies }
    var count: Int { bodies.count }

    init(_ replies: [String] = [], status: Int = 200, delay: Double = 0) {
        self.replies = replies; self.status = status; self.delay = delay
    }

    func queue(_ reply: String) { lock.lock(); replies.append(reply); lock.unlock() }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        _bodies.append(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
        let reply = replies.isEmpty ? "" : replies.removeFirst()
        let code = status
        lock.unlock()
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        let json: [String: Any] = ["content": [["type": "text", "text": reply]], "stop_reason": "end_turn"]
        let body = code == 200 ? try JSONSerialization.data(withJSONObject: json) : Data(#"{"error":{"message":"bad key"}}"#.utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class ModelOpponentTests: XCTestCase {
    private func makeModel(_ transport: LLMTransport, human: PieceColor = .white) -> GameModel {
        let settings = CoachSettings.inMemory(keys: ["api.anthropic.com": "sk-test-key"])
        let model = GameModel(settings: settings, transport: transport, analysisLimits: AnalysisLimits(maxDepth: 2, budgetSeconds: 0.1))
        model.minimumThinkTime = 0
        model.newGame(mode: .versusModel, humanColor: human, difficulty: .medium)
        return model
    }

    private func e2e4(_ model: GameModel) {
        XCTAssertTrue(model.perform(Move(from: Square("e2")!, to: Square("e4")!, promotion: nil)))
    }

    private func wait(_ timeout: Double = 8, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testLegalReplyIsPlayed() async {
        let t = QueuedTransport(["I like it.\nMOVE: e5"])
        let m = makeModel(t)
        e2e4(m)
        XCTAssertFalse(m.canInteract)
        await wait { m.game.history.count == 2 }
        XCTAssertEqual(m.game.history.map(\.san), ["e4", "e5"])
        XCTAssertEqual(t.count, 1)
        XCTAssertFalse(m.isThinking)
        XCTAssertTrue(m.canInteract)
        XCTAssertNil(m.opponentMessage)
    }

    func testIllegalThenLegalRetries() async {
        let t = QueuedTransport(["MOVE: Qh5", "MOVE: e5"])
        let m = makeModel(t)
        e2e4(m)
        await wait { m.game.history.count == 2 }
        XCTAssertEqual(m.game.history.last?.san, "e5")
        XCTAssertEqual(t.count, 2)
        XCTAssertTrue(t.bodies[1].contains("did not contain a legal move"))
    }

    func testThreeBadRepliesFallBackToEngine() async {
        let t = QueuedTransport(["MOVE: Qh5", "MOVE: Ke4", "no idea"])
        let m = makeModel(t)
        e2e4(m)
        await wait { m.game.history.count == 2 }
        XCTAssertEqual(m.game.history.count, 2)
        XCTAssertEqual(t.count, 3)
        let san = m.game.history[1].san
        XCTAssertEqual(m.opponentMessage, .notice("\(m.modelName) gave no legal move, so the engine played \(san)."))
        // the human's next move clears the notice
        await wait { !m.isThinking }
        XCTAssertTrue(m.canInteract)
    }

    func testHTTP401StopsThenTryAgainPlays() async {
        let t = QueuedTransport([], status: 401)
        let m = makeModel(t)
        e2e4(m)
        await wait { m.opponentMessage != nil }
        XCTAssertEqual(m.opponentMessage, .error(LLMError.unauthorized.localizedDescription))
        XCTAssertEqual(m.game.history.count, 1)
        XCTAssertFalse(m.isThinking)
        XCTAssertFalse(m.canInteract)
        t.status = 200
        t.queue("MOVE: e5")
        m.retryModelTurn()
        XCTAssertNil(m.opponentMessage)
        await wait { m.game.history.count == 2 }
        XCTAssertEqual(m.game.history.last?.san, "e5")
    }

    func testLetTheEngineMovePlaysLegalMove() async {
        let t = QueuedTransport([], status: 401)
        let m = makeModel(t)
        e2e4(m)
        await wait { m.opponentMessage != nil }
        m.letEngineMove()
        await wait { m.game.history.count == 2 }
        XCTAssertEqual(m.game.history.count, 2)
        XCTAssertNil(m.opponentMessage)
        XCTAssertTrue(m.canInteract)
    }

    func testUndoCancelsPendingRequest() async {
        let t = QueuedTransport(["MOVE: e5"], delay: 0.4)
        let m = makeModel(t)
        e2e4(m)
        await wait { t.count == 1 }
        XCTAssertTrue(m.isThinking)
        m.undo()
        XCTAssertEqual(m.game.history.count, 0)
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(m.game.history.count, 0)
        XCTAssertFalse(m.isThinking)
    }

    func testNewGameCancelsPendingRequest() async {
        let t = QueuedTransport(["MOVE: e5"], delay: 0.4)
        let m = makeModel(t)
        e2e4(m)
        await wait { t.count == 1 }
        m.newGame(mode: .versusModel, humanColor: .white, difficulty: .medium)
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(m.game.history.count, 0)
        XCTAssertEqual(m.game.position, Position.start)
    }

    func testHumanAsBlackModelMovesFirst() async {
        let t = QueuedTransport(["MOVE: d4"])
        let m = makeModel(t, human: .black)
        XCTAssertFalse(m.canInteract)
        XCTAssertFalse(m.whiteAtBottom)
        await wait { m.game.history.count == 1 }
        XCTAssertEqual(m.game.history.first?.san, "d4")
        XCTAssertTrue(m.canInteract)
    }

    func testStatusAndNames() {
        let t = QueuedTransport([], delay: 1)
        let m = makeModel(t)
        e2e4(m)
        XCTAssertEqual(m.statusText, "\(m.modelName) is thinking…")
        XCTAssertEqual(m.playerName(.black), m.modelName)
        XCTAssertEqual(m.playerName(.white), "You")
        m.undo()
    }
}
