import XCTest
import Foundation
@testable import SnippAIKit

final class HookFrameTests: XCTestCase {
    func testDecodeWellFormedFrame() throws {
        let json = #"{"v":1,"event":"Stop","iterm":"w0t5p0:E5FD49F8-7BB4-44CA-A964-E76644118E1B","term_session":"","tmux_pane":"","tty":"/dev/ttys005","term_program":"iTerm.app","payload_b64":""}"#
        let frame = try XCTUnwrap(HookFrame.decode(line: Data(json.utf8)))
        XCTAssertEqual(frame.event, "Stop")
        XCTAssertEqual(frame.tty, "/dev/ttys005")
        XCTAssertEqual(frame.termProgram, "iTerm.app")
    }

    func testGUIDExtractionFromITermSessionID() throws {
        let frame = HookFrame(event: "Stop", iterm: "w0t5p0:E5FD49F8-7BB4-44CA-A964-E76644118E1B")
        XCTAssertEqual(frame.itermSessionGUID, "E5FD49F8-7BB4-44CA-A964-E76644118E1B")
    }

    func testGUIDFallsBackToTermSessionWhenItermEmpty() throws {
        let frame = HookFrame(event: "Notification", iterm: "", termSession: "w0t1p0:ABC-123")
        XCTAssertEqual(frame.itermSessionGUID, "ABC-123")
    }

    func testGUIDNilWhenNoColon() throws {
        let frame = HookFrame(event: "Stop", iterm: "no-colon-here")
        XCTAssertNil(frame.itermSessionGUID)
    }

    func testDecodeEmbeddedClaudePayload() throws {
        let claude = #"{"session_id":"conv-1","cwd":"/Users/x/proj","message":"needs permission","hook_event_name":"Notification"}"#
        let b64 = Data(claude.utf8).base64EncodedString()
        let frame = HookFrame(event: "Notification", payloadB64: b64)
        let payload = try XCTUnwrap(frame.claudePayload)
        XCTAssertEqual(payload.sessionID, "conv-1")
        XCTAssertEqual(payload.cwd, "/Users/x/proj")
        XCTAssertEqual(payload.message, "needs permission")
    }

    func testBadBase64PayloadDegradesToNil() {
        let frame = HookFrame(event: "Stop", payloadB64: "!!!not base64!!!")
        XCTAssertNil(frame.claudePayload)
    }

    func testMalformedFrameLineReturnsNil() {
        XCTAssertNil(HookFrame.decode(line: Data("{ not json".utf8)))
        XCTAssertNil(HookFrame.decode(line: Data()))
    }
}

final class AgentStateTests: XCTestCase {
    func testEventMapping() {
        XCTAssertEqual(AgentState.from(event: "Stop"), .finished)
        XCTAssertEqual(AgentState.from(event: "Notification"), .waitingForInput)
        XCTAssertNil(AgentState.from(event: "PreToolUse"))   // schema drift → ignored
    }

    func testNeedsAttention() {
        XCTAssertTrue(AgentState.finished.needsAttention)
        XCTAssertTrue(AgentState.waitingForInput.needsAttention)
        XCTAssertFalse(AgentState.working.needsAttention)
        XCTAssertFalse(AgentState.unknown.needsAttention)
    }
}

final class HookCorrelatorTests: XCTestCase {
    private let guid = "E5FD49F8-7BB4-44CA-A964-E76644118E1B"

    func testCorrelatesByGUIDWhenKnown() {
        let frame = HookFrame(event: "Stop", iterm: "w0t5p0:\(guid)")
        let id = HookCorrelator.sessionID(for: frame, knownIDs: [guid], ttyToID: [:])
        XCTAssertEqual(id, guid)
    }

    func testDropsGUIDNotInKnownSet() {
        let frame = HookFrame(event: "Stop", iterm: "w0t5p0:\(guid)")
        XCTAssertNil(HookCorrelator.sessionID(for: frame, knownIDs: ["other"], ttyToID: [:]))
    }

    func testFallsBackToTTYWhenGUIDUnknown() {
        let frame = HookFrame(event: "Stop", iterm: "", tty: "/dev/ttys009")
        let id = HookCorrelator.sessionID(for: frame, knownIDs: [], ttyToID: ["/dev/ttys009": "sess-9"])
        XCTAssertEqual(id, "sess-9")
    }

    func testGUIDTakesPrecedenceOverTTY() {
        let frame = HookFrame(event: "Stop", iterm: "w0t5p0:\(guid)", tty: "/dev/ttys009")
        let id = HookCorrelator.sessionID(for: frame, knownIDs: [guid], ttyToID: ["/dev/ttys009": "sess-9"])
        XCTAssertEqual(id, guid)   // not sess-9
    }

    func testDropsWhenNothingMatches() {
        let frame = HookFrame(event: "Stop", iterm: "w0t5p0:\(guid)", tty: "/dev/ttys009")
        XCTAssertNil(HookCorrelator.sessionID(for: frame, knownIDs: [], ttyToID: [:]))
    }

    func testEmptyTTYNeverMatches() {
        let frame = HookFrame(event: "Stop", iterm: "", tty: "")
        XCTAssertNil(HookCorrelator.sessionID(for: frame, knownIDs: [], ttyToID: ["": "sess-bad"]))
    }
}
