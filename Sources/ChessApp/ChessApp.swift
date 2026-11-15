import SwiftUI
import AppKit
import ChessCore
import ChessEngine
import ChessCoach

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct ChessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = GameModel.fromEnvironment()

    var body: some Scene {
        Window("Chess", id: "main") {
            MainView(model: model)
                .frame(minWidth: 760, minHeight: 540)
                .onAppear { SnapshotHook.runIfRequested(model: model) }
        }
        .defaultSize(width: 920, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New game") { model.showingNewGame = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
            }
            CommandGroup(replacing: .textEditing) {
                Button("Flip board") { model.flipBoard() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("Game") {
                Button("Hint") { model.requestHint() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(!model.canHint)
            }
        }
        Settings {
            SettingsView(settings: model.coach.settings, transport: model.coach.transport)
        }
    }
}

struct MainView: View {
    @Bindable var model: GameModel

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                let side = max(100, min(geo.size.width, geo.size.height) - 40)
                let showBar = model.coach.showEvalBar
                // The bar takes 10 pt plus an 8 pt gap out of the board, so both stay centred together.
                let boardSide = showBar ? side - 18 : side
                HStack(spacing: 8) {
                    if showBar { EvalBar(model: model, height: boardSide) }
                    ZStack {
                        BoardView(model: model, side: boardSide)
                        if model.showGameOverCard {
                            GameOverCard(model: model)
                        }
                    }
                    .frame(width: boardSide, height: boardSide)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            Divider()
            SidebarView(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showingNewGame) {
            NewGameSheet(model: model)
        }
    }
}

// MARK: - Snapshot support

extension GameModel {
    /// Builds the launch model, applying the optional CHESS_* variables used for headless layout checks.
    static func fromEnvironment() -> GameModel {
        let env = ProcessInfo.processInfo.environment
        var position = Position.start
        if let fen = env["CHESS_FEN"], let p = Position(fen: fen) { position = p }
        let headless = !(env["CHESS_SNAPSHOT"] ?? "").isEmpty
        let anySnapshot = headless || !(env["CHESS_SETTINGS_SNAPSHOT"] ?? "").isEmpty
            || !(env["CHESS_NEWGAME_SNAPSHOT"] ?? "").isEmpty
        let versusModel = (env["CHESS_VS"] ?? "").lowercased() == "model"
        // Snapshot runs use in-memory settings and keys and have no network; the real app uses UserDefaults and the Keychain.
        // CHESS_VS=model gets a fake key so the model counts as usable (CHESS_NOKEY=1 leaves it out); it never leaves the process.
        let fakeKeys = (versusModel && env["CHESS_NOKEY"] != "1") ? ["api.anthropic.com": "sk-headless-fake"] : [:]
        let model = anySnapshot
            ? GameModel(position: position, settings: .inMemory(keys: fakeKeys), transport: NoNetworkTransport())
            : GameModel(position: position, settings: .production())
        let demo = env["CHESS_COACH_DEMO"] == "1"
        model.computerEnabled = !headless || env["CHESS_AUTOPLAY"] == "1"
        if versusModel {
            model.newGame(mode: .versusModel, humanColor: .white, difficulty: .medium, position: position)
        } else if let vs = env["CHESS_VS"], let d = Difficulty(rawValue: vs.lowercased()) {
            model.newGame(mode: .versusComputer, humanColor: .white, difficulty: d, position: position)
        }
        if anySnapshot { model.coach.beginReplay() }
        for uci in (env["CHESS_MOVES"] ?? "").split(separator: " ") {
            let u = Array(uci)
            guard u.count >= 4, let from = Square(String(u[0..<2])), let to = Square(String(u[2..<4])) else { continue }
            var promo: PieceKind?
            if u.count > 4 {
                switch u[4] {
                case "q": promo = .queen
                case "r": promo = .rook
                case "b": promo = .bishop
                case "n": promo = .knight
                default: break
                }
            }
            model.perform(Move(from: from, to: to, promotion: promo))
        }
        if anySnapshot { model.coach.endReplay(reviewLast: demo) }
        if env["CHESS_HINT"] == "1" { model.requestHint() }
        if let s = env["CHESS_SELECT"], let sq = Square(s) { model.selected = sq }
        if env["CHESS_FLIP"] == "1" { model.flipBoard() }
        return model
    }
}

@MainActor
enum SnapshotHook {
    static func runIfRequested(model: GameModel) {
        let env = ProcessInfo.processInfo.environment
        let dark = env["CHESS_DARK"] == "1"
        if let path = env["CHESS_SETTINGS_SNAPSHOT"], !path.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                let view = SettingsView(settings: model.coach.settings, transport: NoNetworkTransport())
                    .background(Color(nsColor: .windowBackgroundColor))
                await capture(view, width: 460, height: nil, dark: dark, path: path)
            }
            return
        }
        if let path = env["CHESS_NEWGAME_SNAPSHOT"], !path.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                let preset: GameMode? = (env["CHESS_VS"] ?? "").lowercased() == "model" ? .versusModel
                    : (Difficulty(rawValue: (env["CHESS_VS"] ?? "").lowercased()) != nil ? .versusComputer : nil)
                let view = NewGameSheet(model: model, initialMode: preset)
                    .background(Color(nsColor: .windowBackgroundColor))
                await capture(view, width: 400, height: nil, dark: dark, path: path)
            }
            return
        }
        guard let path = env["CHESS_SNAPSHOT"], !path.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if env["CHESS_AUTOPLAY"] == "1" {
                let deadline = Date().addingTimeInterval(10)
                while model.isThinking && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            if env["CHESS_COACH_DEMO"] == "1" || env["CHESS_HINT"] == "1" {
                await model.coach.waitUntilIdle(timeout: 15)
            }
            await capture(MainView(model: model), width: 920, height: 640, dark: dark, path: path)
        }
    }

    /// Renders a view offscreen and writes a 2x PNG, then exits. `height` nil means the view's natural height.
    private static func capture<V: View>(_ view: V, width: CGFloat, height: CGFloat?, dark: Bool, path: String) async {
        let host = NSHostingView(rootView: view.frame(width: width))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height ?? 600),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -3000, y: 0))
        win.orderFrontRegardless()
        host.frame = NSRect(x: 0, y: 0, width: width, height: height ?? 600)
        host.layoutSubtreeIfNeeded()
        var h = height ?? host.fittingSize.height
        if height == nil {
            h = max(h, 200)
            host.frame = NSRect(x: 0, y: 0, width: width, height: h)
            win.setContentSize(NSSize(width: width, height: h))
        } else if let height {
            host.rootView = view.frame(width: width, height: height)
        }
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 600_000_000)
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(h * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
        rep.size = NSSize(width: width, height: h)
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            exit(1)
        }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
