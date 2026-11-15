import XCTest
@testable import ChessCore

final class PerftTests: XCTestCase {
    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    static let kiwipete = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
    static let position3 = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"
    static let position4 = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1"
    static let position5 = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8"

    private func check(_ fen: String, _ expected: [Int], file: StaticString = #filePath, line: UInt = #line) throws {
        let p = try XCTUnwrap(Position(fen: fen), file: file, line: line)
        for (i, n) in expected.enumerated() {
            XCTAssertEqual(perft(p, depth: i + 1), n, "\(fen) depth \(i + 1)", file: file, line: line)
        }
    }

    func testDepthZeroIsOne() {
        XCTAssertEqual(perft(.start, depth: 0), 1)
    }

    func testStart() throws { try check(Self.startFEN, [20, 400, 8902, 197_281]) }
    func testKiwipete() throws { try check(Self.kiwipete, [48, 2039, 97_862]) }
    func testPosition3() throws { try check(Self.position3, [14, 191, 2812, 43_238]) }
    func testPosition4() throws { try check(Self.position4, [6, 264, 9467]) }
    func testPosition5() throws { try check(Self.position5, [44, 1486, 62_379]) }

    func testStartPerft4Timing() {
        let t = Date()
        XCTAssertEqual(perft(.start, depth: 4), 197_281)
        let dt = Date().timeIntervalSince(t)
        print("PERFT4_SECONDS \(dt)")
        XCTAssertLessThan(dt, 2.0)
    }

    /// Run on demand: `swift test -c release --filter PerftTests/testStartPerft5`.
    func testStartPerft5() {
        let t = Date()
        XCTAssertEqual(perft(.start, depth: 5), 4_865_609)
        print("PERFT5_SECONDS \(Date().timeIntervalSince(t))")
    }
}
