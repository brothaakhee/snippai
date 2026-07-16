import Foundation

/// Runs an ephemeral, CONSTRAINED `claude -p` one-shot and streams its text.
///
/// The constraint profile is the feature: the de-risking spike showed an
/// unconstrained one-shot happily runs web searches (50 s, $0.32); pinned to
/// haiku with tools forbidden it answers in ~7 s for ~$0.02 (or at no marginal
/// cost on a subscription). Uses the user's existing Claude Code auth — SnippAI
/// never talks to any API itself.
public struct ClaudeOneShot: Sendable {
    public enum StreamEvent: Equatable, Sendable {
        case text(String)
        case finished
        case ignored
    }

    /// Where the `claude` binary lives, or nil when Claude Code isn't installed.
    public static func binaryPath() -> String? {
        let candidates = ["/usr/local/bin/claude", "/opt/homebrew/bin/claude",
                          ("~/.local/bin/claude" as NSString).expandingTildeInPath]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The full argument list for a constrained explain one-shot.
    static func arguments(prompt: String) -> [String] {
        [
            "-p", prompt,
            "--model", "haiku",             // fast + cheap; an explainer needs no more
            "--disallowedTools", "*",       // knowledge-only: no web, no files, no shells
            "--output-format", "stream-json",
            "--verbose",                    // stream-json requires it in print mode
        ]
    }

    /// Parses one stream-json line into an event. Unknown/undecodable lines are
    /// ignored (the CLI interleaves system events and may print non-JSON noise).
    static func parse(line: String) -> StreamEvent {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return .ignored }
        switch type {
        case "assistant":
            let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            return text.isEmpty ? .ignored : .text(text)
        case "result":
            return .finished
        default:
            return .ignored
        }
    }

    /// Launches the one-shot and delivers events as they stream. Terminating the
    /// returned process (e.g. on Esc) ends the stream. Runs from a fixed scratch
    /// cwd so ask transcripts group under one sweepable project dir instead of
    /// polluting the user's per-project session lists.
    public static func run(prompt: String) throws -> (process: Process, events: AsyncStream<StreamEvent>) {
        guard let bin = binaryPath() else {
            throw NSError(domain: "ClaudeOneShot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Claude Code isn’t installed (looked for the `claude` command).",
            ])
        }
        let scratch = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SnippAI/Ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = arguments(prompt: prompt)
        p.currentDirectoryURL = scratch
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        let events = AsyncStream<StreamEvent> { continuation in
            // Pipe reads have NO line framing: a single JSON line (the whole answer
            // is typically one ~2KB+ line) can arrive split across reads, and a
            // multibyte UTF-8 character can straddle a boundary. Buffer bytes and
            // emit only complete lines, or the answer is silently lost.
            nonisolated(unsafe) var buffer = ByteLineBuffer()   // touched only on the handler's serial queue
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {                      // EOF
                    if let residual = buffer.flush() {
                        let event = parse(line: residual)
                        if event != .ignored { continuation.yield(event) }
                    }
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                for line in buffer.append(data) {
                    let event = parse(line: line)
                    if event != .ignored { continuation.yield(event) }
                }
            }
            continuation.onTermination = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                if p.isRunning { p.terminate() }
            }
        }
        try p.run()
        return (p, events)
    }
}

/// Accumulates raw pipe bytes and yields complete newline-terminated lines,
/// holding partial lines (and split UTF-8 sequences) until they complete.
struct ByteLineBuffer {
    private var data = Data()

    /// Appends a chunk; returns every COMPLETE line it closed off.
    mutating func append(_ chunk: Data) -> [String] {
        data.append(chunk)
        var lines: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data.subdata(in: data.startIndex..<nl)
            data.removeSubrange(data.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty {
                lines.append(s)
            }
        }
        return lines
    }

    /// Drains whatever remains (a final line without a trailing newline).
    mutating func flush() -> String? {
        defer { data.removeAll() }
        guard !data.isEmpty, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
}
