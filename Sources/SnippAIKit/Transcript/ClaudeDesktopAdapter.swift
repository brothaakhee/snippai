import Foundation

public enum ClaudeDesktopAdapterError: Error, LocalizedError {
    case noSessions
    case injectUnavailable

    public var errorDescription: String? {
        switch self {
        case .noSessions:
            return "The Claude desktop app has no active session to mirror."
        case .injectUnavailable:
            return "SnippAI couldn’t send into the Claude desktop app. Make sure it’s running and SnippAI has Accessibility access (Settings → Privacy & Security → Accessibility)."
        }
    }
}

/// Drives the desktop app's chat input via UI automation (focus the conversation,
/// paste the composed text, submit). Lives in the app layer (AppKit/CGEvent);
/// SnippAIKit can't link those, so it's injected here as a closure.
public typealias DesktopInject = @Sendable (_ text: String, _ sessionID: String) async throws -> Void

/// `TargetAdapter` for the **Claude desktop app**. Its foreground Claude Code session
/// runs on the host and writes a normal transcript JSONL, so SnippAI discovers it from
/// the `claude-code-sessions` registry and mirrors it through the shared transcript
/// engine. Injection into the desktop app has no smooth, supported path (its stdin is an
/// Electron-owned socketpair — see docs/claude-code-feasibility-matrix.md), so this is a
/// **mirror-only** adapter: `send` reports that clearly and `focus` deep-links instead.
public actor ClaudeDesktopAdapter: TargetAdapter {
    public nonisolated let displayName = "Claude Desktop"
    private let inject: DesktopInject?

    /// `inject` is the app-layer UI-automation injector. When nil (e.g. SnippAIKit
    /// tests, or no AppKit host), the adapter degrades to mirror-only and `send`
    /// reports that injection is unavailable.
    public init(inject: DesktopInject? = nil) {
        self.inject = inject
    }

    public func connect() async throws {
        // Nothing to connect to — discovery just reads the on-disk registry. Treat
        // "no sessions" as empty rather than an error so the router stays happy when
        // the desktop app isn't in use.
    }

    public func disconnect() async {}

    public func discover() async throws -> [TerminalSession] {
        ClaudeDesktopSessions.read().map { session in
            TerminalSession(
                id: session.cliSessionID,
                cwd: session.originCwd,
                title: session.title,
                jobName: "claude",
                lastLine: session.title,
                source: displayName,
                transcriptPath: session.transcriptPath,
                supportsInject: inject != nil,   // injectable when the app provided an injector
                hasScreenStream: false)           // display is the transcript mirror, not a terminal screen
        }
    }

    public func send(text: String, toSession sessionID: String) async throws {
        guard let inject else { throw ClaudeDesktopAdapterError.injectUnavailable }
        try await inject(text, sessionID)
    }

    public func snapshot(ofSession sessionID: String) async throws -> TerminalScreen {
        .empty   // the conversation mirror (transcript) is this target's display
    }

    public func screenStream(forSession sessionID: String) async throws -> AsyncStream<TerminalScreen> {
        // No terminal screen to stream; the transcript-driven mirror handles display.
        AsyncStream { $0.finish() }
    }

    public func focus(sessionID: String) async throws {
        // Bring the conversation forward in the desktop app via its URL scheme
        // (navigate-only; carries no payload). Best-effort — spawn `open` so the
        // engine library doesn't need to link AppKit.
        let id = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["claude://chat/\(id)"]
        try? process.run()
    }
}
