import XCTest
import Dispatch
import ChessCore
@testable import ChessEngine

// MARK: - Helpers

/// Small deterministic generator (SplitMix64) so playouts are reproducible.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func position(_ fen: String, file: StaticString = #filePath, line: UInt = #line) -> Position {
    guard let p = Position(fen: fen) else {
        XCTFail("bad FEN \(fen)", file: file, line: line)
        return .start
    }
    return p
}

func isMate(_ p: Position) -> Bool { p.isInCheck && p.legalMoves().isEmpty }

func hasMateIn1(_ p: Position) -> Bool {
    p.legalMoves().contains { isMate(p.applying($0)) }
}

/// Brute force: the side to move can force mate on its second move.
func hasMateIn2(_ p: Position) -> Bool {
    for m in p.legalMoves() {
        let q = p.applying(m)
        let replies = q.legalMoves()
        if replies.isEmpty { continue }
        if replies.allSatisfy({ hasMateIn1(q.applying($0)) }) { return true }
    }
    return false
}

/// Colour-mirrored FEN: ranks flipped, piece colours, side, castling and en passant swapped.
func mirrorFEN(_ fen: String) -> String {
    let parts = fen.split(separator: " ").map(String.init)
    func swapCase(_ c: Character) -> Character {
        c.isUppercase ? Character(c.lowercased()) : Character(c.uppercased())
    }
    let placement = parts[0].split(separator: "/").reversed()
        .map { String($0.map { $0.isLetter ? swapCase($0) : $0 }) }
        .joined(separator: "/")
    let side = parts[1] == "w" ? "b" : "w"
    var castling = "-"
    if parts[2] != "-" {
        let swapped = Set(parts[2].map(swapCase))
        castling = "KQkq".filter { swapped.contains($0) }
    }
    var ep = "-"
    if parts[3] != "-" {
        let f = parts[3].first!
        ep = "\(f)\(parts[3].last! == "3" ? "6" : "3")"
    }
    return "\(placement) \(side) \(castling) \(ep) \(parts[4]) \(parts[5])"
}

func mirrored(_ p: Position) -> Position { position(mirrorFEN(p.fen)) }

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func seconds(since start: UInt64) -> Double { Double(now() - start) / 1e9 }

/// Plays random legal moves from `start`, returning every position reached (including terminal ones).
func randomPlayout(from start: Position = .start, plies: Int, rng: inout SeededRNG) -> [Position] {
    var p = start
    var out = [p]
    for _ in 0..<plies {
        let moves = p.legalMoves()
        if moves.isEmpty || p.hasInsufficientMaterial || p.halfmoveClock >= 100 { break }
        p = p.applying(moves[Int.random(in: 0..<moves.count, using: &rng)])
        out.append(p)
    }
    return out
}

final class ChessEngineTests: XCTestCase {
    private let mateIn1: [(name: String, fen: String)] = [
        ("back rank Ra8", "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1"),
        ("Qxf7 scholar", "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4"),
        ("black back rank Ra1", "r5k1/8/8/8/8/8/5PPP/6K1 b - - 0 1"),
        ("fool's mate Qh4", "rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2"),
    ]

    /// Verified by brute force in `testMateIn2PositionsAreReallyMateIn2`.
    private let mateIn2: [(name: String, fen: String)] = [
        ("rook + pawn ending", "7k/3p4/8/8/K4R2/8/8/2R5 w - - 0 1"),
        ("two rooks", "8/8/8/7k/3RRK2/8/8/8 w - - 0 1"),
        ("queen + knight", "2k5/8/8/K7/3Q4/3N4/8/8 w - - 0 1"),
        ("rook ladder", "8/8/K7/7k/3R4/8/5R2/8 w - - 0 1"),
        ("king + rook", "k7/8/3K4/7R/8/8/8/8 w - - 0 1"),
        ("queen and king", "8/8/8/8/8/2Q5/7k/4K3 w - - 0 1"),
    ]

    private var mateIn2WithBlack: [(name: String, fen: String)] {
        mateIn2.map { ("black: " + $0.name, mirrorFEN($0.fen)) }
    }

    private func move(_ difficulty: Difficulty, _ p: Position,
                      file: StaticString = #filePath, line: UInt = #line) -> Move? {
        Engine.bestMove(in: Game(position: p), difficulty: difficulty)
    }

    // MARK: Basics

