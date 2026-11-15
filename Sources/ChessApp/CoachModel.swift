import Foundation
import Observation
import ChessCore
import ChessEngine
import ChessCoach

// MARK: - Small value types

struct BoardArrow: Equatable {
    let from: Square
    let to: Square
}

/// State of a request for the model's explanation.
enum AIText: Equatable {
    case none
    case loading
    case text(String)
    case failed(String)
}

struct HintInfo: Equatable {
    let move: Move
    let san: String
    var ai: AIText
}

extension MoveQuality {
    /// The mark shown after the move in the move list (nil for "good").
    var mark: String? {
        switch self {
        case .best: return "\u{2605}"
        case .excellent: return "!"
        case .good: return nil
        case .inaccuracy: return "?!"
        case .mistake: return "?"
        case .blunder: return "??"
        }
    }

    var isBad: Bool { self == .inaccuracy || self == .mistake || self == .blunder }
}

// MARK: - Analysis cache and jobs

struct AnalysisKey: Hashable {
    let position: Position
    let plies: Int
}

/// One running engine analysis. `interest` counts the consumers that still want the result;
/// when it drops to zero the search is cancelled.
@MainActor
final class AnalysisJob {
    let flag: CancelFlag
    var interest = 0
    let task: Task<PositionAnalysis?, Never>

    init(game: Game, limits: AnalysisLimits) {
        let f = CancelFlag()
        flag = f
        task = Task.detached(priority: .utility) {
            let analysis = Engine.analyse(game, limits: limits, shouldStop: { f.isCancelled })
            return f.isCancelled ? nil : analysis
        }
    }
}

/// A consumer's claim on an analysis: either already cached or backed by a shared job.
@MainActor
final class AnalysisTicket {
    fileprivate let key: AnalysisKey
    fileprivate let job: AnalysisJob?
    private(set) var cached: PositionAnalysis?
    private weak var owner: CoachModel?
    private var released = false

    fileprivate init(key: AnalysisKey, job: AnalysisJob?, cached: PositionAnalysis?, owner: CoachModel) {
        self.key = key; self.job = job; self.cached = cached; self.owner = owner
    }

    /// The analysis, or nil when it was cancelled.
    func value() async -> PositionAnalysis? {
        if let cached { return cached }
        guard let job else { return nil }
        let result = await job.task.value
        if let result {
            cached = result
            owner?.store(result, for: key)
        }
        return result
    }

    func release() {
        guard !released else { return }
        released = true
        guard let job else { return }
        owner?.release(job, key: key)
    }
}

@MainActor
private final class ReviewWork {
    var tickets: [AnalysisTicket] = []
    var task: Task<Void, Never>?
    func releaseTickets() {
        tickets.forEach { $0.release() }
        tickets = []
    }
    func cancel() {
        task?.cancel()
        releaseTickets()
    }
}

// MARK: - Coach state and logic

/// Everything the coach does: background analysis of each position, reviews per ply,
/// AI explanations, hints and the arrow. Owned by `GameModel`; judgement comes from `Engine` and `Coach`.
@MainActor @Observable
final class CoachModel {
    let settings: CoachSettings
    @ObservationIgnored let transport: LLMTransport
    @ObservationIgnored let limits: AnalysisLimits
    @ObservationIgnored weak var host: GameModel?

    /// Analysis of the current position; nil while it is being computed.
    private(set) var currentAnalysis: PositionAnalysis?
    /// Last known evaluation (White's view). Kept while the next analysis runs so the bar does not jump.
    private(set) var evalScore: Score?
    private(set) var reviews: [Int: MoveReview] = [:]
    private(set) var explanations: [Int: AIText] = [:]
    private(set) var hint: HintInfo?
    private(set) var arrow: BoardArrow?
    private(set) var hintPending = false
    /// Ply picked in the move list; nil means the latest review.
    var inspectedPly: Int?

    @ObservationIgnored private var cache: [AnalysisKey: PositionAnalysis] = [:]
    @ObservationIgnored private var jobs: [AnalysisKey: AnalysisJob] = [:]
    @ObservationIgnored private var positionTicket: AnalysisTicket?
    @ObservationIgnored private var positionTask: Task<Void, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored private var reviewWork: [Int: ReviewWork] = [:]
    @ObservationIgnored private var explainTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var hintExplainTask: Task<Void, Never>?
    @ObservationIgnored private var positionEpoch = 0
    @ObservationIgnored private var gameEpoch = 0
    @ObservationIgnored private var replaying = false
    @ObservationIgnored private var lastPlayedByHuman = false

    private static let cacheLimit = 400

    init(settings: CoachSettings, transport: LLMTransport, limits: AnalysisLimits) {
        self.settings = settings
        self.transport = transport
        self.limits = limits
        settings.onChange = { [weak self] toggled in self?.settingsChanged(coachToggled: toggled) }
    }

    // MARK: Derived state

    var enabled: Bool { settings.coachEnabled }
    var showEvalBar: Bool { settings.coachEnabled && settings.evalBarEnabled }
    var visibleArrow: BoardArrow? { enabled ? arrow : nil }
    var hintAvailable: Bool { enabled && settings.hintsEnabled }

