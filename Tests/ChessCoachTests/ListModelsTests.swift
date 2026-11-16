import XCTest
@testable import ChessCoach

final class ListModelsTests: XCTestCase {
    func testOpenAICompatibleListsAndSorts() async throws {
        let cfg = ModelConfig(kind: .openAICompatible, baseURL: "http://localhost:11434/v1/", model: "", requiresKey: false)
        let t = StubTransport(json: #"{"object":"list","data":[{"id":"qwen3:8b"},{"id":"llama3.1:8b"},{"id":"qwen2.5:7b"},{"id":"qwen3:8b"}]}"#)
        let ids = try await LLMClient(config: cfg, apiKey: nil, transport: t).listModels()
        XCTAssertEqual(ids, ["llama3.1:8b", "qwen2.5:7b", "qwen3:8b"])
        let r = t.requests[0]
        XCTAssertEqual(r.url?.absoluteString, "http://localhost:11434/v1/models")
        XCTAssertEqual(r.httpMethod, "GET")
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
    }

    func testAnthropicUsesV1ModelsAndHeaders() async throws {
        let cfg = ModelConfig(kind: .anthropic, baseURL: "https://api.anthropic.com", model: "", requiresKey: true)
        let t = StubTransport(json: #"{"data":[{"id":"claude-opus-5-5","type":"model"},{"id":"claude-haiku-5-5","type":"model"}],"has_more":false}"#)
        let ids = try await LLMClient(config: cfg, apiKey: "sk-x", transport: t).listModels()
        XCTAssertEqual(ids, ["claude-haiku-5-5", "claude-opus-5-5"])
        let r = t.requests[0]
        XCTAssertEqual(r.url?.absoluteString, "https://api.anthropic.com/v1/models?limit=1000")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "sk-x")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testGeminiPrefixStrippedAndBearerSent() async throws {
        let cfg = ModelConfig(kind: .openAICompatible, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", model: "", requiresKey: true)
        let t = StubTransport(json: #"{"data":[{"id":"models/gemini-2.5-flash"}]}"#)
        let ids = try await LLMClient(config: cfg, apiKey: "g-key", transport: t).listModels()
        XCTAssertEqual(ids, ["gemini-2.5-flash"])
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer g-key")
    }

    func testErrors() async {
        let cfg = ModelConfig(kind: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "", requiresKey: true)
        do { _ = try await LLMClient(config: cfg, apiKey: nil, transport: StubTransport()).listModels(); XCTFail() }
        catch { XCTAssertEqual(error as? LLMError, .missingKey) }
        do { _ = try await LLMClient(config: cfg, apiKey: "k", transport: StubTransport(status: 401)).listModels(); XCTFail() }
        catch { XCTAssertEqual(error as? LLMError, .unauthorized) }
    }
}
