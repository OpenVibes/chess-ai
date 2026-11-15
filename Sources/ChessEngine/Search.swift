import ChessCore
import Dispatch

struct SearchInfo {
    /// Deepest fully completed iteration (0 if none).
    var depth = 0
    var nodes = 0
    /// Score of the last completed iteration, side to move's point of view.
    var score = 0
}

struct SearchLimits {
    var maxDepth: Int
    /// Wall-clock budget in nanoseconds; nil = no time limit.
    var budgetNanos: UInt64?
}

@inline(__always)
func kindIndex(_ kind: PieceKind) -> Int {
    switch kind {
    case .pawn: return 0
    case .knight: return 1
    case .bishop: return 2
    case .rook: return 3
    case .queen: return 4
    case .king: return 5
    }
}

/// One search. All state is per instance, nothing is shared between calls.
final class Searcher {
    static let infinity = 32_000
    static let mate = 30_000
    /// Scores at or beyond this magnitude are forced mates.
    static let mateBound = 29_000
    static let maxPly = 100

    private let shouldStop: () -> Bool
    private var deadline: UInt64 = .max
    private var enforceDeadline = false
    private(set) var stopped = false
    private(set) var nodes = 0

    /// Repetition keys of the positions on the current search path (index = ply).
    private var path: [RepetitionKey]
    /// Keys that already occurred at least twice in the game so far.
    private let repeatedInGame: Set<RepetitionKey>

    private var killers = [Move?](repeating: nil, count: Searcher.maxPly * 2)
    private var history = [Int](repeating: 0, count: 2 * 4096)
    private var pvTable = [Move?](repeating: nil, count: Searcher.maxPly * Searcher.maxPly)
    private var pvLength = [Int](repeating: 0, count: Searcher.maxPly)
    private var previousPV: [Move] = []

    init(game: Game, shouldStop: @escaping () -> Bool) {
        self.shouldStop = shouldStop
        let rootKey = game.position.repetitionKey
        path = [RepetitionKey](repeating: rootKey, count: Searcher.maxPly)

        var counts: [RepetitionKey: Int] = [:]
        for record in game.history {
            counts[record.positionBefore.repetitionKey, default: 0] += 1
        }
        counts[rootKey, default: 0] += 1
        var twice = Set<RepetitionKey>()
        for (key, n) in counts where n >= 2 { twice.insert(key) }
        repeatedInGame = twice
    }

    // MARK: Clock and cancellation

    @inline(__always)
    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// True (and `stopped` set) when the search must unwind.
    private func poll() -> Bool {
        if shouldStop() { stopped = true; return true }
        if enforceDeadline && Searcher.now() >= deadline { stopped = true; return true }
        return false
    }

    // MARK: Move ordering

    /// Index (0 = pawn ... 4 = queen) of the piece `move` captures, nil for a quiet move.
    @inline(__always)
    private func victimIndex(_ position: Position, _ move: Move, mover: PieceKind) -> Int? {
        if let v = position[move.to] { return kindIndex(v.kind) }
        // A pawn changing file onto an empty square can only be en passant.
        if mover == .pawn && move.from.file != move.to.file { return 0 }
        return nil
    }

    private func orderScore(_ position: Position, _ move: Move, side: Int, ply: Int) -> Int {
        guard let mover = position[move.from]?.kind else { return 0 }
        if let victim = victimIndex(position, move, mover: mover) {
            var s = 1_000_000 + victim * 16 + (5 - kindIndex(mover))
            if move.promotion == .queen { s += 50_000 }
            return s
        }
        if let promo = move.promotion { return promo == .queen ? 1_040_000 : -1 }
        if ply < Searcher.maxPly {
            if killers[ply * 2] == move { return 900_000 }
            if killers[ply * 2 + 1] == move { return 800_000 }
        }
        return history[side * 4096 + move.from.index * 64 + move.to.index]
    }

    private func recordCutoff(_ position: Position, _ move: Move, depth: Int, ply: Int) {
        guard move.promotion == nil, let mover = position[move.from]?.kind,
              victimIndex(position, move, mover: mover) == nil else { return }
        if ply < Searcher.maxPly {
            if killers[ply * 2] != move {
                killers[ply * 2 + 1] = killers[ply * 2]
                killers[ply * 2] = move
            }
        }
        let side = position.sideToMove == .white ? 0 : 1
        let i = side * 4096 + move.from.index * 64 + move.to.index
        history[i] = min(history[i] + depth * depth, 400_000)
    }

