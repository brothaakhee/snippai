import Foundation

/// Finds the Claude conversation you're currently in, uniformly across every
/// surface. Terminal Claude Code, the desktop app, and IDE extensions all write
/// their transcript to `~/.claude/projects/<project>/<sessionId>.jsonl`, so the
/// most-recently-modified transcript IS the live session — no per-app detection,
/// no dependency on the status-hook integration.
public enum ActiveTranscript {
    /// The default projects root (`~/.claude/projects`).
    public static var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// The `.jsonl` transcripts under `root`, most-recently-modified first.
    public static func recent(in root: URL = projectsRoot, limit: Int = 40) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var dated: [(url: URL, date: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let date = values?.contentModificationDate else { continue }
            dated.append((url, date))
        }
        return dated.sorted { $0.date > $1.date }.prefix(limit).map(\.url)
    }

    /// The conversation an on-screen `fragment` came from: among the recent
    /// transcripts, the one whose latest assistant message actually CONTAINS the
    /// selected words — not merely the newest file. This is what makes Ask attach
    /// to the response you're pointing at even when several Claude sessions are
    /// running at once (the newest file is often an unrelated session). Returns the
    /// matched transcript and its last assistant message (the context to attach), or
    /// nil when no session confidently contains the text (e.g. a browser selection).
    public static func match(fragment: String, in root: URL = projectsRoot,
                             limit: Int = 40, minScore: Double = 0.65,
                             maxLength: Int = 16_000) -> (url: URL, response: String)? {
        var best: (url: URL, response: String, score: Double)?
        for url in recent(in: root, limit: limit) {
            guard let response = AskContext.recentAssistantText(transcriptPath: url.path, maxLength: maxLength)
            else { continue }
            let score = SentenceMatcher.score(forFragment: fragment, in: response)
            if best == nil || score > best!.score { best = (url, response, score) }
            // Selection/clipboard text is exact, so an exact containment (1.0) is the
            // best possible match — and files are scanned newest-first — so stop
            // instead of reading the rest.
            if score >= 1.0 { break }
        }
        guard let best, best.score >= minScore else { return nil }
        return (best.url, best.response)
    }
}
