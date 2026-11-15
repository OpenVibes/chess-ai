import XCTest
import ChessCore
import ChessEngine
import ChessCoach
@testable import ChessApp

/// Counts requests and answers with a canned Anthropic-format reply, after an optional delay.
final class CountingTransport: LLMTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    let status: Int
    let text: String
    let delay: Double

    init(status: Int = 200, text: String = "The queen is left hanging.", delay: Double = 0) {
        self.status = status; self.text = text; self.delay = delay
    }

    private func bump() { lock.lock(); _count += 1; lock.unlock() }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        bump()
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        let body = #"{"content":[{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn"}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

@MainActor
final class CoachModelTests: XCTestCase {
    private let blunderLine = "e2e4 e7e5 d1h5 g7g6"   // ...g6 allows Qxe5+ winning the rook

    private func mv(_ s: String) -> Move {
        let u = Array(s)
        return Move(from: Square(String(u[0..<2]))!, to: Square(String(u[2..<4]))!, promotion: nil)
    }

    private func play(_ model: GameModel, _ moves: String) {
        for m in moves.split(separator: " ") { XCTAssertTrue(model.perform(mv(String(m))), "illegal \(m)") }
    }

    /// Black to move after 1.e4 e5 2.Qh5: ...g6 loses the h8 rook to Qxe5+. A single reviewed ply keeps the AI tests deterministic.
    private let afterQh5 = "rnbqkbnr/pppp1ppp/8/4p2Q/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 1 2"
    /// White has exactly one legal move (Kxg2), which the coach rates as best by rule.
    private let forcedMove = "k7/8/8/8/8/8/6q1/7K w - - 0 1"

    private func makeModel(ai: Bool = false, transport: LLMTransport = CountingTransport(),
                           keys: [String: String] = ["api.anthropic.com": "sk-test-key"],
                           fen: String? = nil) -> (GameModel, CoachSettings) {
        let settings = CoachSettings.inMemory(keys: keys)
        settings.aiExplanations = ai
        let model = GameModel(position: fen.flatMap { Position(fen: $0) } ?? .start, settings: settings, transport: transport,
                              analysisLimits: AnalysisLimits(maxDepth: 3, budgetSeconds: 0.25))
        return (model, settings)
    }

