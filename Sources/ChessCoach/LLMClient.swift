import Foundation

public enum ProviderKind: String, Codable, Sendable, CaseIterable { case anthropic, openAICompatible }

public struct ModelConfig: Codable, Equatable, Sendable {
    public var kind: ProviderKind
    public var baseURL: String                // no trailing slash
    public var model: String
    public var requiresKey: Bool

    public init(kind: ProviderKind, baseURL: String, model: String, requiresKey: Bool) {
        self.kind = kind; self.baseURL = baseURL; self.model = model; self.requiresKey = requiresKey
    }
}

public struct ProviderPreset: Identifiable, Sendable {
    public let id: String, name: String
    public let config: ModelConfig

    public init(id: String, name: String, config: ModelConfig) {
        self.id = id; self.name = name; self.config = config
    }

    public static let all: [ProviderPreset] = [
        ProviderPreset(id: "claude", name: "Claude", config: ModelConfig(kind: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-opus-5-5", requiresKey: true)),
        ProviderPreset(id: "openai", name: "OpenAI", config: ModelConfig(kind: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-5", requiresKey: true)),
        ProviderPreset(id: "gemini", name: "Gemini", config: ModelConfig(kind: .openAICompatible, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-2.5-flash", requiresKey: true)),
        ProviderPreset(id: "openrouter", name: "OpenRouter", config: ModelConfig(kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1", model: "anthropic/claude-opus-5-5", requiresKey: true)),
        ProviderPreset(id: "ollama", name: "Ollama on this Mac", config: ModelConfig(kind: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "llama3.2", requiresKey: false)),
        ProviderPreset(id: "custom", name: "Custom", config: ModelConfig(kind: .openAICompatible, baseURL: "", model: "", requiresKey: true)),
    ]
}

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) { self.role = role; self.content = content }
}

public enum LLMError: Error, Equatable, LocalizedError {
    case missingKey, badURL, unauthorized, rateLimited, refused, emptyReply
    case http(Int, String)                    // status, short message from the body
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "No API key is set."
        case .badURL: return "The base URL is not valid."
        case .unauthorized: return "The API key was rejected."
        case .rateLimited: return "Too many requests. Try again in a moment."
        case .refused: return "The model declined to answer."
        case .emptyReply: return "The model sent an empty reply."
        case .http(let status, let message):
            return message.isEmpty ? "The server returned an error (\(status))." : "The server returned an error (\(status)): \(message)"
        case .network(let message): return "Could not reach the server: \(message)"
        }
    }
}

public protocol LLMTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: LLMTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public struct LLMClient: Sendable {
    let config: ModelConfig
    let apiKey: String?
    let transport: LLMTransport

    public init(config: ModelConfig, apiKey: String?, transport: LLMTransport = URLSessionTransport()) {
        self.config = config
        self.apiKey = apiKey
        self.transport = transport
    }

    static let fallbackModels: Set<String> = ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    public func complete(system: String, messages: [ChatMessage], maxTokens: Int = 4000) async throws -> String {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKey = !(key ?? "").isEmpty
        if config.requiresKey && !hasKey { throw LLMError.missingKey }

        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let path = config.kind == .anthropic ? "/v1/messages" : "/chat/completions"
        guard let url = URL(string: base + path), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else {
            throw LLMError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = ["model": config.model, "max_tokens": maxTokens]
        switch config.kind {
        case .anthropic:
            if hasKey { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var msgs = messages
            while msgs.last?.role == .assistant { msgs.removeLast() }   // no prefill
            body["system"] = system
            body["messages"] = msgs.map { ["role": $0.role.rawValue, "content": $0.content] }
            body["output_config"] = ["effort": "low"]
            if host.lowercased() == "api.anthropic.com" && Self.fallbackModels.contains(config.model) {
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        case .openAICompatible:
            if hasKey, let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            var all: [[String: String]] = [["role": "system", "content": system]]
            all += messages.map { ["role": $0.role.rawValue, "content": $0.content] }
            body["messages"] = all
            // OpenAI's own current models reject `max_tokens`; other compatible servers still expect it.
            if host.lowercased() == "api.openai.com" {
                body["max_tokens"] = nil
                body["max_completion_tokens"] = maxTokens
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.network(redact((error as? URLError)?.localizedDescription ?? error.localizedDescription, key))
        }

        let status = response.statusCode
        switch status {
        case 200..<300: break
        case 401, 403: throw LLMError.unauthorized
        case 429: throw LLMError.rateLimited
        default: throw LLMError.http(status, redact(Self.errorMessage(from: data), key))
        }

        let text: String
        switch config.kind {
        case .anthropic:
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw LLMError.http(status, "The reply was not understood.")
            }
            if (json["stop_reason"] as? String) == "refusal" { throw LLMError.refused }
            let blocks = json["content"] as? [[String: Any]] ?? []
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        case .openAICompatible:
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw LLMError.http(status, "The reply was not understood.")
            }
            let choices = json["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any]
            text = message?["content"] as? String ?? ""
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw LLMError.emptyReply }
        return text
    }

    /// The model ids the server offers, sorted. Anthropic: `GET {baseURL}/v1/models`;
    /// OpenAI-compatible (OpenAI, Gemini, OpenRouter, Ollama…): `GET {baseURL}/models`.
    public func listModels() async throws -> [String] {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKey = !(key ?? "").isEmpty
        if config.requiresKey && !hasKey { throw LLMError.missingKey }

        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let path = config.kind == .anthropic ? "/v1/models?limit=1000" : "/models"
        guard let url = URL(string: base + path), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else {
            throw LLMError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        switch config.kind {
        case .anthropic:
            if hasKey { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAICompatible:
            if hasKey, let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }

        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.network(redact((error as? URLError)?.localizedDescription ?? error.localizedDescription, key))
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw LLMError.unauthorized
        case 429: throw LLMError.rateLimited
        default: throw LLMError.http(response.statusCode, redact(Self.errorMessage(from: data), key))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LLMError.http(response.statusCode, "The reply was not understood.")
        }
        // Both formats put the list in `data`; Gemini's OpenAI endpoint prefixes ids with "models/".
        let entries = json["data"] as? [[String: Any]] ?? []
        let ids = entries.compactMap { $0["id"] as? String }.map { id -> String in
            id.hasPrefix("models/") ? String(id.dropFirst("models/".count)) : id
        }
        return Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func redact(_ text: String, _ key: String?) -> String {
        guard let key, !key.isEmpty else { return text }
        return text.replacingOccurrences(of: key, with: "…")
    }

    private static func errorMessage(from data: Data) -> String {
        var message = ""
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let m = error["message"] as? String {
                message = m
            } else if let m = json["error"] as? String {
                message = m
            } else if let m = json["message"] as? String {
                message = m
            }
        }
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.count > 200 ? String(message.prefix(200)) : message
    }
}
