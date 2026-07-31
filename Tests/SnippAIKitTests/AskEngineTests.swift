import AppKit
import XCTest

@testable import SnippAIKit

final class AskEngineTests: XCTestCase {

    // MARK: - One-shot invocation shape

    func testOneShotArgumentsAreConstrained() {
        let args = ClaudeOneShot.arguments(prompt: "explain X")
        XCTAssertEqual(args.first, "-p")
        XCTAssertTrue(args.contains("explain X"))
        // The constrained profile IS the feature: an unconstrained one-shot ran web
        // search in the spike (50s, $0.32). Haiku + no tools, streaming JSON.
        XCTAssertTrue(args.contains("haiku"), "must pin the fast/cheap model")
        XCTAssertTrue(args.contains("--disallowedTools"), "must forbid tools")
        XCTAssertTrue(args.contains("stream-json"), "must stream for progressive UI")
    }

    // MARK: - stream-json parsing (fixture lines match the real CLI output shape)

    func testStreamParsingExtractsTextDeltasAndResult() {
        let lines = [
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Caesar's wife "}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"must be above suspicion."}]}}"#,
            #"{"type":"result","total_cost_usd":0.019,"is_error":false}"#,
            "not json at all",
        ]
        var text = ""
        var finished = false
        for line in lines {
            switch ClaudeOneShot.parse(line: line) {
            case .text(let t): text += t
            case .finished: finished = true
            case .ignored: break
            }
        }
        XCTAssertEqual(text, "Caesar's wife must be above suspicion.")
        XCTAssertTrue(finished)
    }

