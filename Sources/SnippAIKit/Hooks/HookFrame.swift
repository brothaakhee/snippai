import Foundation

/// One newline-delimited JSON frame the hook script sends over the socket.
///
/// The hook captures terminal identity from its environment (which Claude Code
/// inherits from the hosting pane) and embeds Claude's raw hook JSON as base64 so
/// the shell never has to parse/escape it — SnippAI decodes it here instead.
public struct HookFrame: Codable, Equatable, Sendable {
    public var v: Int
    public var event: String          // "Stop" | "Notification" | …
    public var iterm: String?         // $ITERM_SESSION_ID, e.g. "w0t5p0:<GUID>"
    public var termSession: String?   // $TERM_SESSION_ID (Terminal.app & others)
    public var tmuxPane: String?      // $TMUX_PANE
    public var tty: String?           // best-effort controlling tty (ps-derived)
    public var termProgram: String?   // $TERM_PROGRAM
    public var payloadB64: String?    // base64 of Claude's raw hook JSON on stdin

    enum CodingKeys: String, CodingKey {
        case v, event, iterm
        case termSession = "term_session"
        case tmuxPane = "tmux_pane"
        case tty
        case termProgram = "term_program"
        case payloadB64 = "payload_b64"
    }

    public init(v: Int = 1, event: String, iterm: String? = nil, termSession: String? = nil,
                tmuxPane: String? = nil, tty: String? = nil, termProgram: String? = nil,
                payloadB64: String? = nil) {
        self.v = v
        self.event = event
        self.iterm = iterm
        self.termSession = termSession
        self.tmuxPane = tmuxPane
        self.tty = tty
        self.termProgram = termProgram
        self.payloadB64 = payloadB64
    }

    /// Claude Code's hook payload, if present and decodable. All fields optional —
    /// the schema is undocumented and version-drifts, so a missing/renamed field
    /// degrades gracefully rather than throwing.
    public struct ClaudePayload: Codable, Equatable, Sendable {
        public var sessionID: String?
        public var cwd: String?
        public var message: String?
        public var hookEventName: String?
        public var transcriptPath: String?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case cwd, message
            case hookEventName = "hook_event_name"
            case transcriptPath = "transcript_path"
        }
    }

    /// Decodes the embedded Claude payload (base64 → JSON). Returns nil on any failure.
    public var claudePayload: ClaudePayload? {
        guard let b64 = payloadB64, !b64.isEmpty,
              let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONDecoder().decode(ClaudePayload.self, from: data)
    }

    /// Decodes a single frame line. Returns nil on malformed input (never throws to
    /// the socket read loop — a bad frame must not take down the listener).
    public static func decode(line: Data) -> HookFrame? {
        guard !line.isEmpty else { return nil }
        return try? JSONDecoder().decode(HookFrame.self, from: line)
    }

    /// The iTerm session GUID this frame belongs to, if derivable. `ITERM_SESSION_ID`
    /// and `TERM_SESSION_ID` are formatted `"<window/tab/pane>:<GUID>"`; the GUID
    /// after the last colon is exactly `TerminalSession.id` (verified live).
    public var itermSessionGUID: String? {
        for raw in [iterm, termSession] {
            guard let raw, let colon = raw.lastIndex(of: ":") else { continue }
            let guid = String(raw[raw.index(after: colon)...])
            if !guid.isEmpty { return guid }
        }
        return nil
    }
}