    func testDifficultyLevels() {
        XCTAssertEqual(Difficulty.allCases.count, 3)
    }

    // MARK: Mate in 1

    func testMateInOne() {
        for level in [Difficulty.medium, .hard] {
            for (name, fen) in mateIn1 {
                let p = position(fen)
                guard let m = move(level, p) else { XCTFail("\(level) \(name): nil"); continue }
                XCTAssertTrue(p.legalMoves().contains(m), "\(level) \(name): illegal \(m.uci)")
                XCTAssertTrue(isMate(p.applying(m)), "\(level) \(name): \(m.uci) is not mate")
            }
        }
    }

    func testEasyFindsMateInOne() {
        for (name, fen) in mateIn1 {
            let p = position(fen)
            var rng = SeededRNG(seed: 5)
            let result = Engine.analyze(game: Game(position: p), difficulty: .easy,
                                        shouldStop: { false }, using: &rng)
            XCTAssertNotNil(result, name)
            if let m = result?.move { XCTAssertTrue(isMate(p.applying(m)), "easy \(name): \(m.uci)") }
        }
    }

    // MARK: Mate in 2

    func testMateIn2PositionsAreReallyMateIn2() {
        for (name, fen) in mateIn2 + mateIn2WithBlack {
            let p = position(fen)
            XCTAssertFalse(p.isInCheck, name)
            XCTAssertFalse(hasMateIn1(p), "\(name) already has mate in 1")
            XCTAssertTrue(hasMateIn2(p), "\(name) is not a forced mate in 2")
        }
    }

    private func assertMateIn2(_ level: Difficulty, _ cases: [(name: String, fen: String)],
                               file: StaticString = #filePath, line: UInt = #line) {
        for (name, fen) in cases {
            let p = position(fen)
            guard let first = move(level, p) else { XCTFail("\(level) \(name): nil", file: file, line: line); continue }
            XCTAssertTrue(p.legalMoves().contains(first), "\(level) \(name): illegal", file: file, line: line)
            let q = p.applying(first)
            XCTAssertFalse(q.legalMoves().isEmpty && !q.isInCheck, "\(level) \(name): stalemate", file: file, line: line)
            for reply in q.legalMoves() {
                let r = q.applying(reply)
                guard let second = move(level, r) else {
                    XCTFail("\(level) \(name): no move after \(first.uci) \(reply.uci)", file: file, line: line)
                    continue
                }
                XCTAssertTrue(r.legalMoves().contains(second), file: file, line: line)
                XCTAssertTrue(isMate(r.applying(second)),
                              "\(level) \(name): \(first.uci) \(reply.uci) \(second.uci) is not mate",
                              file: file, line: line)
            }
        }
    }

    func testMateInTwoHard() { assertMateIn2(.hard, mateIn2 + mateIn2WithBlack) }
    func testMateInTwoMedium() { assertMateIn2(.medium, mateIn2 + mateIn2WithBlack) }

    // MARK: Tactics

    func testTakesHangingQueen() {
        // White rook takes the undefended queen; black bishop takes the undefended queen.
        let cases: [(String, String)] = [
            ("4k3/8/8/3q4/8/8/8/3RK3 w - - 0 1", "d1d5"),
            ("4k3/8/8/3q4/8/5B2/8/4K3 w - - 0 1", "f3d5"),
            ("3rk3/8/8/8/8/8/3Q4/4K3 b - - 0 1", "d8d2"),
        ]
        for (n, (fen, expected)) in cases.enumerated() {
            let p = position(fen)
            for level in (n == 0 ? [Difficulty.medium, .hard] : [.medium]) {
                XCTAssertEqual(move(level, p)?.uci, expected, "\(level) \(fen)")
            }
            var rng = SeededRNG(seed: 11)
            let easy = Engine.analyze(game: Game(position: p), difficulty: .easy, shouldStop: { false }, using: &rng)
            XCTAssertEqual(easy?.move.uci, expected, "easy \(fen)")
        }
    }

    func testDoesNotHangQueenToPoisonedPawn() {
        // Qxd7+ loses the queen for a pawn (the pawn is guarded by king and rook).
        let p = position("3rk3/3p4/8/8/8/8/8/3QK3 w - - 0 1")
        for level in [Difficulty.medium, .hard] {
            let m = move(level, p)
            XCTAssertNotNil(m)
            XCTAssertNotEqual(m?.uci, "d1d7", "\(level) took the poisoned pawn")
        }
    }

