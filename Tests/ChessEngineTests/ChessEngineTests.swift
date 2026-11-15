import XCTest
import ChessCore
@testable import ChessEngine

final class ChessEngineTests: XCTestCase {
    func testDifficultyLevels() {
        XCTAssertEqual(Difficulty.allCases.count, 3)
    }
}
