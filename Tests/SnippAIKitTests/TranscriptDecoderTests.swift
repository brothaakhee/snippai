import XCTest
import Foundation
@testable import SnippAIKit

final class TranscriptDecoderTests: XCTestCase {

    private func decode(_ json: String) -> TranscriptEvent? {
        TranscriptDecoder.decode(line: Data(json.utf8))
    }

    // MARK: - Happy paths

    func testUserStringContent() throws {
        let json = #"{"type":"user","uuid":"u1","timestamp":"2026-06-21T05:00:00.000Z","sessionId":"s1","cwd":"/p","message":{"role":"user","content":"fix this bug"}}"#
        let e = try XCTUnwrap(decode(json))
        XCTAssertEqual(e.role, .user)
        XCTAssertEqual(e.id, "u1")
        XCTAssertEqual(e.blocks, [.text("fix this bug")])
        XCTAssertEqual(e.cwd, "/p")
        XCTAssertFalse(e.isSidechain)
    }

    func testAssistantBlocksThinkingTextTool() throws {
        let json = #"""
        {"type":"assistant","uuid":"a1","timestamp":"2026-06-21T05:01:00.000Z","message":{"role":"assistant","model":"claude-opus-4-8","content":[{"type":"thinking","thinking":"let me look"},{"type":"text","text":"On it."},{"type":"tool_use","name":"Read","input":{"file_path":"/x","limit":10}}]}}
        """#
        let e = try XCTUnwrap(decode(json))
        XCTAssertEqual(e.role, .assistant)
        XCTAssertEqual(e.model, "claude-opus-4-8")
        XCTAssertEqual(e.blocks.count, 3)
        XCTAssertEqual(e.blocks[0], .thinking("let me look"))
        XCTAssertEqual(e.blocks[1], .text("On it."))
        // input is serialised with sorted keys for stability
        XCTAssertEqual(e.blocks[2], .toolUse(name: "Read", input: #"{"file_path":"/x","limit":10}"#))
    }

    func testToolResultEnvelopeAttributedAsToolOutput() throws {
        let json = #"{"type":"user","uuid":"u2","timestamp":"t","message":{"role":"user","content":[{"type":"tool_result","content":"done","is_error":false}]}}"#
        let e = try XCTUnwrap(decode(json))
        XCTAssertEqual(e.blocks, [.toolResult(text: "done", isError: false)])
        XCTAssertTrue(e.isToolResultEnvelope)
    }

    func testToolResultArrayContentAndError() throws {
        let json = #"{"type":"user","uuid":"u3","timestamp":"t","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"content":[{"type":"text","text":"boom"},{"type":"image"}]}]}}"#
        let e = try XCTUnwrap(decode(json))
        XCTAssertEqual(e.blocks, [.toolResult(text: "boom\n[image]", isError: true)])
    }

    func testImageBlock() throws {
        let json = #"{"type":"user","uuid":"u4","timestamp":"t","message":{"role":"user","content":[{"type":"image"},{"type":"text","text":"look"}]}}"#
        let e = try XCTUnwrap(decode(json))
        XCTAssertEqual(e.blocks, [.image, .text("look")])
    }

    func testSidechainFlag() throws {
        let json = #"{"type":"assistant","uuid":"a2","isSidechain":true,"timestamp":"t","message":{"role":"assistant","content":[{"type":"text","text":"sub"}]}}"#
        let e = try XCTUnwrap(decode(json))
        XCTAssertTrue(e.isSidechain)
    }

    func testMixedContentListKeepsValidBlocks() throws {
        // A stray non-dict element must not drop the whole turn (drift tolerance).
        let json = #"{"type":"assistant","uuid":"a9","timestamp":"t","message":{"role":"assistant","content":[{"type":"text","text":"hi"},"trailing-string",{"type":"tool_use","name":"Bash","input":{"cmd":"ls"}}]}}"#
        let e = try XCTUnwrap(decode(json))
        XCTAssertEqual(e.blocks, [.text("hi"), .text("trailing-string"), .toolUse(name: "Bash", input: #"{"cmd":"ls"}"#)])
    }

    func testArrayOfStringsUserContent() throws {
        let json = #"{"type":"user","uuid":"u9","timestamp":"t","message":{"role":"user","content":["hello","world"]}}"#
        let e = try XCTUnwrap(decode(json))
        XCTAssertEqual(e.blocks, [.text("hello"), .text("world")])
    }

    func testToolResultArrayOfStrings() throws {
        let json = #"{"type":"user","uuid":"u10","timestamp":"t","message":{"role":"user","content":[{"type":"tool_result","content":["line one","line two"]}]}}"#
        let e = try XCTUnwrap(decode(json))
        XCTAssertEqual(e.blocks, [.toolResult(text: "line one\nline two", isError: false)])
    }

    func testUnknownBlockTypePreserved() throws {
        let json = #"{"type":"assistant","uuid":"a3","timestamp":"t","message":{"role":"assistant","content":[{"type":"redacted_thinking","data":"xx"}]}}"#
        let e = try XCTUnwrap(decode(json))
        XCTAssertEqual(e.blocks, [.unknown("redacted_thinking")])
    }

    // MARK: - Skips & robustness

    func testSkipsNonConversationTypes() {
        for type in ["mode", "permission-mode", "file-history-snapshot", "last-prompt", "pr-link", "queue-operation", "attachment", "system"] {
            let json = #"{"type":"\#(type)","uuid":"x","message":{"content":"whatever"}}"#
            XCTAssertNil(decode(json), "should skip \(type)")
        }
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(decode("{not json"))
        XCTAssertNil(TranscriptDecoder.decode(line: Data()))
    }

    func testMissingMessageReturnsNil() {
        XCTAssertNil(decode(#"{"type":"user","uuid":"u"}"#))
    }

    func testEmptyContentReturnsNil() {
        XCTAssertNil(decode(#"{"type":"user","uuid":"u","message":{"role":"user","content":"   "}}"#))
        XCTAssertNil(decode(#"{"type":"assistant","uuid":"a","message":{"role":"assistant","content":[]}}"#))
    }

    func testMissingUuidSynthesizesStableId() throws {
        let json = #"{"type":"user","timestamp":"2026-06-21T05:00:00Z","message":{"role":"user","content":"hi"}}"#
        let e = try XCTUnwrap(decode(json))
        XCTAssertFalse(e.id.isEmpty)
    }
}
