import SwiftUI
import ChessCoach

struct SettingsView: View {
    @Bindable var settings: CoachSettings
    let transport: LLMTransport

    private enum TestState: Equatable { case idle, running, connected, failed(String) }

    @State private var keyText = ""
    @State private var loadedHost = ""
    @State private var test: TestState = .idle
    @FocusState private var keyFocused: Bool

    var body: some View {
        Form {
            Section("Coach") {
                Toggle("Review my moves", isOn: $settings.coachEnabled)
                Toggle("Evaluation bar", isOn: $settings.evalBarEnabled)
                Toggle("Hints", isOn: $settings.hintsEnabled)
                Toggle("Explain with AI", isOn: $settings.aiExplanations)
                    .disabled(!settings.isModelUsable)
                if !settings.isModelUsable {
                    Text("Add a model below to turn this on.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Provider", selection: Binding(
                    get: { settings.selectedPresetID },
                    set: { settings.selectPreset($0) }
                )) {
                    ForEach(ProviderPreset.all) { Text($0.name).tag($0.id) }
                }
                TextField("Base URL", text: $settings.modelConfig.baseURL)
                TextField("Model", text: $settings.modelConfig.model)
                if settings.modelConfig.requiresKey {
                    SecureField("API key", text: $keyText, prompt: Text("Stored in your Keychain"))
                        .focused($keyFocused)
                        .onSubmit { commitKey() }
                }
                HStack(spacing: 10) {
                    Button("Test connection") { runTest() }
                        .disabled(test == .running)
                    switch test {
                    case .idle: EmptyView()
                    case .running: ProgressView().controlSize(.small)
                    case .connected:
                        Text("Connected.").foregroundStyle(.green)
                    case .failed(let message):
                        Text(message).foregroundStyle(.red).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            } header: {
                Text("AI model")
            } footer: {
                Text("Only the position and moves are sent to the model. Requests are billed to your own key.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { reloadKey() }
        .onDisappear { commitKey() }
        .onChange(of: keyFocused) { if !keyFocused { commitKey() } }
        .onChange(of: settings.modelConfig.keyHost) {
            commitKey()
            reloadKey()
        }
    }

    private func reloadKey() {
        loadedHost = settings.modelConfig.keyHost
        keyText = settings.storedKey(forHost: loadedHost) ?? ""
    }

    /// Writes the field to the key store when it differs from what is stored.
    private func commitKey() {
        guard !loadedHost.isEmpty else { return }
        let typed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed != (settings.storedKey(forHost: loadedHost) ?? "") {
            settings.saveKey(typed, forHost: loadedHost)
        }
    }

    private func runTest() {
        commitKey()
        test = .running
        let client = LLMClient(config: settings.modelConfig, apiKey: settings.currentKey(), transport: transport)
        Task { @MainActor in
            do {
                _ = try await client.complete(system: "You are a connection test. Answer in one word.",
                                              messages: [ChatMessage(role: .user, content: "Reply with the word OK.")],
                                              maxTokens: 1000)
                test = .connected
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }
}
