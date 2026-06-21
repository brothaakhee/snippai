import Foundation

/// Resolves a Claude Code transcript file on disk. The exact, per-pane-correct path
/// arrives via a hook (`transcript_path`); this locator is the **cold-start fallback**
/// for when no hook frame has been seen yet — it maps a working directory to its
/// project transcript directory and picks the most-recently-active session file.
///
/// Path scheme (verified): `~/.claude/projects/<cwd with '/'→'-'>/<sessionId>.jsonl`.
public enum TranscriptLocator {
    /// The transcript project directory for a working directory, e.g.
    /// `/Users/x/pers/snippai` → `~/.claude/projects/-Users-x-pers-snippai`.
    public static func projectDirectory(forCWD cwd: String,
                                        home: String = NSHomeDirectory()) -> URL {
        let slug = slug(forCWD: cwd)
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/projects/\(slug)", isDirectory: true)
    }

    /// Claude slugifies a cwd by replacing every character outside `[A-Za-z0-9]` with
    /// `-` (verified against the real `~/.claude/projects` tree: `/private/tmp/live_pr`
    /// → `-private-tmp-live-pr`, i.e. `_` and `.` and `/` all become `-`).
    public static func slug(forCWD cwd: String) -> String {
        var s = ""
        for ch in cwd {
            s.append((ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-")
        }
        return s
    }

    /// The newest `.jsonl` transcript under a cwd's project directory, by modification
    /// time — the best guess for "the session active in this directory" before a hook
    /// pins the exact one. Returns nil if the directory has no transcripts yet.
    public static func newestTranscript(forCWD cwd: String,
                                        home: String = NSHomeDirectory(),
                                        excluding: Set<String> = [],
                                        fileManager: FileManager = .default) -> URL? {
        let dir = projectDirectory(forCWD: cwd, home: home)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }

        return entries
            .filter { $0.pathExtension == "jsonl" && !excluding.contains($0.path) }
            .map { (url: $0, mtime: modificationDate($0, fileManager: fileManager)) }
            .max { $0.mtime < $1.mtime }?
            .url
    }

    private static func modificationDate(_ url: URL, fileManager: FileManager) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }
}
