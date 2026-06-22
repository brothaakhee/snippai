import Foundation

public enum TerminalAdapterError: Error, LocalizedError {
    case notRunning
    case automationDenied
    case sessionNotFound
    case scriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "Terminal.app isn’t running."
        case .automationDenied:
            return "SnippAI isn’t allowed to control Terminal.app. Enable it in System Settings → Privacy & Security → Automation."
        case .sessionNotFound: return "That Terminal session is no longer open."
        case .scriptFailed(let m): return "Terminal automation failed: \(m)"
        }
    }
}

/// `TargetAdapter` for the macOS Terminal.app, driven via its AppleScript
/// automation. Terminal exposes no event stream or per-cell styling, so the
/// mirror is plain text refreshed by polling — a deliberate fidelity tradeoff vs
/// the native iTerm2 client.
public actor TerminalAppAdapter: TargetAdapter {
    public nonisolated let displayName = "Terminal"
    private static let scriptQueue = DispatchQueue(label: "com.snippai.terminal.osascript", attributes: .concurrent)
    private static let scriptSem = DispatchSemaphore(value: 6)   // cap concurrent osascript/ps/lsof spawns

    public init() {}

    // MARK: - Lifecycle

    public func connect() async throws {
        // `… is running` does NOT launch Terminal and needs no automation grant;
        // the `count windows` does (and triggers the one-time consent on first use).
        // Done in AppleScript so the engine library needn't link AppKit.
        let result = try await run("""
        if application "Terminal" is running then
          tell application "Terminal" to return ((count of windows) as string)
        else
          return "NOT_RUNNING"
        end if
        """)
        if result == "NOT_RUNNING" { throw TerminalAdapterError.notRunning }
    }

    public func disconnect() async {}

    // MARK: - Discovery

    public func discover() async throws -> [TerminalSession] {
        let raw = try await run(Self.discoverScript)
        var stubs: [TerminalSession] = []
        for line in raw.components(separatedBy: "\u{1E}") where !line.isEmpty {   // record separator
            let f = line.components(separatedBy: "\u{1F}")   // unit separator (no Terminal-term collision)
            guard f.count >= 5, !f[0].isEmpty else { continue }
            stubs.append(TerminalSession(
                id: f[0],                                   // tty path, unique per tab
                title: f.count >= 6 ? f[5] : "",
                jobName: f[4],
                windowNumber: Int(f[1]) ?? 0,
                tabIndex: (Int(f[2]) ?? 1) - 1,
                source: "Terminal"))
        }

        // Enrich each tab (cwd + last visible line) concurrently and off the actor.
        return await withTaskGroup(of: TerminalSession.self) { group in
            for stub in stubs {
                group.addTask {
                    var s = stub
                    s.cwd = await Self.resolveCWD(tty: stub.id)
                    if let contents = try? await Self.runScript(Self.contentsScript(tty: stub.id)) {
                        s.lastLine = TerminalScreen.plain(contents).lastNonEmptyLine ?? ""
                    }
                    return s
                }
            }
            var out: [TerminalSession] = []
            for await s in group { out.append(s) }
            out.sort { ($0.windowNumber, $0.tabIndex) < ($1.windowNumber, $1.tabIndex) }
            return out
        }
    }

    // MARK: - Send / snapshot / stream / focus

    public func send(text: String, toSession sessionID: String) async throws {
        // Flatten newlines: `do script` runs each line as a separate command, which
        // would submit a multi-line message prematurely / fragment it.
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        let script = """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (tty of t) is \(AppleScript.quote(sessionID)) then
                  do script \(AppleScript.quote(oneLine)) in t
                  return "ok"
                end if
              end try
            end repeat
          end repeat
          return "not-found"
        end tell
        """
        let result = try await run(script)
        if result != "ok" { throw TerminalAdapterError.sessionNotFound }
    }

    /// Returned by `contentsScript` when no tab matches the tty (vs an empty tab).
    private static let goneSentinel = "\u{4}"

    public func snapshot(ofSession sessionID: String) async throws -> TerminalScreen {
        let contents = try await Self.runMapped(Self.contentsScript(tty: sessionID))
        if contents == Self.goneSentinel { throw TerminalAdapterError.sessionNotFound }
        return TerminalScreen.plain(contents)
    }

    public func screenStream(forSession sessionID: String) async throws -> AsyncStream<TerminalScreen> {
        AsyncStream { continuation in
            let task = Task {
                var lastRaw: String?
                while !Task.isCancelled {
                    let contents = try? await Self.runMapped(Self.contentsScript(tty: sessionID))
                    if contents == Self.goneSentinel {
                        break   // tab closed → end the stream so the UI can surface it
                    }
                    if let contents, contents != lastRaw {   // dedup on raw text, skip building unchanged screens
                        lastRaw = contents
                        continuation.yield(TerminalScreen.plain(contents))
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)   // Terminal has no event stream → poll
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func focus(sessionID: String) async throws {
        let script = """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (tty of t) is \(AppleScript.quote(sessionID)) then
                  set selected of t to true
                  set index of w to 1
                  activate
                  return "ok"
                end if
              end try
            end repeat
          end repeat
          return "not-found"
        end tell
        """
        _ = try await run(script)
    }

    // MARK: - Scripts

    private static let discoverScript = """
    tell application "Terminal"
      set out to ""
      set w_i to 0
      repeat with w in windows
        set w_i to w_i + 1
        set t_i to 0
        repeat with t in tabs of w
          set t_i to t_i + 1
          set ttyVal to ""
          try
            set ttyVal to tty of t
          end try
          set jobVal to ""
          try
            set procList to processes of t
            if (count of procList) > 0 then set jobVal to item -1 of procList
          end try
          set titleVal to ""
          try
            set titleVal to custom title of t
          end try
          if titleVal is missing value then set titleVal to ""
          set busyVal to "0"
          try
            if busy of t then set busyVal to "1"
          end try
          set sep to (character id 31)
          -- Record separator is a control char (not linefeed) so a title containing
          -- a newline can't split one tab's record across two lines.
          set out to out & ttyVal & sep & (w_i as string) & sep & (t_i as string) & sep & busyVal & sep & jobVal & sep & titleVal & (character id 30)
        end repeat
      end repeat
      return out
    end tell
    """

    private static func contentsScript(tty: String) -> String {
        // `contents of t` (a repeat-loop reference) is parsed as AppleScript's
        // dereference operator and returns the tab object, not its text. We must
        // read `contents` off a DIRECT index specifier, so capture the indices.
        """
        tell application "Terminal"
          set w_i to 0
          repeat with w in windows
            set w_i to w_i + 1
            set t_i to 0
            repeat with t in tabs of w
              set t_i to t_i + 1
              try
                if (tty of t) is \(AppleScript.quote(tty)) then return (contents of tab t_i of window w_i)
              end try
            end repeat
          end repeat
          return (character id 4)
        end tell
        """
    }

    // MARK: - Helpers (nonisolated so discovery enrichment runs concurrently)

    private func run(_ source: String) async throws -> String {
        try await Self.runMapped(source)
    }

    /// Runs a script and maps raw AppleScript errors to TerminalAdapterError so all
    /// call sites (connect/send/snapshot/stream/focus) surface consistent messages.
    nonisolated static func runMapped(_ source: String) async throws -> String {
        do {
            return try await runScript(source)
        } catch let AppleScriptError.scriptError(code, message) {
            if code == -1743 { throw TerminalAdapterError.automationDenied }
            throw TerminalAdapterError.scriptFailed(message)
        }
    }

    nonisolated static func runScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            scriptQueue.async {
                scriptSem.wait(); defer { scriptSem.signal() }   // cap concurrent osascript processes
                do { cont.resume(returning: try AppleScript.run(source)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Best-effort: resolve a tab's working directory from its tty by finding the
    /// foreground process and reading its cwd via lsof.
    nonisolated static func resolveCWD(tty: String) async -> String {
        let name = tty.replacingOccurrences(of: "/dev/", with: "")
        guard !name.isEmpty else { return "" }
        let ps = await shell("/bin/ps", ["-t", name, "-o", "pid=,stat="])
        var foreground: [String] = []
        for line in ps.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            if cols.count >= 2, cols[1].contains("+") { foreground.append(String(cols[0])) }
        }
        guard let pid = foreground.last else { return "" }
        let lsof = await shell("/usr/sbin/lsof", ["-a", "-p", pid, "-d", "cwd", "-Fn"])
        for line in lsof.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return ""
    }

    nonisolated static func shell(_ launchPath: String, _ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            scriptQueue.async {
                scriptSem.wait(); defer { scriptSem.signal() }   // cap concurrent processes
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = args
                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = Pipe()
                do { try process.run() } catch { cont.resume(returning: ""); return }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
