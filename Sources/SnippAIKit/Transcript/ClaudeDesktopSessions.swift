import Foundation

/// One Claude Code session hosted by the **desktop app**, as recorded in its
/// `claude-code-sessions` registry. The desktop app's foreground session runs on the
/// host and writes the same `~/.claude/projects/.../<cliSessionId>.jsonl` transcript a
/// terminal CLI session does — so once discovered here it mirrors through the very
/// same engine. (The VM/Cowork `local-agent-mode-sessions` tree is a different, dormant
/// class and is deliberately NOT read here.)
public struct DesktopSession: Equatable, Sendable {
    public let cliSessionID: String
    public let originCwd: String
    public let title: String
    public let lastFocusedAt: Double   // epoch ms; higher == more recently focused
    public let model: String
    public let transcriptPath: String

    public init(cliSessionID: String, originCwd: String, title: String,
                lastFocusedAt: Double, model: String, transcriptPath: String) {
        self.cliSessionID = cliSessionID
        self.originCwd = originCwd
        self.title = title
        self.lastFocusedAt = lastFocusedAt
        self.model = model
        self.transcriptPath = transcriptPath
    }
}

/// Reads the Claude desktop app's `claude-code-sessions` registry to discover its
/// foreground Claude Code session(s). Pure + injectable for tests.
public enum ClaudeDesktopSessions {
    /// Default registry location under the desktop app's Application Support.
    public static func defaultRegistryRoot(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions",
                                    isDirectory: true)
    }

    /// All non-archived desktop sessions whose transcript exists on disk, most-recently
    /// focused first. Returns `[]` if the desktop app isn't installed / has no sessions.
    public static func read(registryRoot: URL? = nil,
                            home: String = NSHomeDirectory(),
                            fileManager: FileManager = .default) -> [DesktopSession] {
        let root = registryRoot ?? defaultRegistryRoot(home: home)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }

        var sessions: [DesktopSession] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "json",
                  url.lastPathComponent.hasPrefix("local_"),
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Skip archived sessions — they aren't the live foreground conversation.
            if (obj["isArchived"] as? Bool) == true { continue }

            guard let cliSessionID = obj["cliSessionId"] as? String, !cliSessionID.isEmpty,
                  let originCwd = (obj["originCwd"] as? String) ?? (obj["cwd"] as? String),
                  !originCwd.isEmpty else { continue }

            let transcript = TranscriptLocator
                .projectDirectory(forCWD: originCwd, home: home)
                .appendingPathComponent("\(cliSessionID).jsonl")
            // Only surface a session we can actually mirror.
            guard fileManager.fileExists(atPath: transcript.path) else { continue }

            sessions.append(DesktopSession(
                cliSessionID: cliSessionID,
                originCwd: originCwd,
                title: (obj["title"] as? String) ?? "",
                lastFocusedAt: numeric(obj["lastFocusedAt"]),
                model: (obj["model"] as? String) ?? "",
                transcriptPath: transcript.path))
        }
        return sessions.sorted { $0.lastFocusedAt > $1.lastFocusedAt }
    }

    /// `lastFocusedAt` is written as a JSON number; tolerate string form too.
    private static func numeric(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String, let d = Double(s) { return d }
        return 0
    }
}
