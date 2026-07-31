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

    /// The most-recently-modified `.jsonl` transcript under `root`, or nil.
    public static func mostRecent(in root: URL = projectsRoot) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (url: URL, date: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let date = values?.contentModificationDate else { continue }
            if best == nil || date > best!.date { best = (url, date) }
        }
        return best?.url
    }
}
