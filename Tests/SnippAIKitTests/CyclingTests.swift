import XCTest
@testable import SnippAIKit

final class CyclingTests: XCTestCase {
    func testForwardWraps() {
        XCTAssertEqual(cycledIndex(from: 0, by: 1, count: 3), 1)
        XCTAssertEqual(cycledIndex(from: 1, by: 1, count: 3), 2)
        XCTAssertEqual(cycledIndex(from: 2, by: 1, count: 3), 0)   // wrap to start
    }

    func testBackwardWraps() {
        XCTAssertEqual(cycledIndex(from: 2, by: -1, count: 3), 1)
        XCTAssertEqual(cycledIndex(from: 1, by: -1, count: 3), 0)
        XCTAssertEqual(cycledIndex(from: 0, by: -1, count: 3), 2)   // wrap to end (negative-safe)
    }

    func testLargeDeltasWrapModulo() {
        XCTAssertEqual(cycledIndex(from: 0, by: 7, count: 3), 1)
        XCTAssertEqual(cycledIndex(from: 0, by: -7, count: 3), 2)
    }

    func testSingleAndEmpty() {
        XCTAssertEqual(cycledIndex(from: 0, by: 1, count: 1), 0)
        XCTAssertEqual(cycledIndex(from: 0, by: -1, count: 1), 0)
        XCTAssertEqual(cycledIndex(from: 0, by: 1, count: 0), 0)   // guarded, no crash
    }
}
