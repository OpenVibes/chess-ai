import XCTest
@testable import ChessCoach

final class ThinkingTests: XCTestCase {
    let msgs = [ChatMessage(role: .user, content: "hi")]
    let okAnthropic = #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#
    let okOpenAI = #"{"choices":[{"message":{"content":"ok"}}]}"#

    private func send(_ baseURL: String, kind: ProviderKind = .openAICompatible, _ level: ThinkingLevel?) async throws -> (URLRequest, [String: Any]) {
        let t = StubTransport(json: kind == .anthropic ? okAnthropic : okOpenAI)
        let config = ModelConfig(kind: kind, baseURL: baseURL, model: "m", requiresKey: false)
        _ = try await LLMClient(config: config, apiKey: "k", transport: t).complete(system: "s", messages: msgs, maxTokens: 50, thinking: level)
        let r = t.requests[0]
        return (r, try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any])
    }

    func testAnthropicEffortFollowsLevel() async throws {
        for (level, effort) in [(ThinkingLevel.fast, "low"), (.normal, "medium"), (.deep, "high")] {
            let (r, b) = try await send("https://api.anthropic.com", kind: .anthropic, level)
            XCTAssertEqual((b["output_config"] as? [String: String])?["effort"], effort)
            XCTAssertEqual(r.timeoutInterval, level.timeout)
        }
        let (r, b) = try await send("https://api.anthropic.com", kind: .anthropic, nil)
        XCTAssertEqual((b["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(r.timeoutInterval, 60)
    }

    func testOpenAIGeminiAndOpenRouter() async throws {
        let openai = try await send("https://api.openai.com/v1", .deep).1
        XCTAssertEqual(openai["reasoning_effort"] as? String, "high")
        let gemini = try await send("https://generativelanguage.googleapis.com/v1beta/openai", .fast).1
        XCTAssertEqual(gemini["reasoning_effort"] as? String, "low")
        let router = try await send("https://openrouter.ai/api/v1", .normal).1
        XCTAssertEqual((router["reasoning"] as? [String: String])?["effort"], "medium")
        XCTAssertNil(router["reasoning_effort"])
    }

    func testOllamaOnlyFastSwitchesThinkingOff() async throws {
        let fast = try await send("http://localhost:11434/v1", .fast).1
        let normal = try await send("http://localhost:11434/v1", .normal).1
        let deep = try await send("http://localhost:11434/v1", .deep).1
        XCTAssertEqual(fast["reasoning_effort"] as? String, "none")
        XCTAssertNil(normal["reasoning_effort"])
        XCTAssertNil(deep["reasoning_effort"])
    }

    func testUnknownServersAndNoLevelGetNoReasoningField() async throws {
        let proxy = try await send("https://my-proxy.example/v1", .deep).1
        let plain = try await send("https://api.openai.com/v1", nil).1
        XCTAssertNil(proxy["reasoning_effort"])
        XCTAssertNil(plain["reasoning_effort"])
    }

    func testPromptNotesDiffer() {
        XCTAssertTrue(ThinkingLevel.fast.promptNote.contains("blitz"))
        XCTAssertTrue(ThinkingLevel.deep.promptNote.contains("plenty of time"))
        XCTAssertLessThan(ThinkingLevel.fast.maxTokens, ThinkingLevel.deep.maxTokens)
    }
}
