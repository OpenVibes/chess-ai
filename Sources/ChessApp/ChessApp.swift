import SwiftUI
import AppKit
import ChessCore
import ChessEngine

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
        }
    }
}

struct MainView: View {
    @Bindable var model: GameModel

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                let side = max(100, min(geo.size.width, geo.size.height) - 40)
                ZStack {
                    BoardView(model: model, side: side)
                    if model.showGameOverCard {
                        GameOverCard(model: model)
                    }
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
        let model = GameModel(position: position)
        if let vs = env["CHESS_VS"], let d = Difficulty(rawValue: vs.lowercased()) {
            model.newGame(mode: .versusComputer, humanColor: .white, difficulty: d, position: position)
        }
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
        if let s = env["CHESS_SELECT"], let sq = Square(s) { model.selected = sq }
        if env["CHESS_FLIP"] == "1" { model.flipBoard() }
        return model
    }
}

@MainActor
enum SnapshotHook {
    static func runIfRequested(model: GameModel) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CHESS_SNAPSHOT"], !path.isEmpty else { return }
        let dark = env["CHESS_DARK"] == "1"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            let host = NSHostingView(rootView: MainView(model: model).frame(width: 920, height: 640))
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            win.contentView = host
            win.setFrameOrigin(NSPoint(x: -3000, y: 0))
            win.orderFrontRegardless()
            host.frame = NSRect(x: 0, y: 0, width: 920, height: 640)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 600_000_000)
            host.layoutSubtreeIfNeeded()
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1840, pixelsHigh: 1280,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
            rep.size = NSSize(width: 920, height: 640)
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
}