    func testStreamParsingIgnoresToolAndThinkingBlocks() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebSearch"},{"type":"text","text":"ok"}]}}"#
        guard case .text(let t) = ClaudeOneShot.parse(line: line) else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(t, "ok")
    }

    // MARK: - Context extraction from a transcript JSONL

    func testLastAssistantTextFromTranscript() throws {
        let jsonl = """
        {"uuid":"1","type":"user","message":{"role":"user","content":[{"type":"text","text":"fix the bug"}]}}
        {"uuid":"2","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"First answer."}]}}
        {"uuid":"3","type":"user","message":{"role":"user","content":[{"type":"text","text":"and then?"}]}}
        {"uuid":"4","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Make it policy - it is your Caesar's-wife rule."}]}}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-test-\(UUID().uuidString).jsonl")
        try jsonl.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let context = AskContext.lastAssistantText(transcriptPath: url.path, maxLength: 4000)
        XCTAssertEqual(context, "Make it policy - it is your Caesar's-wife rule.")
    }

    func testContextTruncatesLongMessagesKeepingTheTail() throws {
        let long = String(repeating: "a", count: 3000) + " THE-END-MATTERS"
        let jsonl = #"{"uuid":"1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(long)"}]}}"#
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-test-\(UUID().uuidString).jsonl")
        try jsonl.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let context = AskContext.lastAssistantText(transcriptPath: url.path, maxLength: 500)
        XCTAssertNotNil(context)
        XCTAssertLessThanOrEqual(context!.count, 501)   // "…" prefix allowance
        XCTAssertTrue(context!.hasSuffix("THE-END-MATTERS"),
                      "the tail carries the referenced term — keep it, drop the head")
    }

    func testContextNilForMissingFile() {
        XCTAssertNil(AskContext.lastAssistantText(transcriptPath: "/nonexistent/x.jsonl", maxLength: 100))
    }

    // MARK: - Prompt building

    func testPromptIncludesQuoteContextAndConstraints() {
        let p = AskContext.prompt(question: nil,
                                  highlighted: "Caesar's-wife rule",
                                  context: "Make it policy - it is your Caesar's-wife rule.")
        XCTAssertTrue(p.contains("Caesar's-wife rule"))
        XCTAssertTrue(p.contains("Make it policy"))
        XCTAssertTrue(p.lowercased().contains("do not use any tools"))
        XCTAssertTrue(p.lowercased().contains("brief"))
    }

    func testPromptWithoutContextStillWellFormed() {
        let p = AskContext.prompt(question: nil, highlighted: "dead man's switch", context: nil)
        XCTAssertTrue(p.contains("dead man's switch"))
        XCTAssertFalse(p.contains("conversation below"), "no dangling context framing")
    }


    func testWhitespaceOnlyQuestionFallsBackToCannedExplain() {
        let p = AskContext.prompt(question: "   \n  ", highlighted: "idempotency key", context: nil)
        XCTAssertTrue(p.lowercased().contains("briefly explain what it means"),
                      "blank question must use the canned explanation")
        XCTAssertFalse(p.contains("Their question about it"))
    }

    func testPromptCarriesTheUsersOwnQuestion() {
        let p = AskContext.prompt(question: "what is this company and why does it matter here?",
                                  highlighted: "QuikTrak",
                                  context: "QuikTrak-type shops have national contracts.")
        XCTAssertTrue(p.contains("what is this company and why does it matter here?"))
        XCTAssertTrue(p.contains("QuikTrak"))
        // The user's question REPLACES the canned one — no double-asking.
        XCTAssertFalse(p.lowercased().contains("briefly explain what it means"),
                       "canned question must not appear alongside a real one")
        XCTAssertTrue(p.lowercased().contains("do not use any tools"), "constraints always apply")
    }

    // MARK: - Pasteboard snapshot/restore (on a private named pasteboard — never
    // the user's real clipboard)

    func testPasteboardSnapshotRoundTrip() {
        let pb = NSPasteboard(name: NSPasteboard.Name("snippai-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("precious clipboard contents", forType: .string)

        let snapshot = PasteboardSnapshot.take(from: pb)
        pb.clearContents()
        pb.setString("transient ⌘C result", forType: .string)
        XCTAssertEqual(pb.string(forType: .string), "transient ⌘C result")

        snapshot.restore(to: pb)
        XCTAssertEqual(pb.string(forType: .string), "precious clipboard contents")
    }

    func testPasteboardSnapshotOfEmptyRestoresToEmpty() {
        let pb = NSPasteboard(name: NSPasteboard.Name("snippai-test-\(UUID().uuidString)"))
        pb.clearContents()
        let snapshot = PasteboardSnapshot.take(from: pb)
        pb.setString("junk", forType: .string)
        snapshot.restore(to: pb)
        XCTAssertNil(pb.string(forType: .string))
    }

    // MARK: - Byte line buffering (pipe reads have no line framing)

    func testLineBufferReassemblesSplitLines() {
        var buf = ByteLineBuffer()
        // One JSON line delivered across three arbitrary chunk boundaries.
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}"#
        let data = Data((line + "\n").utf8)
        var lines: [String] = []
        lines += buf.append(data.prefix(10))
        lines += buf.append(data.dropFirst(10).prefix(30))
        lines += buf.append(data.dropFirst(40))
        XCTAssertEqual(lines, [line], "fragments must reassemble into exactly one line")
    }

    func testLineBufferSurvivesUTF8StraddlingAChunkBoundary() {
        var buf = ByteLineBuffer()
        let line = "«Ångström’s» rule"   // multibyte characters
        let data = Data((line + "\n").utf8)
        // Split INSIDE the first multibyte scalar («).
        var lines = buf.append(data.prefix(1))
        lines += buf.append(data.dropFirst(1))
        XCTAssertEqual(lines, [line])
    }

    func testLineBufferFlushReturnsResidualWithoutNewline() {
        var buf = ByteLineBuffer()
        XCTAssertEqual(buf.append(Data("no newline yet".utf8)), [])
        XCTAssertEqual(buf.flush(), "no newline yet")
        XCTAssertNil(buf.flush(), "flush drains")
    }

    // MARK: - OCR (fully local: render a known string, recognize it back)

    func testOCRRecognizesRenderedText() throws {
        let text = "The database connection uses REDIS_URL"
        let size = CGSize(width: 720, height: 60)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 16, y: 16), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .regular),
            .foregroundColor: NSColor.black,
        ])
        img.unlockFocus()
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("render failed")
        }

        let recognized = try TextRecognizer.recognize(in: cg)
        XCTAssertTrue(recognized.contains("REDIS_URL"), "got: \(recognized)")
        XCTAssertTrue(recognized.lowercased().contains("database connection"))
    }
}
