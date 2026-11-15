import SwiftUI
import Observation
import ChessCore
import ChessEngine
import ChessCoach

enum GameMode: Equatable { case twoPlayers, versusComputer }

/// A piece on the board with a stable identity, so SwiftUI can animate it between squares.
struct PieceItem: Identifiable, Equatable {
    let id: Int
    var piece: Piece
    var square: Square
}

struct PendingPromotion: Equatable {
    let from: Square
    let to: Square
}

extension PieceKind {
    /// Material value in pawns (king excluded).
    var value: Int {
        switch self {
        case .pawn: return 1
        case .knight, .bishop: return 3
        case .rook: return 5
        case .queen: return 9
        case .king: return 0
        }
    }
}

/// Thread-safe cancellation flag read by the engine's `shouldStop` closure.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

@MainActor @Observable
final class GameModel {
    private(set) var game: Game
    var mode: GameMode = .twoPlayers
    var humanColor: PieceColor = .white
    var difficulty: Difficulty = .medium
    var selected: Square?
    var whiteAtBottom = true
    var pendingPromotion: PendingPromotion?
    var isThinking = false
    var gameOverDismissed = false
    var showingNewGame = false
    /// False in headless snapshot runs so the computer does not move on its own.
    var computerEnabled = true
    /// Minimum time before the computer's move is applied.
    var minimumThinkTime: Double = 0.4

    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var searchFlag: CancelFlag?

    /// Pieces with stable ids; one snapshot per position so undo restores identities.
    private var pieceStack: [[PieceItem]]
    private var nextID = 0

    var pieces: [PieceItem] { pieceStack[pieceStack.count - 1] }

    /// The coach: background analysis, reviews, hints (see `CoachModel.swift`).
    let coach: CoachModel

    /// `settings` defaults to throwaway in-memory settings with the coach off, so a bare `GameModel()` never
    /// touches UserDefaults, the Keychain or the network. The app passes real ones (`fromEnvironment`).
    init(position: Position = .start, settings: CoachSettings? = nil, transport: LLMTransport? = nil,
         analysisLimits: AnalysisLimits = AnalysisLimits()) {
        game = Game(position: position)
        pieceStack = []
        coach = CoachModel(settings: settings ?? CoachSettings.inMemory(coachEnabled: false),
                           transport: transport ?? URLSessionTransport(), limits: analysisLimits)
        pieceStack = [makeItems(for: position)]
        coach.host = self
        coach.positionChanged()
    }

    private func makeItems(for position: Position) -> [PieceItem] {
        var items: [PieceItem] = []
        for i in 0..<64 {
            let sq = Square(file: i & 7, rank: i >> 3)
            if let p = position[sq] {
                items.append(PieceItem(id: nextID, piece: p, square: sq))
                nextID += 1
            }
        }
        return items
    }

    // MARK: Derived state

    var sideToMove: PieceColor { game.position.sideToMove }
    var isGameOver: Bool { game.status != .ongoing }
    var showGameOverCard: Bool { isGameOver && !gameOverDismissed }

    var canInteract: Bool {
        if isGameOver || isThinking { return false }
        if mode == .versusComputer && sideToMove != humanColor { return false }
        return true
    }

    var legalTargets: Set<Square> {
        guard let selected else { return [] }
        return Set(game.position.legalMoves(from: selected).map(\.to))
    }

    func isCapture(to square: Square) -> Bool {
        guard let selected else { return false }
        if let p = game.position[square], p.color != game.position[selected]?.color { return true }
        if game.position[selected]?.kind == .pawn, game.position.enPassant == square { return true }
        return false
    }

    var kingInCheckSquare: Square? {
        guard game.position.isInCheck else { return nil }
        return game.position.kingSquare(of: sideToMove)
    }

    var canUndo: Bool { !game.history.isEmpty }

    /// The lightbulb and the Hint menu item: coach and hints on, and it is a human's turn.
    var canHint: Bool { coach.hintAvailable && canInteract }

    func requestHint() { coach.requestHint() }

    var bottomColor: PieceColor { whiteAtBottom ? .white : .black }
    var topColor: PieceColor { bottomColor.opposite }

    func playerName(_ color: PieceColor) -> String {
        switch mode {
        case .twoPlayers: return color == .white ? "White" : "Black"
        case .versusComputer:
            return color == humanColor ? "You" : "Computer · \(difficulty.rawValue.capitalized)"
        }
    }

    /// Material on the board for one colour, in pawns.
    func material(_ color: PieceColor) -> Int {
        pieces.reduce(0) { $0 + ($1.piece.color == color ? $1.piece.kind.value : 0) }
    }

    func lead(_ color: PieceColor) -> Int { material(color) - material(color.opposite) }

    /// Pieces this colour has captured, cheapest first.
    func capturedPieces(by color: PieceColor) -> [Piece] {
        game.captured(by: color).sorted { $0.kind.value < $1.kind.value }
    }

    var resultText: String? {
        switch game.status {
        case .ongoing: return nil
        case .checkmate(let winner): return "Checkmate. \(winner == .white ? "White" : "Black") wins"
        case .stalemate: return "Stalemate. Draw"
        case .drawRepetition: return "Draw by repetition"
        case .drawFiftyMove: return "Draw by fifty-move rule"
        case .drawInsufficientMaterial: return "Draw by insufficient material"
        }
    }

