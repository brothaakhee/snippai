import XCTest

@testable import SnippAIKit

final class ActiveTranscriptTests: XCTestCase {

    // MARK: - Most-recently-written resolver

    func testResolvesMostRecentlyModifiedTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("at-\(UUID().uuidString)", isDirectory: true)
        let projA = root.appendingPathComponent("projectA", isDirectory: true)
        let projB = root.appendingPathComponent("projectB", isDirectory: true)
        try FileManager.default.createDirectory(at: projA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let older = projA.appendingPathComponent("older.jsonl")
        let newer = projB.appendingPathComponent("newer.jsonl")
        try "{}".data(using: .utf8)!.write(to: older)
        try "{}".data(using: .utf8)!.write(to: newer)
        // Make `older` genuinely older.
        let past = Date(timeIntervalSinceNow: -600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: older.path)

        let resolved = ActiveTranscript.recent(in: root).first
        XCTAssertEqual(resolved?.lastPathComponent, "newer.jsonl")
    }

    func testResolverIgnoresNonJSONLAndEmptyDirs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("at-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "log".data(using: .utf8)!.write(to: root.appendingPathComponent("notes.txt"))
        XCTAssertNil(ActiveTranscript.recent(in: root).first)
    }

    func testResolverNilWhenRootMissing() {
        XCTAssertNil(ActiveTranscript.recent(in: URL(fileURLWithPath: "/no/such/dir")).first)
    }

    // MARK: - Content-based match (the on-screen selection picks the transcript)

    /// Writes a transcript whose last assistant message is `text`, with `mtime`.
    private func writeTranscript(_ text: String, at url: URL, ageSeconds: TimeInterval) throws {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
        try line.data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -ageSeconds)], ofItemAtPath: url.path)
    }

    func testMatchPicksTranscriptContainingTheFragmentNotTheNewest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("at-\(UUID().uuidString)", isDirectory: true)
        let projA = root.appendingPathComponent("projectA", isDirectory: true)
        let projB = root.appendingPathComponent("projectB", isDirectory: true)
        try FileManager.default.createDirectory(at: projA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The NEWEST transcript is an unrelated session (a different concurrent
        // Claude). The older one holds the response actually on the user's screen.
        try writeTranscript("Kubernetes ingress controllers route external traffic to services.",
                            at: projA.appendingPathComponent("unrelated.jsonl"), ageSeconds: 1)
        try writeTranscript("That means no real customer can buy right now - every checkout is a test-card sandbox.",
                            at: projB.appendingPathComponent("onscreen.jsonl"), ageSeconds: 300)

        let match = ActiveTranscript.match(fragment: "test-card sandbox", in: root)
        XCTAssertEqual(match?.url.lastPathComponent, "onscreen.jsonl",
                       "must attach to the session whose message contains the selection, not the newest file")
        XCTAssertTrue(match?.response.contains("test-card sandbox") == true)
    }

    func testMatchToleratesOCRNoiseInTheFragment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("at-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript("The Caesar's wife rule means insiders must be above suspicion.",
                            at: root.appendingPathComponent("s.jsonl"), ageSeconds: 1)
        // l→1, rn→m, case — the resolver must still find it.
        let match = ActiveTranscript.match(fragment: "caesars wife ru1e means insiders rnust", in: root)
        XCTAssertNotNil(match)
    }

    func testMatchNilWhenNoTranscriptContainsTheSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("at-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript("Backpressure is handled by the AsyncStream buffering policy.",
                            at: root.appendingPathComponent("s.jsonl"), ageSeconds: 1)
        // A browser selection unrelated to any Claude session → no context to attach.
        XCTAssertNil(ActiveTranscript.match(fragment: "quarterly revenue grew by fourteen percent", in: root))
    }

    // MARK: - Sentence-level anchoring (fuzzy match of a noisy OCR fragment)

    private let response = """
    I chose stateless threads because actors are reentrant. \
    Each follow-up re-sends the full response plus the quote to a fresh claude -p. \
    The Caesar's wife rule means insiders must be above suspicion. \
    Backpressure is handled by the AsyncStream buffering policy.
    """

    func testFuzzyMatchExactFragment() {
        let s = SentenceMatcher.bestSentence(
            forFragment: "the Caesar's wife rule means insiders must be above suspicion",
            in: response)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("Caesar's wife rule"))
        XCTAssertFalse(s!.contains("Backpressure"), "must not bleed into the next sentence")
    }

    func testFuzzyMatchToleratesOCRNoise() {
        // Realistic OCR errors: l→1, rn→m, dropped punctuation, case.
        let noisy = "the caesars wife ru1e means insiders rnust be above suspicion"
        let s = SentenceMatcher.bestSentence(forFragment: noisy, in: response)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("Caesar's wife rule"), "got: \(s ?? "nil")")
    }

    func testFuzzyMatchPicksRightSentenceAmongSimilar() {
        // "full response" appears near "fresh claude -p" — a naive contains() could
        // grab the wrong sentence; the matcher should score the best overlap.
        let s = SentenceMatcher.bestSentence(
            forFragment: "re-sends the full response plus the quote",
            in: response)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("fresh claude -p"))
        XCTAssertFalse(s!.contains("stateless threads because"))
    }

    func testFuzzyMatchNilOnNoReasonableOverlap() {
        let s = SentenceMatcher.bestSentence(
            forFragment: "kubernetes ingress controller helm chart",
            in: response)
        XCTAssertNil(s, "unrelated fragment must not force a spurious anchor")
    }

    func testFuzzyMatchAnchorsAPartialPointerIntoASentence() {
        // The user pointed at just a slice of the sentence — containment recovers
        // the whole sentence a symmetric measure would miss.
        let s = SentenceMatcher.bestSentence(forFragment: "insiders must be above", in: response)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("Caesar's wife rule"))
    }

    func testTinyPointerDoesNotAnchor() {
        XCTAssertNil(SentenceMatcher.bestSentence(forFragment: "the", in: response),
                     "a trivial pointer must not match everything")
    }

    func testAnchorFallsBackToRawFragmentWhenNoMatch() {
        // No confident sentence → hand back the raw fragment (full response is still
        // the context, so Claude can still ground the answer).
        let a = SentenceMatcher.anchor(forFragment: "kubernetes ingress controller helm chart",
                                       in: response)
        XCTAssertEqual(a, "kubernetes ingress controller helm chart")
    }
}