    private func updatePV(ply: Int, move: Move) {
        let base = ply * Searcher.maxPly
        pvTable[base] = move
        let childLength = pvLength[ply + 1]
        if childLength > 0 {
            let childBase = (ply + 1) * Searcher.maxPly
            for i in 0..<childLength { pvTable[base + 1 + i] = pvTable[childBase + i] }
        }
        pvLength[ply] = childLength + 1
    }

    @inline(__always)
    private func signedEval(_ position: Position) -> Int {
        let e = Evaluation.evaluate(position)
        return position.sideToMove == .white ? e : -e
    }

    // MARK: Search

    /// Negamax alpha-beta with principal variation search. Score is from the side to move's view.
    private func search(_ position: Position, depth: Int, alpha: Int, beta: Int,
                        ply: Int, onPV: Bool) -> Int {
        pvLength[ply] = 0
        if stopped { return 0 }

        if ply > 0 {
            if position.hasInsufficientMaterial { return 0 }
            let key = position.repetitionKey
            var i = ply - 2
            let lowest = max(0, ply - position.halfmoveClock)
            while i >= lowest {
                if path[i] == key { return 0 }
                i -= 2
            }
            if !repeatedInGame.isEmpty && repeatedInGame.contains(key) { return 0 }
            path[ply] = key
        }

        if depth <= 0 || ply >= Searcher.maxPly - 2 {
            return quiesce(position, alpha, beta, ply)
        }

        nodes &+= 1
        if nodes & 1023 == 0 && poll() { return 0 }

        let inCheck = position.isInCheck
        var moves = position.legalMoves()
        if moves.isEmpty { return inCheck ? -Searcher.mate + ply : 0 }
        if position.halfmoveClock >= 100 { return 0 }

        let pvMove: Move? = (onPV && ply < previousPV.count) ? previousPV[ply] : nil
        let side = position.sideToMove == .white ? 0 : 1
        let n = moves.count
        var scores = [Int](repeating: 0, count: n)
        for j in 0..<n {
            scores[j] = (moves[j] == pvMove) ? 10_000_000
                : orderScore(position, moves[j], side: side, ply: ply)
        }

        var best = -Searcher.infinity
        var a = alpha
        for i in 0..<n {
            // Selection: bring the best remaining move to slot i.
            var top = i
            for j in (i + 1)..<n where scores[j] > scores[top] { top = j }
            if top != i { moves.swapAt(i, top); scores.swapAt(i, top) }

            let move = moves[i]
            let child = position.applying(move)
            var score: Int
            if i == 0 {
                score = -search(child, depth: depth - 1, alpha: -beta, beta: -a,
                                ply: ply + 1, onPV: onPV && move == pvMove)
            } else {
                score = -search(child, depth: depth - 1, alpha: -a - 1, beta: -a,
                                ply: ply + 1, onPV: false)
                if score > a && score < beta && !stopped {
                    score = -search(child, depth: depth - 1, alpha: -beta, beta: -a,
                                    ply: ply + 1, onPV: false)
                }
            }
            if stopped { return 0 }

            if score > best {
                best = score
                if score > a {
                    a = score
                    updatePV(ply: ply, move: move)
                    if a >= beta {
                        recordCutoff(position, move, depth: depth, ply: ply)
                        break
                    }
                }
            }
        }
        return best
    }

    /// Captures (and queen promotions), plus all evasions when in check. Stand-pat otherwise.
    private func quiesce(_ position: Position, _ alpha: Int, _ beta: Int, _ ply: Int) -> Int {
        if stopped { return 0 }
        nodes &+= 1
        if nodes & 1023 == 0 && poll() { return 0 }

        if position.hasInsufficientMaterial { return 0 }
        let inCheck = position.isInCheck
        let moves = position.legalMoves()
        if moves.isEmpty { return inCheck ? -Searcher.mate + ply : 0 }
        if position.halfmoveClock >= 100 { return 0 }

        var a = alpha
        var best = -Searcher.infinity
        if !inCheck {
            best = signedEval(position)
            if best >= beta { return best }
            if best > a { a = best }
        }
        if ply >= Searcher.maxPly - 1 { return inCheck ? signedEval(position) : best }

        var candidates = [Move]()
        var scores = [Int]()
        for move in moves {
            guard let mover = position[move.from]?.kind else { continue }
            if let victim = victimIndex(position, move, mover: mover) {
                var s = 1_000_000 + victim * 16 + (5 - kindIndex(mover))
                if move.promotion == .queen { s += 50_000 }
                candidates.append(move); scores.append(s)
            } else if move.promotion == .queen {
                candidates.append(move); scores.append(1_040_000)
            } else if inCheck {
                candidates.append(move)
                scores.append(move.promotion == nil ? 0 : -1)
            }
        }

        let n = candidates.count
        for i in 0..<n {
            var top = i
            for j in (i + 1)..<n where scores[j] > scores[top] { top = j }
            if top != i { candidates.swapAt(i, top); scores.swapAt(i, top) }

            let child = position.applying(candidates[i])
            let score = -quiesce(child, -beta, -a, ply + 1)
            if stopped { return 0 }
            if score > best {
                best = score
                if score > a {
                    a = score
                    if a >= beta { break }
                }
            }
        }
        return best
    }

