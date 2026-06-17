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

final class TargetCycleDeltaTests: XCTestCase {
    // keyCodes: left=123, right=124, down=125, up=126.
    private func delta(_ kc: Int, cmd: Bool = true, opt: Bool = false, ctrl: Bool = false, shift: Bool = false) -> Int? {
        targetCycleDelta(keyCode: kc, command: cmd, option: opt, control: ctrl, shift: shift)
    }

    func testCommandArrowsCycle() {
        XCTAssertEqual(delta(124), 1)    // ⌘→ next
        XCTAssertEqual(delta(125), 1)    // ⌘↓ next
        XCTAssertEqual(delta(123), -1)   // ⌘← previous
        XCTAssertEqual(delta(126), -1)   // ⌘↑ previous
    }

    func testCommandRequired() {
        XCTAssertNil(delta(124, cmd: false))   // plain → moves caret, not cycle
    }

    func testOtherModifiersSuppressCycling() {
        // ⌥/⌃/⇧ + ⌘+arrow must fall through to normal text navigation.
        XCTAssertNil(delta(124, opt: true))
        XCTAssertNil(delta(124, ctrl: true))
        XCTAssertNil(delta(124, shift: true))
    }

    func testNonArrowKeysIgnored() {
        XCTAssertNil(delta(0))     // 'a'
        XCTAssertNil(delta(36))    // return
    }
}
