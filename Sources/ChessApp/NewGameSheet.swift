import SwiftUI
import ChessCore
import ChessEngine
import ChessCoach

struct NewGameSheet: View {
    let model: GameModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    enum PlayAs: String, CaseIterable { case white = "White", black = "Black", random = "Random" }

    /// Models offered by the configured server, fetched when the sheet needs them.
    private enum ModelList: Equatable { case idle, loading, loaded([String]), failed(String) }

    @State private var mode: GameMode
    @State private var playAs: PlayAs
    @State private var difficulty: Difficulty
    @State private var models: ModelList = .idle

    init(model: GameModel, initialMode: GameMode? = nil) {
        self.model = model
        _mode = State(initialValue: initialMode ?? model.mode)
        _playAs = State(initialValue: model.humanColor == .white ? .white : .black)
        _difficulty = State(initialValue: model.difficulty)
    }

    private var settings: CoachSettings { model.coach.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New game").font(.headline)
            labeled("Mode") {
                Picker("Mode", selection: $mode) {
                    Text("Two players").tag(GameMode.twoPlayers)
                    Text("Versus computer").tag(GameMode.versusComputer)
                    Text("Versus AI model").tag(GameMode.versusModel)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if mode != .twoPlayers {
                labeled("Play as") {
                    Picker("Play as", selection: $playAs) {
                        ForEach(PlayAs.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            if mode == .versusComputer {
                labeled("Difficulty") {
                    Picker("Difficulty", selection: $difficulty) {
                        ForEach(Difficulty.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            if mode == .versusModel {
                opponentSection
            }

            Divider()
            coachSection

            HStack {
                Button("AI settings…") { openSettings() }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start game") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode == .versusModel && !settings.isModelUsable)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: listKey) { await loadModels() }
    }

    // MARK: Sections

    @ViewBuilder
    private var opponentSection: some View {
        @Bindable var settings = settings
        labeled("Provider") {
            Picker("Provider", selection: Binding(
                get: { settings.selectedPresetID },
                set: { settings.selectPreset($0) }
            )) {
                ForEach(ProviderPreset.all) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        labeled("Model") {
            HStack(spacing: 8) {
                TextField("Model", text: $settings.modelConfig.model)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                modelMenu
            }
            modelListStatus
        }
        if !settings.isModelUsable {
            HStack(spacing: 8) {
                Text(settings.modelConfig.baseURL.isEmpty || settings.modelConfig.model.isEmpty
                     ? "Set a base URL and model in Settings to play against a model."
                     : "Add an API key in Settings to play against a model.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Open Settings") { openSettings() }
            }
        }
    }

    @ViewBuilder
    private var modelMenu: some View {
        @Bindable var settings = settings
        Menu {
            switch models {
            case .loaded(let ids) where !ids.isEmpty:
                ForEach(ids, id: \.self) { id in
                    Button {
                        settings.modelConfig.model = id
                    } label: {
                        if id == settings.modelConfig.model { Label(id, systemImage: "checkmark") } else { Text(id) }
                    }
                }
            case .loading:
                Text("Loading models…")
            default:
                Text("No models listed")
            }
            Divider()
            Button("Refresh list") { Task { await loadModels() } }
        } label: {
            Text("Choose")
        }
        .menuStyle(.button)
        .fixedSize()
    }

    @ViewBuilder
    private var modelListStatus: some View {
        switch models {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Asking the server for its models…")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        case .loaded(let ids):
            if ids.isEmpty {
                note("The server listed no models. Type the model name.")
            } else if !ids.contains(settings.modelConfig.model) {
                note("\(ids.count) models available. \"\(settings.modelConfig.model)\" is not one of them.")
            } else {
                note("\(ids.count) models available on this server.")
            }
        case .failed(let message):
            note("Could not list models: \(message)")
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var coachSection: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 8) {
            Text("Coach")
            Toggle("Review my moves", isOn: $settings.coachEnabled)
            Toggle("Explain my mistakes with AI", isOn: $settings.aiExplanations)
                .disabled(!settings.isModelUsable)
            if settings.isModelUsable {
                note("Explanations use \(settings.modelConfig.model) via \(providerName).")
            } else {
                note("Add a model in AI settings to turn on explanations.")
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: Helpers

    private var providerName: String {
        ProviderPreset.all.first { $0.id == settings.selectedPresetID }?.name ?? "your provider"
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Changes whenever the list has to be fetched again.
    private var listKey: String {
        guard mode == .versusModel else { return "off" }
        let c = settings.modelConfig
        return "\(c.kind.rawValue)|\(c.baseURL)|\(settings.keyRevision)"
    }

    private func loadModels() async {
        guard mode == .versusModel else { models = .idle; return }
        let config = settings.modelConfig
        let needsKey = config.requiresKey && settings.currentKey() == nil
        if config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty || needsKey {
            models = .idle
            return
        }
        models = .loading
        let client = LLMClient(config: config, apiKey: settings.currentKey(), transport: model.coach.transport)
        do {
            let ids = try await client.listModels()
            guard !Task.isCancelled else { return }
            models = .loaded(ids)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            models = .failed(error.localizedDescription)
        }
    }

    private func start() {
        let color: PieceColor
        switch playAs {
        case .white: color = .white
        case .black: color = .black
        case .random: color = Bool.random() ? .white : .black
        }
        model.newGame(mode: mode, humanColor: color, difficulty: difficulty)
        dismiss()
    }
}