    // MARK: Root

    private func rootOrder(_ position: Position, _ moves: [Move]) -> [Move] {
        let side = position.sideToMove == .white ? 0 : 1
        let keyed = moves.map { (orderScore(position, $0, side: side, ply: 0), $0) }
        // Stable: equal scores keep generation order.
        return keyed.enumerated()
            .sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }
            .map { $0.element.1 }
    }

    /// Iterative deepening. Returns the best move of the last completed iteration, upgraded by a
    /// partially searched deeper iteration only when that iteration fully searched a better move.
    func iterate(root: Position, moves rootMoves: [Move],
                 limits: SearchLimits) -> (move: Move, info: SearchInfo) {
        var ordered = rootOrder(root, rootMoves)
        var best = ordered[0]
        var info = SearchInfo()
        let useDeadline = limits.budgetNanos != nil
        if let budget = limits.budgetNanos { deadline = Searcher.now() &+ budget }

        let inf = Searcher.infinity
        for depth in 1...max(1, limits.maxDepth) {
            if shouldStop() { stopped = true; break }
            if depth > 1 && useDeadline && Searcher.now() >= deadline { break }
            // Depth 1 always completes: the budget is not enforced until it is done.
            enforceDeadline = useDeadline && depth > 1

            var alpha = -inf
            var iterationBest: Move?
            var iterationScore = -inf
            pvLength[0] = 0

            for (index, move) in ordered.enumerated() {
                let child = root.applying(move)
                var score: Int
                if index == 0 {
                    score = -search(child, depth: depth - 1, alpha: -inf, beta: -alpha,
                                    ply: 1, onPV: !previousPV.isEmpty)
                } else {
                    score = -search(child, depth: depth - 1, alpha: -alpha - 1, beta: -alpha,
                                    ply: 1, onPV: false)
                    if score > alpha && !stopped {
                        score = -search(child, depth: depth - 1, alpha: -inf, beta: -alpha,
                                        ply: 1, onPV: false)
                    }
                }
                if stopped { break }
                if score > alpha {
                    alpha = score
                    iterationBest = move
                    iterationScore = score
                    updatePV(ply: 0, move: move)
                }
            }

            if stopped {
                if let b = iterationBest { best = b }
                break
            }
            guard let b = iterationBest else { break }
            best = b
            info.depth = depth
            info.score = iterationScore
            if let idx = ordered.firstIndex(of: b), idx != 0 {
                ordered.remove(at: idx)
                ordered.insert(b, at: 0)
            }
            previousPV = (0..<pvLength[0]).compactMap { pvTable[$0] }
            if abs(iterationScore) >= Searcher.mateBound { break }
        }
        info.nodes = nodes
        return (best, info)
    }

    /// Easy level: one-ply search (with quiescence) of every root move, then a random pick among
    /// the moves within `margin` centipawns of the best.
    func pickRandom<G: RandomNumberGenerator>(root: Position, moves rootMoves: [Move], margin: Int,
                                              using rng: inout G) -> (move: Move, info: SearchInfo) {
        let ordered = rootOrder(root, rootMoves)
        var scored: [(Move, Int)] = []
        let inf = Searcher.infinity
        for move in ordered {
            if shouldStop() { stopped = true; break }
            let child = root.applying(move)
            let score = -search(child, depth: 0, alpha: -inf, beta: inf, ply: 1, onPV: false)
            if stopped { break }
            scored.append((move, score))
        }
        var info = SearchInfo()
        info.nodes = nodes
        guard let bestScore = scored.map({ $0.1 }).max() else { return (ordered[0], info) }
        info.depth = 1
        info.score = bestScore
        let candidates = scored.filter { $0.1 >= bestScore - margin }.map { $0.0 }
        let pick = candidates[Int.random(in: 0..<candidates.count, using: &rng)]
        return (pick, info)
    }
}
