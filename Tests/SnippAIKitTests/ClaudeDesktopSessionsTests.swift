import XCTest
import Foundation
@testable import SnippAIKit

final class ClaudeDesktopSessionsTests: XCTestCase {

    /// Builds an isolated fake HOME with a desktop registry + matching transcript(s).
    private func makeHome() throws -> (home: URL, registry: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippai-desktop-\(UUID().uuidString)", isDirectory: true)
        let registry = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        return (home, registry)
    }

    private func writeRegistry(_ url: URL, _ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: url.appendingPathComponent("local_\(obj["sessionId"] ?? UUID().uuidString).json"))
    }

    private func writeTranscript(home: URL, cwd: String, sessionID: String) throws {
        let dir = TranscriptLocator.projectDirectory(forCWD: cwd, home: home.path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = #"{"type":"user","uuid":"x","message":{"role":"user","content":"hi"}}"# + "\n"
        try line.data(using: .utf8)!.write(to: dir.appendingPathComponent("\(sessionID).jsonl"))
    }

    func testDiscoversSessionWithResolvedTranscriptPath() throws {
        let (home, registry) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/Users/x/pers/proj", sid = "11111111-1111-1111-1111-111111111111"
        try writeTranscript(home: home, cwd: cwd, sessionID: sid)
        try writeRegistry(registry, ["sessionId": "s1", "cliSessionId": sid, "originCwd": cwd,
                                     "title": "My Session", "lastFocusedAt": 1782000000000,
                                     "isArchived": false, "model": "claude-opus-4-8"])

        let sessions = ClaudeDesktopSessions.read(registryRoot: registry.deletingLastPathComponent().deletingLastPathComponent(), home: home.path)
        XCTAssertEqual(sessions.count, 1)
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.cliSessionID, sid)
        XCTAssertEqual(s.originCwd, cwd)
        XCTAssertEqual(s.title, "My Session")
        XCTAssertTrue(s.transcriptPath.hasSuffix("\(sid).jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.transcriptPath))
    }

    func testSkipsArchivedAndMissingTranscript() throws {
        let (home, registry) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/Users/x/proj"
        // Archived (has transcript) — skipped.
        let archivedID = "22222222-2222-2222-2222-222222222222"
        try writeTranscript(home: home, cwd: cwd, sessionID: archivedID)
        try writeRegistry(registry, ["sessionId": "s2", "cliSessionId": archivedID, "originCwd": cwd,
                                     "isArchived": true, "lastFocusedAt": 1782000000001])
        // Live but transcript missing — skipped.
        try writeRegistry(registry, ["sessionId": "s3", "cliSessionId": "33333333-3333-3333-3333-333333333333",
                                     "originCwd": cwd, "isArchived": false, "lastFocusedAt": 1782000000002])

        let sessions = ClaudeDesktopSessions.read(registryRoot: registry.deletingLastPathComponent().deletingLastPathComponent(), home: home.path)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testSortsByLastFocusedDescending() throws {
        let (home, registry) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/Users/x/proj"
        for (sid, focus) in [("aaaaaaaa-0000-0000-0000-000000000001", 100.0),
                             ("bbbbbbbb-0000-0000-0000-000000000002", 300.0),
                             ("cccccccc-0000-0000-0000-000000000003", 200.0)] {
            try writeTranscript(home: home, cwd: cwd, sessionID: sid)
            try writeRegistry(registry, ["sessionId": sid, "cliSessionId": sid, "originCwd": cwd,
                                         "isArchived": false, "lastFocusedAt": focus])
        }
        let sessions = ClaudeDesktopSessions.read(registryRoot: registry.deletingLastPathComponent().deletingLastPathComponent(), home: home.path)
        XCTAssertEqual(sessions.map(\.lastFocusedAt), [300, 200, 100])
    }

    func testSlugDashesAllNonAlphanumerics() {
        // Verified against the real ~/.claude/projects tree: '/', '.', '_', space all → '-'.
        XCTAssertEqual(TranscriptLocator.slug(forCWD: "/private/tmp/live_pr"), "-private-tmp-live-pr")
        XCTAssertEqual(TranscriptLocator.slug(forCWD: "/Users/h/pers/snippai"), "-Users-h-pers-snippai")
        XCTAssertEqual(TranscriptLocator.slug(forCWD: "/a/b.c/d e"), "-a-b-c-d-e")
        XCTAssertEqual(TranscriptLocator.slug(forCWD: "/x/café"), "-x-caf-")  // non-ASCII letter → '-'
    }

    func testDiscoversSessionWhoseCwdHasUnderscore() throws {
        // Regression for the slug bug: a cwd with '_' must still resolve its transcript.
        let (home, registry) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/Users/x/live_pr", sid = "44444444-4444-4444-4444-444444444444"
        try writeTranscript(home: home, cwd: cwd, sessionID: sid)
        try writeRegistry(registry, ["sessionId": "s4", "cliSessionId": sid, "originCwd": cwd,
                                     "isArchived": false, "lastFocusedAt": 1782000000003])
        let sessions = ClaudeDesktopSessions.read(registryRoot: registry.deletingLastPathComponent().deletingLastPathComponent(), home: home.path)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions.first?.transcriptPath.contains("-Users-x-live-pr") == true)
    }

    func testMissingRegistryReturnsEmpty() {
        let sessions = ClaudeDesktopSessions.read(
            registryRoot: URL(fileURLWithPath: "/nonexistent/snippai-test-registry"),
            home: "/nonexistent")
        XCTAssertTrue(sessions.isEmpty)
    }
}