    private func wait(_ timeout: Double = 10, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    // MARK: Reviews

    func testBlunderIsReviewedAndMarked() async {
        let (model, _) = makeModel()
        play(model, blunderLine)
        await model.coach.waitUntilIdle()
        XCTAssertEqual(model.coach.reviews[3]?.quality, .blunder)
        XCTAssertEqual(model.coach.reviews[3]?.san, "g6")
        XCTAssertEqual(model.coach.moveMark(ply: 3), "??")
        XCTAssertEqual(model.coach.displayedPly, 3)
        XCTAssertNotNil(model.coach.currentAnalysis)
        XCTAssertNotNil(model.coach.evalScore)
        // Plies 0 to 2 are reviewed too (both sides are human in Two players).
        XCTAssertEqual(Set(model.coach.reviews.keys), [0, 1, 2, 3])
    }

    func testOnlyHumanMovesAreReviewedVersusComputer() async {
        let (model, _) = makeModel()
        model.computerEnabled = false
        model.newGame(mode: .versusComputer, humanColor: .white, difficulty: .easy)
        play(model, "e2e4 e7e5")   // white: human, black: the computer's side
        await model.coach.waitUntilIdle()
        XCTAssertNotNil(model.coach.reviews[0])
        XCTAssertNil(model.coach.reviews[1])
    }

    func testUndoDropsReviewsOfUndonePlies() async {
        let (model, _) = makeModel()
        play(model, blunderLine)
        await model.coach.waitUntilIdle()
        XCTAssertEqual(model.coach.reviews.count, 4)
        model.undo()
        XCTAssertEqual(Set(model.coach.reviews.keys), [0, 1, 2])
        model.undo()
        model.undo()
        XCTAssertEqual(Set(model.coach.reviews.keys), [0])
        model.undo()
        XCTAssertTrue(model.coach.reviews.isEmpty)
    }

    func testUndoBeforeReviewFinishesNeverStoresIt() async {
        let (model, _) = makeModel()
        play(model, "e2e4 e7e5")
        model.undo()
        model.undo()
        await model.coach.waitUntilIdle()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(model.coach.reviews.isEmpty)
    }

    func testNewGameClearsEverything() async {
        let (model, _) = makeModel()
        play(model, blunderLine)
        await model.coach.waitUntilIdle()
        model.newGame(mode: .twoPlayers, humanColor: .white, difficulty: .medium)
        XCTAssertTrue(model.coach.reviews.isEmpty)
        XCTAssertTrue(model.coach.explanations.isEmpty)
        XCTAssertNil(model.coach.hint)
        XCTAssertNil(model.coach.arrow)
    }

    func testClickingAMoveInspectsItsReviewAndNewMoveReturnsToLatest() async {
        let (model, _) = makeModel()
        play(model, blunderLine)
        await model.coach.waitUntilIdle()
        model.coach.inspect(ply: 0)
        XCTAssertEqual(model.coach.displayedPly, 0)
        model.undo()
        XCTAssertNil(model.coach.inspectedPly)
        XCTAssertEqual(model.coach.displayedPly, 2)
    }

    func testShowBetterMoveOnlyForLatestPly() async {
        let (model, _) = makeModel()
        play(model, blunderLine)
        await model.coach.waitUntilIdle()
        model.coach.showBetterMove(ply: 2)
        XCTAssertNil(model.coach.arrow)
        model.coach.showBetterMove(ply: 3)
        let best = model.coach.reviews[3]?.bestMove
        XCTAssertEqual(model.coach.arrow, best.map { BoardArrow(from: $0.from, to: $0.to) })
        XCTAssertNotNil(model.coach.arrow)
    }

    // MARK: Hint

    func testHintSetsArrowAndNextMoveClearsIt() async {
        let (model, _) = makeModel()
        play(model, "e2e4")
        model.requestHint()
        await model.coach.waitUntilIdle()
        let best = model.coach.currentAnalysis?.bestMove
        XCTAssertNotNil(best)
        XCTAssertEqual(model.coach.arrow, best.map { BoardArrow(from: $0.from, to: $0.to) })
        XCTAssertEqual(model.coach.hint?.move, best)
        XCTAssertFalse((model.coach.hint?.san ?? "").isEmpty)
        play(model, "e7e5")
        XCTAssertNil(model.coach.arrow)
        XCTAssertNil(model.coach.hint)
    }

    func testHintClearedByUndoAndNewGame() async {
        let (model, _) = makeModel()
        play(model, "e2e4")
        model.requestHint()
        await model.coach.waitUntilIdle()
        XCTAssertNotNil(model.coach.arrow)
        model.undo()
        XCTAssertNil(model.coach.arrow)
        model.requestHint()
        await model.coach.waitUntilIdle()
        XCTAssertNotNil(model.coach.arrow)
        model.newGame(mode: .twoPlayers, humanColor: .white, difficulty: .medium)
        XCTAssertNil(model.coach.arrow)
        XCTAssertNil(model.coach.hint)
    }

    func testNoHintWhenHintsOff() async {
        let (model, settings) = makeModel()
        settings.hintsEnabled = false
        XCTAssertFalse(model.canHint)
        model.requestHint()
        await model.coach.waitUntilIdle()
        XCTAssertNil(model.coach.hint)
    }

    // MARK: AI explanations

    func testAIExplanationGoesLoadingThenText() async {
        let transport = CountingTransport(text: "Your queen can be taken for free.", delay: 0.4)
        let (model, _) = makeModel(ai: true, transport: transport, fen: afterQh5)
        play(model, "g7g6")
        await wait { model.coach.reviews[0] != nil }
        XCTAssertEqual(model.coach.explanations[0], .loading)
        await wait { model.coach.explanations[0] != .loading }
        XCTAssertEqual(model.coach.explanations[0], .text("Your queen can be taken for free."))
        XCTAssertEqual(transport.count, 1)   // only the blunder is explained
    }

    func testAIFailureKeepsRuleBasedSummary() async {
        let transport = CountingTransport(status: 401)
        let (model, _) = makeModel(ai: true, transport: transport, fen: afterQh5)
        play(model, "g7g6")
        await wait { model.coach.reviews[0] != nil }
        await wait { model.coach.explanations[0] != .loading }
        XCTAssertEqual(model.coach.explanations[0], .failed(LLMError.unauthorized.localizedDescription))
        XCTAssertTrue(model.coach.reviews[0]?.summary.hasPrefix("Blunder.") ?? false)
    }

    func testStaleAIReplyIsDroppedAfterUndo() async {
        let transport = CountingTransport(delay: 0.4)
        let (model, _) = makeModel(ai: true, transport: transport, fen: afterQh5)
        play(model, "g7g6")
        await wait { model.coach.reviews[0] != nil }
        model.undo()
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(model.coach.explanations[0])
        XCTAssertNil(model.coach.reviews[0])
    }

    func testNothingRequestedWhenAIIsOff() async {
        let transport = CountingTransport()
        let (model, _) = makeModel(ai: false, transport: transport)
        play(model, blunderLine)
        model.requestHint()
        await model.coach.waitUntilIdle()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(transport.count, 0)
        XCTAssertTrue(model.coach.explanations.isEmpty)
        XCTAssertEqual(model.coach.hint?.ai, AIText.none)
    }

    func testNothingRequestedWhenModelNotUsable() async {
        let transport = CountingTransport()
        let (model, _) = makeModel(ai: true, transport: transport, keys: [:])   // no key stored
        play(model, blunderLine)
        await model.coach.waitUntilIdle()
        XCTAssertEqual(transport.count, 0)
    }

    func testGoodMovesAreNotExplained() async {
        let transport = CountingTransport()
        let (model, _) = makeModel(ai: true, transport: transport, fen: forcedMove)
        play(model, "h1g2")
        await model.coach.waitUntilIdle()
        XCTAssertEqual(model.coach.reviews[0]?.quality, .best)
        XCTAssertEqual(transport.count, 0)
    }

    func testHintGetsAIText() async {
        let transport = CountingTransport(text: "It develops a knight.")
        let (model, _) = makeModel(ai: true, transport: transport)
        model.requestHint()
        await model.coach.waitUntilIdle()
        await wait { model.coach.hint?.ai != .loading }
        XCTAssertEqual(model.coach.hint?.ai, .text("It develops a knight."))
    }

    // MARK: Coach off

    func testCoachOffDoesNothing() async {
        let (model, settings) = makeModel()
        settings.coachEnabled = false
        play(model, blunderLine)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(model.coach.reviews.isEmpty)
        XCTAssertNil(model.coach.currentAnalysis)
        XCTAssertNil(model.coach.moveMark(ply: 3))
        XCTAssertFalse(model.coach.showEvalBar)
    }

    func testEvalShareClampsAndFillsOnMate() async {
        let (model, _) = makeModel()
        await model.coach.waitUntilIdle()
        XCTAssertEqual(model.coach.whiteShare, 0.5, accuracy: 0.1)
        // Fool's mate: Black has mated, the bar is empty of white.
        play(model, "f2f3 e7e5 g2g4 d8h4")
        await model.coach.waitUntilIdle()
        XCTAssertEqual(model.coach.whiteShare, 0.0)
    }

    // MARK: Settings

    func testSettingsRoundTripThroughUserDefaults() {
        let suite = "local.chess.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = InMemoryKeyStore()

        let fresh = CoachSettings(defaults: defaults, keyStore: keys)
        XCTAssertTrue(fresh.coachEnabled)
        XCTAssertTrue(fresh.evalBarEnabled)
        XCTAssertTrue(fresh.hintsEnabled)
        XCTAssertFalse(fresh.aiExplanations)
        XCTAssertEqual(fresh.modelConfig, ProviderPreset.all[0].config)

        fresh.coachEnabled = false
        fresh.evalBarEnabled = false
        fresh.hintsEnabled = false
        fresh.aiExplanations = true
        fresh.selectPreset("openai")
        fresh.modelConfig.model = "gpt-custom"

        let again = CoachSettings(defaults: defaults, keyStore: keys)
        XCTAssertFalse(again.coachEnabled)
        XCTAssertFalse(again.evalBarEnabled)
        XCTAssertFalse(again.hintsEnabled)
        XCTAssertTrue(again.aiExplanations)
        XCTAssertEqual(again.selectedPresetID, "openai")
        XCTAssertEqual(again.modelConfig.model, "gpt-custom")
        XCTAssertEqual(again.modelConfig.baseURL, "https://api.openai.com/v1")
    }

    func testKeyNeverReachesUserDefaults() {
        let suite = "local.chess.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = InMemoryKeyStore()
        let settings = CoachSettings(defaults: defaults, keyStore: keys)
        settings.saveKey("sk-very-secret", forHost: "api.anthropic.com")
        settings.coachEnabled = false   // forces a write of everything
        XCTAssertEqual(keys.key(for: "api.anthropic.com"), "sk-very-secret")
        XCTAssertFalse("\(defaults.dictionaryRepresentation())".contains("sk-very-secret"))
    }

    func testUsableModelLogic() {
        let s = CoachSettings.inMemory()
        XCTAssertFalse(s.isModelUsable)               // Claude needs a key
        s.saveKey("sk-x", forHost: "api.anthropic.com")
        XCTAssertTrue(s.isModelUsable)
        s.modelConfig.model = "  "
        XCTAssertFalse(s.isModelUsable)               // model empty
        s.modelConfig.model = "claude-opus-5-5"
        s.modelConfig.baseURL = ""
        XCTAssertFalse(s.isModelUsable)               // URL empty
        s.selectPreset("ollama")
        XCTAssertTrue(s.isModelUsable)                // no key required
        s.selectPreset("custom")
        XCTAssertFalse(s.isModelUsable)               // empty URL and model
        s.modelConfig.baseURL = "https://gateway.example.com/v1"
        s.modelConfig.model = "m"
        XCTAssertFalse(s.isModelUsable)               // key required, none for that host
        s.saveKey("k", forHost: "gateway.example.com")
        XCTAssertTrue(s.isModelUsable)
        s.saveKey(nil, forHost: "gateway.example.com")
        XCTAssertFalse(s.isModelUsable)
    }

    func testInMemoryKeyStore() {
        let store = InMemoryKeyStore()
        XCTAssertNil(store.key(for: "h"))
        store.setKey(" abc \n", for: "h")
        XCTAssertEqual(store.key(for: "h"), "abc")
        store.setKey("", for: "h")
        XCTAssertNil(store.key(for: "h"))
    }
}
