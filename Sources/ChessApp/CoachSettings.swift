import Foundation
import Observation
import Security
import ChessCoach

// MARK: - Key storage

/// Where API keys live. The key is looked up by the host of the model's base URL.
/// Keys are never logged and never written anywhere except the store.
protocol KeyStore: Sendable {
    func key(for host: String) -> String?
    /// A nil or empty key removes the entry.
    func setKey(_ key: String?, for host: String)
}

/// The macOS Keychain: a generic password with service `local.chess.app` and the host as account.
struct KeychainKeyStore: KeyStore {
    static let service = "local.chess.app"

    init() {}

    private func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: host]
    }

    func key(for host: String) -> String? {
        guard !host.isEmpty else { return nil }
        var q = query(host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setKey(_ key: String?, for host: String) {
        guard !host.isEmpty else { return }
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            SecItemDelete(query(host) as CFDictionary)
            return
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(host) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(host)
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// For tests and headless runs: nothing touches the Keychain.
final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]

    init(_ keys: [String: String] = [:]) { self.keys = keys }

    func key(for host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return keys[host]
    }

    func setKey(_ key: String?, for host: String) {
        lock.lock(); defer { lock.unlock() }
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        keys[host] = trimmed.isEmpty ? nil : trimmed
    }
}

/// Headless runs never reach the network.
struct NoNetworkTransport: LLMTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw LLMError.network("The network is switched off in this run.")
    }
}

extension ModelConfig {
    /// The account name under which this model's key is stored.
    var keyHost: String {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? ""
    }
}

// MARK: - Settings

/// The coach switches, the AI model and the chosen preset, persisted to an injectable `UserDefaults`.
@MainActor @Observable
final class CoachSettings {
    var coachEnabled: Bool { didSet { changed(oldCoach: oldValue) } }
    var evalBarEnabled: Bool { didSet { changed() } }
    var hintsEnabled: Bool { didSet { changed() } }
    var aiExplanations: Bool { didSet { changed() } }
    var modelConfig: ModelConfig { didSet { changed() } }
    var selectedPresetID: String { didSet { changed() } }
    /// Bumped whenever a key is saved so views re-evaluate `isModelUsable`.
    private(set) var keyRevision = 0

    @ObservationIgnored let keyStore: KeyStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var keyCache: [String: String?] = [:]
    /// Called after any setting changes; `coachToggled` is true when `coachEnabled` flipped.
    @ObservationIgnored var onChange: ((_ coachToggled: Bool) -> Void)?

    enum Key {
        static let coach = "coachEnabled"
        static let bar = "evalBarEnabled"
        static let hints = "hintsEnabled"
        static let ai = "aiExplanations"
        static let config = "modelConfig"
        static let preset = "selectedPresetID"
    }

    static var defaultPreset: ProviderPreset { ProviderPreset.all[0] }

    init(defaults: UserDefaults, keyStore: KeyStore) {
        self.defaults = defaults
        self.keyStore = keyStore
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        coachEnabled = bool(Key.coach, true)
        evalBarEnabled = bool(Key.bar, true)
        hintsEnabled = bool(Key.hints, true)
        aiExplanations = bool(Key.ai, false)
        if let data = defaults.data(forKey: Key.config),
           let config = try? JSONDecoder().decode(ModelConfig.self, from: data) {
            modelConfig = config
        } else {
            modelConfig = Self.defaultPreset.config
        }
        selectedPresetID = defaults.string(forKey: Key.preset) ?? Self.defaultPreset.id
    }

    /// Throwaway settings backed by a private suite and an in-memory key store (tests, headless runs).
    static func inMemory(coachEnabled: Bool = true, keys: [String: String] = [:]) -> CoachSettings {
        let suite = "local.chess.app.memory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults()
        defaults.removePersistentDomain(forName: suite)
        let s = CoachSettings(defaults: defaults, keyStore: InMemoryKeyStore(keys))
        s.coachEnabled = coachEnabled
        return s
    }

    /// The real app: standard defaults and the Keychain.
    static func production() -> CoachSettings {
        CoachSettings(defaults: .standard, keyStore: KeychainKeyStore())
    }

    private func changed(oldCoach: Bool? = nil) {
        defaults.set(coachEnabled, forKey: Key.coach)
        defaults.set(evalBarEnabled, forKey: Key.bar)
        defaults.set(hintsEnabled, forKey: Key.hints)
        defaults.set(aiExplanations, forKey: Key.ai)
        if let data = try? JSONEncoder().encode(modelConfig) { defaults.set(data, forKey: Key.config) }
        defaults.set(selectedPresetID, forKey: Key.preset)
        onChange?(oldCoach != nil && oldCoach != coachEnabled)
    }

    /// Choosing a preset fills the URL and model; they stay editable afterwards.
    func selectPreset(_ id: String) {
        guard let preset = ProviderPreset.all.first(where: { $0.id == id }) else { return }
        modelConfig = preset.config
        selectedPresetID = id
    }

    // MARK: Key and usability

    func currentKey() -> String? {
        let host = modelConfig.keyHost
        guard !host.isEmpty else { return nil }
        if let cached = keyCache[host] { return cached }
        let key = keyStore.key(for: host)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (key?.isEmpty ?? true) ? nil : key
        keyCache[host] = .some(value)
        return value
    }

    func storedKey(forHost host: String) -> String? {
        guard !host.isEmpty else { return nil }
        let key = keyStore.key(for: host)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }

    func saveKey(_ key: String?, forHost host: String) {
        guard !host.isEmpty else { return }
        keyStore.setKey(key, for: host)
        keyCache[host] = nil
        keyRevision += 1
        onChange?(false)
    }

    /// Base URL and model are set and, when the provider needs a key, one is stored.
    var isModelUsable: Bool {
        _ = keyRevision
        let url = modelConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelConfig.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !model.isEmpty else { return false }
        if modelConfig.requiresKey { return currentKey() != nil }
        return true
    }
}
