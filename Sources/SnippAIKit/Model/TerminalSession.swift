import Foundation

/// A discoverable terminal session the user can target.
public struct TerminalSession: Identifiable, Equatable, Sendable {
    public let id: String          // adapter-scoped unique id (iTerm session_id)
    public var cwd: String
    public var title: String
    public var jobName: String
    public var windowID: String
    public var tabID: String
    public var windowNumber: Int
    public var tabIndex: Int
    public var paneIndex: Int      // index of this session within its tab's split
    public var lastLine: String    // last on-screen non-empty line, for disambiguation

    public init(id: String, cwd: String = "", title: String = "", jobName: String = "",
                windowID: String = "", tabID: String = "", windowNumber: Int = 0,
                tabIndex: Int = 0, paneIndex: Int = 0, lastLine: String = "") {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.jobName = jobName
        self.windowID = windowID
        self.tabID = tabID
        self.windowNumber = windowNumber
        self.tabIndex = tabIndex
        self.paneIndex = paneIndex
        self.lastLine = lastLine
    }

    /// The folder name of the working directory — the primary human label.
    public var folderName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// True when the running job looks like an interactive AI/agent CLI — these
    /// are the sessions SnippAI most wants to target.
    public var looksLikeAgent: Bool {
        let job = jobName.lowercased()
        return ["claude", "codex", "aider", "cursor", "goose", "ollama"].contains { job.contains($0) }
    }

    /// Disambiguating sublabel given multiple sessions can share a cwd.
    public var disambiguator: String {
        var parts: [String] = []
        if !jobName.isEmpty && jobName != "-" { parts.append(jobName) }
        parts.append("win \(windowNumber)·tab \(tabIndex + 1)")
        if paneIndex > 0 { parts.append("pane \(paneIndex + 1)") }
        return parts.joined(separator: " · ")
    }
}

/// A per-target delivery adapter. iTerm2 is the first implementation; Terminal.app,
/// the Claude desktop app, and a hosted PTY are future adapters behind this interface.
public protocol TargetAdapter: Sendable {
    var displayName: String { get }
    func connect() async throws
    func disconnect() async
    /// Enumerate all live, targetable sessions with rich labels.
    func discover() async throws -> [TerminalSession]
    /// Send a composed message (text, ready to submit) to a session.
    func send(text: String, toSession sessionID: String) async throws
    /// A live stream of screen snapshots for a session (event-driven).
    func screenStream(forSession sessionID: String) async throws -> AsyncStream<TerminalScreen>
    /// A one-shot screen snapshot.
    func snapshot(ofSession sessionID: String) async throws -> TerminalScreen
    /// Bring the underlying session to the foreground (best effort).
    func focus(sessionID: String) async throws
}
