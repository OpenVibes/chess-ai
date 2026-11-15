import XCTest
@testable import ChessCoach

final class StubTransport: LLMTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    let status: Int
    let body: Data
    let error: Error?
    init(status: Int = 200, json: String = "{}", error: Error? = nil) {
        self.status = status; self.body = Data(json.utf8); self.error = error
    }
    private func record(_ r: URLRequest) { lock.lock(); _requests.append(r); lock.unlock() }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        if let error { throw error }
        let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, r)
    }
}

final class LLMClientTests: XCTestCase {
    let claude = ModelConfig(kind: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-opus-5-5", requiresKey: true)
    let openai = ModelConfig(kind: .openAICompatible, baseURL: "https://api.openai.com/v1/", model: "gpt-5", requiresKey: true)
    let msgs = [ChatMessage(role: .user, content: "hi")]
    let okAnthropic = #"{"content":[{"type":"thinking","thinking":"hmm","text":"NO"},{"type":"text","text":"Hello "},{"type":"text","text":"there"}],"stop_reason":"end_turn"}"#
    let okOpenAI = #"{"choices":[{"message":{"content":"Hi!"}}]}"#

    func body(_ t: StubTransport) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: t.requests[0].httpBody!) as! [String: Any]
    }

    func testAnthropicRequestAndReply() async throws {
        let t = StubTransport(json: okAnthropic)
        let reply = try await LLMClient(config: claude, apiKey: "sk-secret", transport: t).complete(system: "sys", messages: msgs, maxTokens: 123)
        XCTAssertEqual(reply, "Hello there")
        let r = t.requests[0]
        XCTAssertEqual(r.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "sk-secret")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(r.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(r.timeoutInterval, 60)
        let b = try body(t)
        XCTAssertEqual(b["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(b["max_tokens"] as? Int, 123)
        XCTAssertEqual(b["system"] as? String, "sys")
        XCTAssertEqual(b["fallbacks"] as? String, "default")
        XCTAssertEqual((b["output_config"] as? [String: String]), ["effort": "low"])
        XCTAssertEqual((b["messages"] as? [[String: String]]), [["role": "user", "content": "hi"]])
        for k in ["temperature", "top_p", "top_k", "thinking"] { XCTAssertNil(b[k]) }
    }

    func testNoFallbackForOtherHostOrModel() async throws {
        var proxy = claude; proxy.baseURL = "https://gateway.example.com"
        var other = claude; other.model = "claude-haiku-4"
        for cfg in [proxy, other] {
            let t = StubTransport(json: okAnthropic)
            _ = try await LLMClient(config: cfg, apiKey: "k", transport: t).complete(system: "s", messages: msgs)
            XCTAssertNil(t.requests[0].value(forHTTPHeaderField: "anthropic-beta"))
            XCTAssertNil(try body(t)["fallbacks"])
        }
        for m in ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5", "claude-sonnet-5-5"] {
            var c = claude; c.model = m
            let t = StubTransport(json: okAnthropic)
            _ = try await LLMClient(config: c, apiKey: "k", transport: t).complete(system: "s", messages: msgs)
            XCTAssertNotNil(t.requests[0].value(forHTTPHeaderField: "anthropic-beta"), m)
        }
    }

    func testAnthropicDropsTrailingAssistantPrefill() async throws {
        let t = StubTransport(json: okAnthropic)
        _ = try await LLMClient(config: claude, apiKey: "k", transport: t)
            .complete(system: "s", messages: msgs + [ChatMessage(role: .assistant, content: "MOVE:")])
        XCTAssertEqual((try body(t)["messages"] as? [[String: String]])?.count, 1)
    }

    func testRefusal() async {
        let t = StubTransport(json: #"{"content":[],"stop_reason":"refusal"}"#)
        await assertThrows(.refused, config: claude, transport: t)
    }

    func testOpenAIRequestAndReply() async throws {
        let t = StubTransport(json: okOpenAI)
        let reply = try await LLMClient(config: openai, apiKey: "sk-x", transport: t).complete(system: "sys", messages: msgs, maxTokens: 50)
        XCTAssertEqual(reply, "Hi!")
        let r = t.requests[0]
        XCTAssertEqual(r.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer sk-x")
        XCTAssertNil(r.value(forHTTPHeaderField: "x-api-key"))
        let b = try body(t)
        XCTAssertEqual(b["model"] as? String, "gpt-5")
        XCTAssertEqual(b["max_completion_tokens"] as? Int, 50)
        XCTAssertNil(b["max_tokens"])
        XCTAssertEqual((b["messages"] as? [[String: String]]), [["role": "system", "content": "sys"], ["role": "user", "content": "hi"]])
        XCTAssertNil(b["temperature"])
    }

    func testOpenAINoKeyOmitsAuthorization() async throws {
        let t = StubTransport(json: okOpenAI)
        let ollama = ProviderPreset.all.first { $0.id == "ollama" }!.config
        _ = try await LLMClient(config: ollama, apiKey: nil, transport: t).complete(system: "s", messages: msgs)
        XCTAssertNil(t.requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(t.requests[0].url?.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testMissingKeyBeforeRequest() async {
        for key in [nil, "", "  "] as [String?] {
            let t = StubTransport(json: okOpenAI)
            do {
                _ = try await LLMClient(config: openai, apiKey: key, transport: t).complete(system: "s", messages: msgs)
                XCTFail()
            } catch { XCTAssertEqual(error as? LLMError, .missingKey) }
            XCTAssertTrue(t.requests.isEmpty)
        }
    }

    func testStatusMapping() async {
        await assertThrows(.unauthorized, config: openai, transport: StubTransport(status: 401))
        await assertThrows(.unauthorized, config: openai, transport: StubTransport(status: 403))
        await assertThrows(.rateLimited, config: openai, transport: StubTransport(status: 429))
        await assertThrows(.http(500, "boom"), config: openai, transport: StubTransport(status: 500, json: #"{"error":{"message":"boom"}}"#))
        await assertThrows(.http(400, ""), config: claude, transport: StubTransport(status: 400, json: "not json"))
        let long = String(repeating: "x", count: 500)
        do {
            _ = try await LLMClient(config: openai, apiKey: "k", transport: StubTransport(status: 400, json: #"{"error":{"message":"\#(long)"}}"#)).complete(system: "s", messages: msgs)
            XCTFail()
        } catch {
            guard case .http(400, let m) = error as? LLMError else { return XCTFail() }
            XCTAssertEqual(m.count, 200)
        }
    }

    func testEmptyReplies() async {
        await assertThrows(.emptyReply, config: openai, transport: StubTransport(json: #"{"choices":[{"message":{"content":"  \n"}}]}"#))
        await assertThrows(.emptyReply, config: openai, transport: StubTransport(json: #"{"choices":[]}"#))
        await assertThrows(.emptyReply, config: claude, transport: StubTransport(json: #"{"content":[{"type":"thinking","thinking":"x"}]}"#))
    }

    func testNetworkAndBadURL() async {
        let t = StubTransport(error: URLError(.notConnectedToInternet))
        do {
            _ = try await LLMClient(config: openai, apiKey: "k", transport: t).complete(system: "s", messages: msgs)
            XCTFail()
        } catch {
            guard case .network(let m) = error as? LLMError else { return XCTFail() }
            XCTAssertEqual(m, URLError(.notConnectedToInternet).localizedDescription)
        }
        var bad = openai; bad.baseURL = ""
        await assertThrows(.badURL, config: bad, transport: StubTransport())
        bad.baseURL = "not a url"
        await assertThrows(.badURL, config: bad, transport: StubTransport())
    }

    func testKeyNeverInErrorText() async {
        let key = "sk-super-secret"
        let t = StubTransport(status: 500, json: #"{"error":{"message":"bad key sk-super-secret"}}"#)
        do {
            _ = try await LLMClient(config: openai, apiKey: key, transport: t).complete(system: "s", messages: msgs)
            XCTFail()
        } catch {
            XCTAssertFalse((error as? LLMError)?.errorDescription?.contains(key) ?? true)
        }
    }

    func testErrorDescriptions() {
        XCTAssertEqual(LLMError.unauthorized.errorDescription, "The API key was rejected.")
        XCTAssertEqual(LLMError.missingKey.errorDescription, "No API key is set.")
        XCTAssertEqual(LLMError.rateLimited.errorDescription, "Too many requests. Try again in a moment.")
        XCTAssertEqual(LLMError.refused.errorDescription, "The model declined to answer.")
        XCTAssertEqual(LLMError.emptyReply.errorDescription, "The model sent an empty reply.")
        XCTAssertEqual(LLMError.network("offline").errorDescription, "Could not reach the server: offline")
    }

    func testPresets() {
        XCTAssertEqual(ProviderPreset.all.map(\.name), ["Claude", "OpenAI", "Gemini", "OpenRouter", "Ollama on this Mac", "Custom"])
        XCTAssertEqual(ProviderPreset.all[0].config.kind, .anthropic)
        XCTAssertFalse(ProviderPreset.all[4].config.requiresKey)
        XCTAssertEqual(ProviderPreset.all[5].config.baseURL, "")
    }

    private func assertThrows(_ expected: LLMError, config: ModelConfig, transport: StubTransport, line: UInt = #line) async {
        do {
            _ = try await LLMClient(config: config, apiKey: "k", transport: transport).complete(system: "s", messages: msgs)
            XCTFail("expected \(expected)", line: line)
        } catch { XCTAssertEqual(error as? LLMError, expected, line: line) }
    }
}