    var statusText: String {
        if let resultText { return resultText }
        if isThinking { return "Computer is thinking…" }
        if game.position.isInCheck { return "Check" }
        return sideToMove == .white ? "White to move" : "Black to move"
    }

    // MARK: Actions

    func tap(_ square: Square) {
        guard canInteract else { return }
        if selected != nil, legalTargets.contains(square) {
            tryMove(from: selected!, to: square)
            return
        }
        if let p = game.position[square], p.color == sideToMove {
            selected = (selected == square) ? nil : square
        } else {
            selected = nil
        }
    }

    /// Selects a piece of the side to move (used when a drag starts).
    func select(_ square: Square) {
        guard canInteract, let p = game.position[square], p.color == sideToMove else { return }
        selected = square
    }

    @discardableResult
    func tryMove(from: Square, to: Square) -> Bool {
        guard canInteract else { return false }
        let moves = game.position.legalMoves(from: from).filter { $0.to == to }
        guard let first = moves.first else { return false }
        if moves.count > 1 || first.promotion != nil {
            pendingPromotion = PendingPromotion(from: from, to: to)
            return true
        }
        return perform(first)
    }

    func choosePromotion(_ kind: PieceKind) {
        guard let pending = pendingPromotion else { return }
        pendingPromotion = nil
        _ = perform(Move(from: pending.from, to: pending.to, promotion: kind))
    }

    func cancelPromotion() {
        guard pendingPromotion != nil else { return }
        pendingPromotion = nil
    }

    func undo() {
        guard canUndo else { return }
        pendingPromotion = nil
        selected = nil
        repeat {
            guard game.undo() else { break }
            pieceStack.removeLast()
        } while mode == .versusComputer && sideToMove != humanColor && !game.history.isEmpty
        gameOverDismissed = false
        coach.didUndo()
        positionDidChange()
    }

    func flipBoard() { whiteAtBottom.toggle() }

    func newGame(mode: GameMode, humanColor: PieceColor, difficulty: Difficulty, position: Position = .start) {
        self.mode = mode
        self.humanColor = humanColor
        self.difficulty = difficulty
        game = Game(position: position)
        pieceStack = [makeItems(for: position)]
        selected = nil
        pendingPromotion = nil
        gameOverDismissed = false
        whiteAtBottom = (mode == .versusComputer) ? (humanColor == .white) : true
        coach.reset()
        positionDidChange()
    }

    /// Plays a move and keeps the identity-tracked piece list in step.
    @discardableResult
    func perform(_ move: Move) -> Bool {
        let before = game.position
        let byHuman = mode == .twoPlayers || before.sideToMove == humanColor
        guard game.play(move) else { return false }
        var items = pieces
        if let mover = items.firstIndex(where: { $0.square == move.from }) {
            let kind = before[move.from]?.kind
            var captureSquare = move.to
            if kind == .pawn, move.from.file != move.to.file, before[move.to] == nil {
                captureSquare = Square(file: move.to.file, rank: move.from.rank)
            }
            let moverID = items[mover].id
            items.removeAll { $0.square == captureSquare && $0.id != moverID }
            let m = items.firstIndex(where: { $0.square == move.from })!
            items[m].square = move.to
            if let np = game.position[move.to] { items[m].piece = np }
            if kind == .king, abs(move.to.file - move.from.file) == 2 {
                let kingside = move.to.file > move.from.file
                let rookFrom = Square(file: kingside ? 7 : 0, rank: move.from.rank)
                let rookTo = Square(file: kingside ? 5 : 3, rank: move.from.rank)
                if let r = items.firstIndex(where: { $0.square == rookFrom }) { items[r].square = rookTo }
            }
        }
        pieceStack.append(items)
        selected = nil
        gameOverDismissed = false
        coach.didPlay(byHuman: byHuman)
        positionDidChange()
        return true
    }

    /// Called after every move, undo and new game: cancels any running search, then starts one if it is the computer's turn.
    func positionDidChange() {
        cancelSearch()
        coach.positionChanged()
        guard computerEnabled, mode == .versusComputer, !isGameOver, sideToMove != humanColor else { return }
        startSearch()
    }

    private func cancelSearch() {
        searchGeneration += 1
        searchFlag?.cancel()
        searchFlag = nil
        isThinking = false
    }

    private func startSearch() {
        let generation = searchGeneration
        let flag = CancelFlag()
        searchFlag = flag
        isThinking = true
        let snapshot = game
        let level = difficulty
        let minimum = minimumThinkTime
        Task { @MainActor [weak self] in
            let started = ContinuousClock.now
            let move = await Task.detached(priority: .userInitiated) {
                Engine.bestMove(in: snapshot, difficulty: level, shouldStop: { flag.isCancelled })
            }.value
            guard let self, generation == self.searchGeneration, !flag.isCancelled else { return }
            let elapsed = started.duration(to: .now)
            let wait = Duration.seconds(minimum) - elapsed
            if wait > .zero {
                try? await Task.sleep(for: wait)
                guard generation == self.searchGeneration, !flag.isCancelled else { return }
            }
            self.searchFlag = nil
            self.isThinking = false
            if let move { self.perform(move) }
        }
    }
}