    func testSavesAttackedQueen() {
        // The queen on d4 is attacked by the e5 pawn. Whatever the engine plays, the queen must
        // not be capturable for nothing afterwards.
        let p = position("4k3/8/8/4p3/3Q4/8/8/4K3 w - - 0 1")
        for level in [Difficulty.medium, .hard] {
            guard let m = move(level, p) else { XCTFail("nil"); continue }
            let q = p.applying(m)
            for reply in q.legalMoves() {
                if let captured = q[reply.to] {
                    XCTAssertNotEqual(captured.kind, .queen, "\(level) \(m.uci) hangs the queen to \(reply.uci)")
                }
            }
        }
    }

    // MARK: Terminal positions and legality

    func testNilWhenNoLegalMoves() {
        let checkmated = position("7k/6Q1/6K1/8/8/8/8/8 b - - 0 1")
        let stalemated = position("7k/5K2/6Q1/8/8/8/8/8 b - - 0 1")
        XCTAssertTrue(checkmated.legalMoves().isEmpty && checkmated.isInCheck)
        XCTAssertTrue(stalemated.legalMoves().isEmpty && !stalemated.isInCheck)
        for level in Difficulty.allCases {
            XCTAssertNil(move(level, checkmated), "\(level) mate")
            XCTAssertNil(move(level, stalemated), "\(level) stalemate")
        }
    }

    func testSingleLegalMove() {
        let p = position("7k/8/6K1/8/8/8/8/R7 b - - 0 1")   // only Kg8
        let legal = p.legalMoves()
        guard legal.count == 1 else { return XCTFail("setup: \(legal.count) legal moves") }
        for level in Difficulty.allCases { XCTAssertEqual(move(level, p), legal[0]) }
    }

    func testRandomPlayoutsGiveLegalMoves() {
        var rng = SeededRNG(seed: 2026)
        var positions: [Position] = []
        for _ in 0..<8 { positions += randomPlayout(plies: 40, rng: &rng) }
        XCTAssertGreaterThanOrEqual(positions.count, 200)

        var easyRNG = SeededRNG(seed: 99)
        for (i, p) in positions.enumerated() {
            let legal = p.legalMoves()
            let m = Engine.analyze(game: Game(position: p), difficulty: .easy,
                                   shouldStop: { false }, using: &easyRNG)?.move
            if legal.isEmpty { XCTAssertNil(m) } else {
                XCTAssertNotNil(m)
                if let m { XCTAssertTrue(legal.contains(m), "easy: illegal \(m.uci) in \(p.fen)") }
            }
            if i % 40 == 0, !legal.isEmpty {
                let mm = move(.medium, p)
                XCTAssertTrue(mm.map(legal.contains) ?? false, "medium: illegal in \(p.fen)")
            }
        }
    }

    func testPublicEasyIsLegalAndUsesSystemRandomness() {
        let p = Position.start
        for _ in 0..<5 {
            let m = move(.easy, p)
            XCTAssertTrue(m.map(p.legalMoves().contains) ?? false)
        }
    }

    // MARK: Repetition

    /// Plays `ucis` from `fen` through `Game.play`.
    private func game(from fen: String, playing ucis: [String]) -> Game {
        var g = Game(position: position(fen))
        for u in ucis {
            guard let m = g.position.legalMoves().first(where: { $0.uci == u }), g.play(m) else {
                XCTFail("could not play \(u)")
                break
            }
        }
        return g
    }

    func testBehindEngineSeeksRepetition() {
        // White (lone king against a queen) has shuffled; Kh1-g1 would repeat a position that
        // already occurred twice, which beats every other move.
        let g = game(from: "1q2k3/8/8/8/8/8/8/6K1 b - - 0 1",
                     playing: ["b8c8", "g1h1", "c8b8", "h1g1", "b8c8", "g1h1", "c8b8"])
        XCTAssertEqual(g.position.sideToMove, .white)
        let m = Engine.bestMove(in: g, difficulty: .medium)
        XCTAssertEqual(m?.uci, "h1g1")
    }

