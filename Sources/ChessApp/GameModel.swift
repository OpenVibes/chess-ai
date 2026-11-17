import SwiftUI
import Observation
import ChessCore
import ChessEngine
import ChessCoach

enum GameMode: Equatable { case twoPlayers, versusComputer, versusModel }

/// Something the coach card says about the opponent (engine fallback notice, or a model error).
enum OpponentMessage: Equatable {
    case notice(String)
    case error(String)
}

/// One entry in the Versus AI model chat.
struct ChatEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        /// The human's move, shown as a small chip with the coach's verdict next to it.
        case humanMove(ply: Int, label: String)
        /// Something the opponent said; `move` is the move it played with it, if any.
        case opponent(text: String, move: String?)
        /// The opponent moved without saying anything.
        case opponentMove(label: String)
        case human(String)
        case note(String)
    }
    let id: Int
    let kind: Kind
}

/// Result of asking the model for a move.
private enum ModelTurnOutcome: Sendable {
    case move(Move, reply: String)
    case noLegalMove
    case failed(String)
}

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
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// Fallback notice or error from the model opponent, shown in the coach card as "Opponent".
    private(set) var opponentMessage: OpponentMessage?

    /// Versus AI model chat: the timeline, the opponent's current mood, and replies still being written.
    private(set) var chat: [ChatEntry] = []
    private(set) var mood: OpponentMood = .neutral
    private(set) var chatPending = 0
    @ObservationIgnored private var nextChatID = 0
    @ObservationIgnored private var chatEpoch = 0
    @ObservationIgnored private var chatTasks: [Int: Task<Void, Never>] = [:]

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
        if hasNonHumanOpponent && sideToMove != humanColor { return false }
        return true
    }

    /// One human plays against the engine or a model.
    var hasNonHumanOpponent: Bool { mode != .twoPlayers }

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
        case .versusModel:
            return color == humanColor ? "You" : modelName
        }
    }

    /// The chat panel and banter are on: versus a model, with chat switched on.
    var chatActive: Bool { mode == .versusModel && coach.settings.chatEnabled }

    /// Whose turn it is, from the human's side: nil in two-player games and when the game is over.
    var isHumansTurn: Bool { hasNonHumanOpponent && !isGameOver && sideToMove == humanColor }

    /// "15. d4" or "15… O-O" for a ply in the history.
    func moveLabel(ply: Int) -> String {
        let record = game.history[ply]
        let n = record.positionBefore.fullmoveNumber
        return record.positionBefore.sideToMove == .white ? "\(n). \(record.san)" : "\(n)\u{2026} \(record.san)"
    }

    /// The opponent model's name for the strip and status line.
    var modelName: String {
        let name = coach.settings.modelConfig.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "AI model" : name
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
        let check = game.position.isInCheck
        if hasNonHumanOpponent {
            if sideToMove == humanColor { return check ? "Check! Your move" : "Your move" }
            let name = mode == .versusModel ? modelName : "Computer"
            return isThinking ? "\(name) is thinking…" : "\(name) to move"
        }
        let side = sideToMove == .white ? "White" : "Black"
        return check ? "Check! \(side) to move" : "\(side) to move"
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
        } while hasNonHumanOpponent && sideToMove != humanColor && !game.history.isEmpty
        gameOverDismissed = false
        coach.didUndo()
        if chatActive, !chat.isEmpty { addChat(.note("You took back a move.")) }
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
        whiteAtBottom = (mode != .twoPlayers) ? (humanColor == .white) : true
        coach.reset()
        resetChat()
        positionDidChange()
    }

    /// Plays a move and keeps the identity-tracked piece list in step.
    @discardableResult
    func perform(_ move: Move) -> Bool {
        let before = game.position
        let byHuman = !hasNonHumanOpponent || before.sideToMove == humanColor
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
        if chatActive, byHuman, hasNonHumanOpponent {
            addChat(.humanMove(ply: game.history.count - 1, label: moveLabel(ply: game.history.count - 1)))
        }
        positionDidChange()
        return true
    }

    /// Called after every move, undo and new game: cancels any running search or request, then starts one if it is the opponent's turn.
    func positionDidChange() {
        cancelSearch()
        opponentMessage = nil
        coach.positionChanged()
        guard computerEnabled, hasNonHumanOpponent, !isGameOver, sideToMove != humanColor else { return }
        if mode == .versusModel { startModelTurn() } else { startSearch() }
    }

    private func cancelSearch() {
        searchGeneration += 1
        searchFlag?.cancel()
        searchFlag = nil
        searchTask?.cancel()
        searchTask = nil
        isThinking = false
    }

    private func startSearch() {
        runEngineMove(level: difficulty, minimum: minimumThinkTime, notice: nil)
    }

    /// Searches off the main thread and plays the result. `notice` builds the card message from the SAN played.
    private func runEngineMove(level: Difficulty, minimum: Double, notice: ((String) -> String)?) {
        let generation = searchGeneration
        let flag = CancelFlag()
        searchFlag = flag
        isThinking = true
        let snapshot = game
        let minimum = minimum
        searchTask = Task { @MainActor [weak self] in
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
            self.searchTask = nil
            self.isThinking = false
            if let move {
                let san = self.game.position.san(for: move)
                if self.perform(move), let notice { self.opponentMessage = .notice(notice(san)) }
            }
        }
    }

    // MARK: Model opponent

    /// "Try again" in the error card: asks the model once more for this turn.
    func retryModelTurn() {
        guard mode == .versusModel, !isGameOver, sideToMove != humanColor, !isThinking else { return }
        opponentMessage = nil
        startModelTurn()
    }

    /// "Let the engine move" in the error card: Medium plays this one move; the model is asked again next turn.
    func letEngineMove() {
        guard mode == .versusModel, !isGameOver, sideToMove != humanColor, !isThinking else { return }
        opponentMessage = nil
        runEngineMove(level: .medium, minimum: 0, notice: nil)
    }

    private func startModelTurn() {
        let generation = searchGeneration
        let flag = CancelFlag()
        searchFlag = flag
        isThinking = true
        opponentMessage = nil
        let client = LLMClient(config: coach.settings.modelConfig, apiKey: coach.settings.currentKey(),
                               transport: coach.transport)
        let name = modelName
        let minimum = minimumThinkTime
        let banter = chatActive
        searchTask = Task { @MainActor [weak self] in
            let started = ContinuousClock.now
            guard let self else { return }
            // Give the coach a moment to judge the human's move, so the opponent can react to it.
            var context: BanterContext?
            if banter {
                if self.coach.enabled, let ply = self.lastHumanPly {
                    _ = await self.coach.review(forPly: ply, timeout: 3)
                    guard generation == self.searchGeneration, !flag.isCancelled else { return }
                }
                context = self.banterContext()
            }
            let snapshot = self.game
            let outcome = await Self.askModel(client, game: snapshot, banter: context)
            guard generation == self.searchGeneration, !flag.isCancelled else { return }
            switch outcome {
            case .failed(let message):
                self.searchFlag = nil
                self.searchTask = nil
                self.isThinking = false
                self.opponentMessage = .error(message)
            case .move(let move, let reply):
                let wait = Duration.seconds(minimum) - started.duration(to: .now)
                if wait > .zero {
                    try? await Task.sleep(for: wait)
                    guard generation == self.searchGeneration, !flag.isCancelled else { return }
                }
                self.searchFlag = nil
                self.searchTask = nil
                self.isThinking = false
                if self.perform(move), banter {
                    let label = self.moveLabel(ply: self.game.history.count - 1)
                    let said = Banter.parse(reply)
                    if let mood = said.mood { self.mood = mood }
                    if let text = said.say {
                        self.addChat(.opponent(text: text, move: label))
                    } else {
                        self.addChat(.opponentMove(label: label))
                    }
                }
            case .noLegalMove:
                self.searchFlag = nil
                self.searchTask = nil
                self.runEngineMove(level: .medium, minimum: 0) {
                    "\(name) gave no legal move, so the engine played \($0)."
                }
            }
        }
    }

    /// One request plus at most two retries. Never judges the move: `MoveParser` and `Position` decide legality.
    private nonisolated static func askModel(_ client: LLMClient, game: Game, banter: BanterContext?) async -> ModelTurnOutcome {
        let system = banter.map { Banter.opponentSystem(name: $0.name) } ?? CoachPrompts.opponentSystem
        let first = banter.map { Banter.opponentTurn(game: game, context: $0) } ?? CoachPrompts.opponentTurn(game: game)
        var messages = [ChatMessage(role: .user, content: first)]
        let legalSAN = game.position.legalMoves().map { game.position.san(for: $0) }
        for attempt in 0..<3 {
            do {
                let reply = try await client.complete(system: system, messages: messages, maxTokens: 4000)
                if let move = MoveParser.parse(reply, in: game.position) { return .move(move, reply: reply) }
                if attempt < 2 {
                    messages.append(ChatMessage(role: .assistant, content: reply))
                    messages.append(ChatMessage(role: .user, content: CoachPrompts.opponentRetry(rejected: reply, legalSAN: legalSAN)))
                }
            } catch is CancellationError {
                return .failed("Cancelled.")
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return .noLegalMove
    }

    // MARK: Chat

    /// The human's latest move, if any.
    private var lastHumanPly: Int? {
        game.history.indices.last { game.history[$0].positionBefore.sideToMove == humanColor }
    }

    private func banterContext() -> BanterContext {
        var context = BanterContext(name: modelName)
        if let ply = lastHumanPly {
            context.lastHumanMove = moveLabel(ply: ply)
            if let review = coach.reviews[ply] {
                context.verdict = review.quality
                if review.bestSAN != review.san { context.betterSAN = review.bestSAN }
            }
        }
        context.chat = chat.compactMap { entry in
            switch entry.kind {
            case .human(let text): return ChatLine(speaker: .human, text: text)
            case .opponent(let text, _): return ChatLine(speaker: .opponent, text: text)
            case .note(let text): return ChatLine(speaker: .note, text: text)
            case .humanMove, .opponentMove: return nil
            }
        }
        return context
    }

    /// Snapshot and test runs: fills the chat without asking a model.
    func seedChat(_ kinds: [ChatEntry.Kind], mood: OpponentMood) {
        kinds.forEach(addChat)
        self.mood = mood
    }

    private func addChat(_ kind: ChatEntry.Kind) {
        chat.append(ChatEntry(id: nextChatID, kind: kind))
        nextChatID += 1
    }

    private func resetChat() {
        chatEpoch += 1
        chatTasks.values.forEach { $0.cancel() }
        chatTasks = [:]
        chatPending = 0
        chat = []
        mood = .neutral
        if chatActive {
            addChat(.note("New game. You play \(humanColor == .white ? "White" : "Black") against \(modelName)."))
        }
    }

    /// The human writes in the chat; the opponent answers with one short line.
    func sendChat(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chatActive, !message.isEmpty else { return }
        let context = banterContext()
        addChat(.human(message))
        guard coach.settings.isModelUsable else {
            addChat(.note("Set up a model in Settings so \(modelName) can answer."))
            return
        }
        let client = LLMClient(config: coach.settings.modelConfig, apiKey: coach.settings.currentKey(),
                               transport: coach.transport)
        let system = Banter.chatSystem(name: context.name)
        let prompt = Banter.chatTurn(game: game, you: humanColor.opposite, context: context, message: message)
        let epoch = chatEpoch
        let id = nextChatID
        chatPending += 1
        chatTasks[id] = Task { @MainActor [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await client.complete(system: system,
                                                            messages: [ChatMessage(role: .user, content: prompt)],
                                                            maxTokens: 2000))
            } catch {
                result = .failure(error)
            }
            guard let self, epoch == self.chatEpoch, !Task.isCancelled else { return }
            self.chatTasks[id] = nil
            self.chatPending = max(0, self.chatPending - 1)
            switch result {
            case .success(let reply):
                let said = Banter.parse(reply)
                if let mood = said.mood { self.mood = mood }
                self.addChat(.opponent(text: said.say ?? "\u{2026}", move: nil))
            case .failure(let error):
                self.addChat(.note("\(self.modelName) could not answer: \(error.localizedDescription)"))
            }
        }
    }
}
