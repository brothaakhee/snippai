import Foundation

/// Answers "is an agent CLI actually alive on this pane's tty?" — the ground truth
/// behind the dead-session send guard.
///
/// The terminal's reported job name reflects the pane's *foreground* process, and an
/// agent that's working constantly foregrounds children (compilers, LSP servers, test
/// runners) — so "job isn't an agent" must not be read as "no agent here". Listing the
/// processes on the session's controlling tty answers it definitively, and filtering
/// by tty is essential: agent binaries also run detached (daemons, SDK sessions,
/// desktop-app helpers) with no controlling terminal.
public enum AgentProbe {
    /// Whether any process on `tty` (e.g. "/dev/ttys005" or "ttys005") is an agent CLI.
    /// Synchronous — runs one `ps`; call off the main actor.
    public static func agentAlive(onTTY tty: String) -> Bool {
        let name = (tty as NSString).lastPathComponent
        guard !name.isEmpty, name != "??" else { return false }
        return processCommands(onTTY: name).contains(where: commandLooksLikeAgent)
    }

    /// Whether a full command line is an agent CLI invocation. Matches a token's
    /// *basename* exactly ("node /usr/local/bin/claude" → yes via "claude"), so an
    /// agent name merely appearing inside an argument ("vim claude-notes.md") doesn't.
    static func commandLooksLikeAgent(_ command: String) -> Bool {
        command.split(whereSeparator: \.isWhitespace).contains { token in
            TerminalSession.agentCLINames.contains((String(token) as NSString).lastPathComponent.lowercased())
        }
    }

    /// The full command line of every process whose controlling terminal is `ttyName`.
    /// `ps -t` does the tty filtering (and inherently excludes detached processes);
    /// a nonexistent tty yields empty output, which reads as "no agent" — safe.
    private static func processCommands(onTTY ttyName: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-t", ttyName, "-o", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        return out.split(separator: "\n").map(String.init)
    }
}