    var aiAvailable: Bool { settings.aiExplanations && settings.isModelUsable }

    /// White's share of the evaluation bar, 0…1: clamped to 5–95 % unless the game is decided by mate.
    var whiteShare: Double {
        guard let score = evalScore else { return 0.5 }
        let w = Coach.winChance(score, for: .white)
        if w <= 0 || w >= 1 { return w }
        return min(0.95, max(0.05, w))
    }

    /// The ply whose review the card shows.
    var displayedPly: Int? {
        if let p = inspectedPly, reviews[p] != nil { return p }
        return reviews.keys.max()
    }

    /// The mark for a reviewed move, hidden when the coach is off.
    func mark(ply: Int) -> (text: String, quality: MoveQuality)? {
        guard enabled, let r = reviews[ply], let m = r.quality.mark else { return nil }
        return (m, r.quality)
    }

    func moveMark(ply: Int) -> String? { mark(ply: ply)?.text }

    /// True while analysis, a review or a hint is still being worked out.
    var isBusy: Bool {
        if !reviewWork.isEmpty || hintPending { return true }
        if enabled && currentAnalysis == nil && host != nil { return true }
        return false
    }

    func waitUntilIdle(timeout: Double = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isBusy && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    // MARK: Analysis tickets

    private func ticket(for game: Game) -> AnalysisTicket {
        let key = AnalysisKey(position: game.position, plies: game.history.count)
        if let hit = cache[key] { return AnalysisTicket(key: key, job: nil, cached: hit, owner: self) }
        let job: AnalysisJob
        if let existing = jobs[key] {
            job = existing
        } else {
            job = AnalysisJob(game: game, limits: limits)
            jobs[key] = job
        }
        job.interest += 1
        return AnalysisTicket(key: key, job: job, cached: nil, owner: self)
    }

    fileprivate func store(_ analysis: PositionAnalysis, for key: AnalysisKey) {
        if cache.count >= Self.cacheLimit { cache.removeAll() }
        cache[key] = analysis
    }

    fileprivate func release(_ job: AnalysisJob, key: AnalysisKey) {
        job.interest -= 1
        if job.interest <= 0 {
            job.flag.cancel()
            if jobs[key] === job { jobs[key] = nil }
        }
    }

    private func gameAt(plies: Int) -> Game? {
        guard var g = host?.game, plies <= g.history.count else { return nil }
        while g.history.count > plies { g.undo() }
        return g
    }

    // MARK: Hooks called by GameModel

    /// Replays (headless setup) skip per-move work; `endReplay` catches up.
    func beginReplay() { replaying = true }

    func endReplay(reviewLast: Bool) {
        replaying = false
        if reviewLast, let host, enabled, lastPlayedByHuman, !host.game.history.isEmpty {
            startReview(ply: host.game.history.count - 1)
        }
        positionChanged()
    }

    /// A move was just played. Starts its review when a human made it.
    func didPlay(byHuman: Bool) {
        guard let host else { return }
        lastPlayedByHuman = byHuman
        guard enabled, byHuman, !replaying, !host.game.history.isEmpty else { return }
        startReview(ply: host.game.history.count - 1)
    }

    /// Plies were taken back: drop their reviews and anything still in flight for them.
    func didUndo() {
        guard let host else { return }
        let count = host.game.history.count
        for ply in reviewWork.keys where ply >= count {
            reviewWork[ply]?.cancel()
            reviewWork[ply] = nil
        }
        for ply in explainTasks.keys where ply >= count {
            explainTasks[ply]?.cancel()
            explainTasks[ply] = nil
        }
        reviews = reviews.filter { $0.key < count }
        explanations = explanations.filter { $0.key < count }
    }

    func reset() {
        gameEpoch += 1
        reviewWork.values.forEach { $0.cancel() }
        reviewWork = [:]
        explainTasks.values.forEach { $0.cancel() }
        explainTasks = [:]
        hintExplainTask?.cancel()
        reviews = [:]
        explanations = [:]
        cache = [:]
        currentAnalysis = nil
        evalScore = nil
        lastPlayedByHuman = false
    }

    /// Called after every move, undo and new game.
    func positionChanged() {
        positionEpoch += 1
        positionTask?.cancel()
        positionTask = nil
        positionTicket?.release()
        positionTicket = nil
        hintTask?.cancel()
        hintExplainTask?.cancel()
        hintPending = false
        hint = nil
        arrow = nil
        inspectedPly = nil
        currentAnalysis = nil
        guard enabled, !replaying, let host else { return }
        let t = ticket(for: host.game)
        positionTicket = t
        if let hit = t.cached {
            currentAnalysis = hit
            evalScore = hit.score
            return
        }
        let epoch = positionEpoch
        positionTask = Task { @MainActor [weak self] in
            let result = await t.value()
            guard let self, epoch == self.positionEpoch, let result else { return }
            self.currentAnalysis = result
            self.evalScore = result.score
        }
    }

    private func settingsChanged(coachToggled: Bool) {
        guard coachToggled else { return }
        if enabled {
            positionChanged()
        } else {
            positionEpoch += 1
            positionTask?.cancel()
            positionTicket?.release()
            positionTicket = nil
            hintTask?.cancel()
            hintExplainTask?.cancel()
            hintPending = false
            hint = nil
            arrow = nil
            currentAnalysis = nil
            reviewWork.values.forEach { $0.cancel() }
            reviewWork = [:]
        }
    }

    // MARK: Reviews

    private func startReview(ply: Int) {
        guard let host, ply < host.game.history.count,
              let beforeGame = gameAt(plies: ply), let afterGame = gameAt(plies: ply + 1) else { return }
        let record = host.game.history[ply]
        reviewWork[ply]?.cancel()
        let work = ReviewWork()
        reviewWork[ply] = work
        let before = ticket(for: beforeGame)
        let after = ticket(for: afterGame)
        work.tickets = [before, after]
        let epoch = gameEpoch
        work.task = Task { @MainActor [weak self] in
            let b = await before.value()
            let a = await after.value()
            guard let self, epoch == self.gameEpoch, self.reviewWork[ply] === work else { return }
            self.reviewWork[ply] = nil
            work.releaseTickets()
            guard !Task.isCancelled, let b, let a else { return }
            let review = Coach.review(record: record, before: b, after: a)
            self.reviews[ply] = review
            self.explain(ply: ply, review: review, record: record)
        }
    }

    // MARK: AI explanations

    private func makeClient() -> LLMClient {
        LLMClient(config: settings.modelConfig, apiKey: settings.currentKey(), transport: transport)
    }

    private func recentSAN(before ply: Int) -> [String] {
        guard let host else { return [] }
        let history = host.game.history
        return history[max(0, ply - 6)..<min(ply, history.count)].map(\.san)
    }

    private func explain(ply: Int, review: MoveReview, record: MoveRecord) {
        guard aiAvailable, review.quality.isBad else { return }
        explanations[ply] = .loading
        let client = makeClient()
        let prompt = CoachPrompts.explainMove(review: review, positionBefore: record.positionBefore,
                                              recentSAN: recentSAN(before: ply))
        let epoch = gameEpoch
        explainTasks[ply]?.cancel()
        explainTasks[ply] = Task { @MainActor [weak self] in
            let outcome = await Self.ask(client, prompt)
            guard let self, !Task.isCancelled, epoch == self.gameEpoch, self.reviews[ply] == review else { return }
            self.explainTasks[ply] = nil
            self.explanations[ply] = outcome
        }
    }

    private nonisolated static func ask(_ client: LLMClient, _ prompt: String) async -> AIText {
        do {
            let reply = try await client.complete(system: CoachPrompts.coachSystem,
                                                  messages: [ChatMessage(role: .user, content: prompt)],
                                                  maxTokens: 4000)
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .failed(LLMError.emptyReply.localizedDescription) : .text(text)
        } catch is CancellationError {
            return .none
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Hint and arrow

    func requestHint() {
        guard let host, hintAvailable, host.canInteract else { return }
        if let a = currentAnalysis {
            applyHint(a)
            return
        }
        guard let t = positionTicket, !hintPending else { return }
        hintPending = true
        let epoch = positionEpoch
        hintTask = Task { @MainActor [weak self] in
            let a = await t.value()
            guard let self, epoch == self.positionEpoch else { return }
            self.hintPending = false
            self.hintTask = nil
            if let a { self.applyHint(a) }
        }
    }

    private func applyHint(_ analysis: PositionAnalysis) {
        guard let host, let move = analysis.bestMove else { return }
        let position = host.game.position
        var line: [String] = []
        var walk = position
        for m in analysis.principalVariation.prefix(4) {
            guard walk.legalMoves().contains(m) else { break }
            line.append(walk.san(for: m))
            walk = walk.applying(m)
        }
        let san = position.san(for: move)
        inspectedPly = nil
        arrow = BoardArrow(from: move.from, to: move.to)
        var info = HintInfo(move: move, san: san, ai: .none)
        if aiAvailable {
            info.ai = .loading
            let client = makeClient()
            let prompt = CoachPrompts.explainHint(position: position, bestSAN: san, line: line,
                                                  recentSAN: recentSAN(before: host.game.history.count))
            let epoch = positionEpoch
            hintExplainTask?.cancel()
            hintExplainTask = Task { @MainActor [weak self] in
                let outcome = await Self.ask(client, prompt)
                guard let self, !Task.isCancelled, epoch == self.positionEpoch, self.hint?.move == move else { return }
                self.hint?.ai = outcome
            }
        }
        hint = info
    }

    /// "Show better move": the arrow for the engine's move, only for the latest ply.
    func showBetterMove(ply: Int) {
        guard let host, ply == host.game.history.count - 1,
              let best = reviews[ply]?.bestMove else { return }
        hint = nil
        arrow = BoardArrow(from: best.from, to: best.to)
    }

    /// Selecting a move in the list shows its review (and drops a hint).
    func inspect(ply: Int) {
        guard reviews[ply] != nil else { return }
        if inspectedPly == ply { inspectedPly = nil; return }
        inspectedPly = ply
        hint = nil
        arrow = nil
    }
}
