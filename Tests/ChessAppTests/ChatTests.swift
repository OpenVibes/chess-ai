import XCTest
import ChessCore
import ChessEngine
import ChessCoach
@testable import ChessApp

@MainActor
final class ChatTests: XCTestCase {
    private func makeModel(_ transport: LLMTransport, chat: Bool = true) -> GameModel {
        let settings = CoachSettings.inMemory(keys: ["api.anthropic.com": "sk-test-key"])
        settings.chatEnabled = chat
        let model = GameModel(settings: settings, transport: transport, analysisLimits: AnalysisLimits(maxDepth: 2, budgetSeconds: 0.1))
        model.minimumThinkTime = 0
        model.newGame(mode: .versusModel, humanColor: .white, difficulty: .medium)
        return model
    }

    private func wait(_ timeout: Double = 8, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func e2e4(_ m: GameModel) {
        XCTAssertTrue(m.perform(Move(from: Square("e2")!, to: Square("e4")!, promotion: nil)))
    }

    func testMoveReplyAddsTheOpponentsLineAndMood() async {
        let t = QueuedTransport(["SAY: Predictable. I love it.\nMOOD: amused\nMOVE: e5"])
        let m = makeModel(t)
        e2e4(m)
        await wait { m.game.history.count == 2 }
        XCTAssertEqual(t.count, 1, "the comment comes with the move, not in a second request")
        XCTAssertTrue(t.bodies[0].contains("SAY:"))
        XCTAssertTrue(t.bodies[0].contains("1. e4"))
        let kinds = m.chat.map(\.kind)
        XCTAssertTrue(kinds.contains(.humanMove(ply: 0, label: "1. e4")))
        XCTAssertEqual(kinds.last, .opponent(text: "Predictable. I love it.", move: "1\u{2026} e5"))
        XCTAssertEqual(m.mood, .amused)
    }

    func testSilentMoveBecomesAChip() async {
        let t = QueuedTransport(["MOVE: e5"])
        let m = makeModel(t)
        e2e4(m)
        await wait { m.game.history.count == 2 }
        XCTAssertEqual(m.chat.last?.kind, .opponentMove(label: "1\u{2026} e5"))
    }

    func testHumanMessageGetsAReply() async {
        let t = QueuedTransport(["SAY: Bring it on.\nMOOD: confident"])
        let m = makeModel(t)
        m.sendChat("  ready to lose?  ")
        XCTAssertEqual(m.chatPending, 1)
        await wait { m.chatPending == 0 }
        XCTAssertTrue(t.bodies[0].contains("ready to lose?"))
        XCTAssertEqual(m.chat.suffix(2).map(\.kind), [.human("ready to lose?"), .opponent(text: "Bring it on.", move: nil)])
        XCTAssertEqual(m.mood, .confident)
    }

    func testChatOffUsesThePlainPromptAndKeepsNoChat() async {
        let t = QueuedTransport(["MOVE: e5"])
        let m = makeModel(t, chat: false)
        XCTAssertFalse(m.chatActive)
        e2e4(m)
        await wait { m.game.history.count == 2 }
        XCTAssertFalse(t.bodies[0].contains("SAY:"))
        XCTAssertTrue(m.chat.isEmpty)
        m.sendChat("hello")
        XCTAssertTrue(m.chat.isEmpty)
    }

    func testNewGameClearsChatAndUndoLeavesANote() async {
        let t = QueuedTransport(["SAY: Hi.\nMOVE: e5"])
        let m = makeModel(t)
        e2e4(m)
        await wait { m.game.history.count == 2 }
        m.undo()
        if case .note(let text) = m.chat.last?.kind { XCTAssertEqual(text, "You took back a move.") } else { XCTFail() }
        m.newGame(mode: .versusModel, humanColor: .black, difficulty: .medium)
        XCTAssertEqual(m.chat.count, 1)
        XCTAssertEqual(m.mood, .neutral)
    }

    func testStatusSaysWhoseTurn() {
        let m = makeModel(QueuedTransport())
        XCTAssertEqual(m.statusText, "Your move")
        XCTAssertTrue(m.isHumansTurn)
    }
}

@MainActor
final class ThinkingSwitchTests: XCTestCase {
    func testSwitchingMidMoveRestartsAtTheNewPace() async {
        let t = QueuedTransport(["SAY: hmm\nMOVE: e5", "SAY: quick!\nMOVE: c5"], delay: 0.6)
        let settings = CoachSettings.inMemory(keys: ["api.anthropic.com": "sk-test-key"])
        settings.opponentThinking = .deep
        let m = GameModel(settings: settings, transport: t, analysisLimits: AnalysisLimits(maxDepth: 2, budgetSeconds: 0.1))
        m.minimumThinkTime = 0
        m.newGame(mode: .versusModel, humanColor: .white, difficulty: .medium)
        XCTAssertTrue(m.perform(Move(from: Square("e2")!, to: Square("e4")!, promotion: nil)))
        let deadline = Date().addingTimeInterval(5)
        while t.count < 1 && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(m.isThinking)
        XCTAssertTrue(t.bodies[0].contains("plenty of time"))
        XCTAssertTrue(t.bodies[0].contains(#""effort":"high""#))
        m.setOpponentThinking(.fast)
        let end = Date().addingTimeInterval(8)
        while m.game.history.count < 2 && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(t.count, 2)
        XCTAssertTrue(t.bodies[1].contains("blitz"))
        XCTAssertTrue(t.bodies[1].contains(#""effort":"low""#))
        XCTAssertTrue(t.bodies[1].contains("Thinking set to Fast"))
        XCTAssertEqual(m.game.history.last?.san, "c5", "the first, slower reply is dropped")
        XCTAssertEqual(settings.opponentThinking, .fast)
    }
}
