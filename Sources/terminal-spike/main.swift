import Foundation
import SnippAIKit

// SnippAI Terminal.app adapter spike — the Terminal analogue of iterm-spike.
// Proves discover / send / poll-stream against live Terminal.app, with no Python.
// Safe: only reads existing tabs; the send/stream test runs in a throwaway window
// it opens and closes.

func line(_ s: String) { print(s) }

let token = "SNIPPAI_" + String((0..<8).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! })

func run() async -> Bool {
    let adapter = TerminalAppAdapter()
    var enumerateOK = false, sendOK = false, streamOK = false
    var latencyMS: Double?

    do {
        try await adapter.connect()
    } catch {
        line("[CONNECT-ERROR] \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        line("  -> Terminal.app must be running and Automation must be allowed for this process.")
        return false
    }

    // ---- LEG 1: DISCOVER ---------------------------------------------------
    do {
        let sessions = try await adapter.discover()
        line("[LEG 1] DISCOVER: \(sessions.count) Terminal tab(s)")
        for s in sessions.prefix(10) {
            line("          - \(s.id)  cwd=\(s.cwd)  job=\(s.jobName)  win\(s.windowNumber)·tab\(s.tabIndex + 1)  last=\(s.lastLine.prefix(40))")
        }
        enumerateOK = !sessions.isEmpty
    } catch {
        line("[LEG 1] DISCOVER FAILED: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }

    // ---- isolated throwaway window (never touch the user's tabs) -----------
    do {
        let tty = try AppleScript.run("tell application \"Terminal\" to return tty of (do script \"\")")
        line("[setup] throwaway tab tty = \(tty)")
        try await Task.sleep(nanoseconds: 700_000_000) // let the shell prompt settle

        // ---- LEG 2: SEND ---------------------------------------------------
        let payload = "echo \(token)"
        let t0 = Date()
        try await adapter.send(text: payload, toSession: tty)
        line("[LEG 2] SEND: ran \(payload.debugDescription) in throwaway tab")
        sendOK = true

        // ---- LEG 3: STREAM (poll snapshot, bounded) -----------------------
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let screen = try? await adapter.snapshot(ofSession: tty) {
                for line in screen.lines {
                    let text = line.plainText
                    // The executed-output line is the bare token (not the "echo TOKEN" command line).
                    if text.contains(token) && !text.contains("echo") {
                        streamOK = true
                        if latencyMS == nil { latencyMS = Date().timeIntervalSince(t0) * 1000 }
                    }
                }
            }
            if streamOK { break }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        let lat = latencyMS.map { String(format: "  (round-trip %.0fms)", $0) } ?? ""
        line("[LEG 3] STREAM: executed-output-seen=\(streamOK)\(lat)")

        // cleanup: close the throwaway window by its tty
        _ = try? AppleScript.run("""
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (tty of t) is "\(tty)" then close w
              end try
            end repeat
          end repeat
        end tell
        """)
        line("[cleanup] closed throwaway window")
    } catch {
        line("[setup/send/stream ERROR] \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }

    await adapter.disconnect()

    line("\n==================== TERMINAL SPIKE RESULT ====================")
    let legs: [(String, Bool)] = [
        ("DISCOVER tabs (picker)", enumerateOK),
        ("SEND text to a tab", sendOK),
        ("STREAM (poll) contents back", streamOK),
    ]
    for (name, ok) in legs { line("  [\(ok ? "PASS" : "FAIL")] \(name)") }
    let overall = legs.allSatisfy { $0.1 }
    line("  ---> \(overall ? "ALL GREEN — Terminal.app adapter works" : "INCOMPLETE")")
    line("===============================================================")
    return overall
}

let ok = await run()
exit(ok ? 0 : 1)