    func testAheadEngineAvoidsRepetition() {
        // Black (queen up) must not play Qb8-c8, which would be a third occurrence.
        let g = game(from: "2q1k3/8/8/8/8/8/8/6K1 w - - 0 1",
                     playing: ["g1h1", "c8b8", "h1g1", "b8c8", "g1h1", "c8b8", "h1g1"])
        XCTAssertEqual(g.position.sideToMove, .black)
        let m = Engine.bestMove(in: g, difficulty: .medium)
        XCTAssertNotNil(m)
        XCTAssertNotEqual(m?.uci, "b8c8")
    }

    // MARK: Evaluation

    func testEvaluateStartIsZero() {
        XCTAssertEqual(Engine.evaluate(.start), 0)
    }

    func testEvaluateIsColourSymmetric() {
        let fens = [
            "r1bq1rk1/pp2ppbp/2np1np1/8/3NP3/2N1BP2/PPPQ2PP/R3KB1R w KQ - 0 9",
            "r3k2r/pppq1ppp/2n2n2/3pp3/1b1PP3/2N2N2/PPP1BPPP/R1BQK2R w KQkq e6 0 7",
            "8/5pk1/6p1/8/3P4/4K3/8/8 w - - 0 1",
            "4k3/8/8/8/8/8/8/3QK3 w - - 0 1",
            "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2",
            "2r3k1/1b3ppp/p3p3/1p6/4P3/1P2B3/P4PPP/2R3K1 b - - 3 25",
        ]
        for fen in fens {
            let p = position(fen)
            XCTAssertEqual(Engine.evaluate(mirrored(p)), -Engine.evaluate(p), fen)
        }
    }

    func testEvaluateMaterial() {
        let up = position("4k3/8/8/8/8/8/8/3QK3 w - - 0 1")
        XCTAssertGreaterThan(Engine.evaluate(up), 800)
        XCTAssertLessThan(Engine.evaluate(mirrored(up)), -800)
        let pawnDown = position("rnbqkbnr/ppp1pppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
        XCTAssertGreaterThan(Engine.evaluate(pawnDown), 50)
    }

    func testEvaluateEndgameKingPrefersCentre() {
        let centre = position("8/8/8/4k3/8/8/8/K6R w - - 0 1")
        let edge = position("4k3/8/8/8/8/8/8/K6R w - - 0 1")
        // Black king in the centre is better for Black than on the edge.
        XCTAssertLessThan(Engine.evaluate(centre), Engine.evaluate(edge))
    }

    // MARK: Timing and cancellation

    func testHardRespectsTimeBudget() {
        let fens = [Position.start.fen,
                    "r1bq1rk1/pp2ppbp/2np1np1/8/3NP3/2N1BP2/PPPQ2PP/R3KB1R w KQ - 0 9"]
        for fen in fens {
            let p = position(fen)
            let t = now()
            let m = move(.hard, p)
            let elapsed = seconds(since: t)
            XCTAssertLessThan(elapsed, 2.5, fen)
            XCTAssertTrue(m.map(p.legalMoves().contains) ?? false, fen)
        }
    }

    func testShouldStopEndsSearchPromptly() {
        let p = position("r1bq1rk1/pp2ppbp/2np1np1/8/3NP3/2N1BP2/PPPQ2PP/R3KB1R w KQ - 0 9")
        let t = now()
        let m = Engine.bestMove(in: Game(position: p), difficulty: .hard,
                                shouldStop: { DispatchTime.now().uptimeNanoseconds - t > 100_000_000 })
        let elapsed = seconds(since: t)
        XCTAssertLessThan(elapsed, 0.5)
        XCTAssertTrue(m.map(p.legalMoves().contains) ?? false)
    }

    func testShouldStopAlreadyTrueStillReturnsLegalMove() {
        let p = position("r1bq1rk1/pp2ppbp/2np1np1/8/3NP3/2N1BP2/PPPQ2PP/R3KB1R w KQ - 0 9")
        for level in Difficulty.allCases {
            let t = now()
            let m = Engine.bestMove(in: Game(position: p), difficulty: level, shouldStop: { true })
            XCTAssertLessThan(seconds(since: t), 0.5, "\(level)")
            XCTAssertTrue(m.map(p.legalMoves().contains) ?? false, "\(level)")
        }
    }

    func testMediumIsDeterministic() {
        let p = position("r1bq1rk1/pp2ppbp/2np1np1/8/3NP3/2N1BP2/PPPQ2PP/R3KB1R w KQ - 0 9")
        let a = move(.medium, p)
        let b = move(.medium, p)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }
}
