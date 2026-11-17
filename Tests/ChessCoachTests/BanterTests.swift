import XCTest
import ChessCore
import ChessCoach

final class BanterTests: XCTestCase {
    func testParsesSayAndMood() {
        let r = Banter.parse("I'll take the centre.\nSAY: \"Cute move. Watch this.\"\nMOOD: Confident\nMOVE: e5")
        XCTAssertEqual(r.say, "Cute move. Watch this.")
        XCTAssertEqual(r.mood, .confident)
    }

    func testMarkdownAndUnknownMood() {
        let r = Banter.parse("**SAY:** Not bad at all.\n**MOOD:** grumpy\nMOVE: Nf6")
        XCTAssertEqual(r.say, "Not bad at all.")
        XCTAssertNil(r.mood)
    }

    func testMoveOnlyReplyHasNoLine() {
        XCTAssertNil(Banter.parse("MOVE: e5").say)
        let long = String(repeating: "I considered many candidate moves here. ", count: 10)
        XCTAssertNil(Banter.parse(long + "\nMOVE: e5").say)
    }

    func testUntaggedShortLineBeforeTagsIsTheLine() {
        let r = Banter.parse("Not so sure about the Q move 🤪\nThink you've gotten yourself into trouble...\nMOOD: amused\nMOVE: Nc6")
        XCTAssertEqual(r.say, "Not so sure about the Q move 🤪 Think you've gotten yourself into trouble...")
        XCTAssertEqual(r.mood, .amused)
    }

    func testPlainShortChatReplyIsTheLine() {
        XCTAssertEqual(Banter.parse("Ha, we'll see about that!").say, "Ha, we'll see about that!")
    }

    func testOpponentPromptCarriesVerdictAndChat() {
        var game = Game()
        _ = game.play(Move(from: Square("f2")!, to: Square("f3")!, promotion: nil))
        let context = BanterContext(name: "qwen3:8b", lastHumanMove: "1. f3", verdict: .inaccuracy, betterSAN: "e4",
                                    chat: [ChatLine(speaker: .human, text: "go easy on me"),
                                           ChatLine(speaker: .opponent, text: "Never.")])
        let prompt = Banter.opponentTurn(game: game, context: context)
        XCTAssertTrue(prompt.contains("1. f3. Judged: inaccuracy. e4 was better"))
        XCTAssertTrue(prompt.contains("- Opponent: go easy on me"))
        XCTAssertTrue(prompt.contains("- You: Never."))
        XCTAssertTrue(prompt.contains("Legal moves:"))
        XCTAssertTrue(Banter.opponentSystem(name: "qwen3:8b").contains("MOOD:"))
    }
}
