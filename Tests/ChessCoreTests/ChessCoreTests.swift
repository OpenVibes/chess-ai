import XCTest
@testable import ChessCore

final class ChessCoreTests: XCTestCase {
    func testSquareAlgebraic() {
        XCTAssertEqual(Square("e4")?.algebraic, "e4")
    }
}
