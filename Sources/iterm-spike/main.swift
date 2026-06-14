import Foundation
import SnippAIKit

// SnippAI native-tunnel spike: the Swift analogue of spike_iterm.py.
// Proves the native client can ENUMERATE / SEND / STREAM against live iTerm2,
// with no Python runtime. Safe: only reads existing sessions; the send/stream
// test runs in a throwaway window that is closed at the end.

func line(_ s: String) { print(s) }

let token = "SNIPPAI_" + String((0..<8).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! })
let fakeShot = "/tmp/snippai_spike_shot.png"

func walk(_ node: Iterm2_SplitTreeNode, into out: inout [String]) {
    for link in node.links {
        switch link.child {
        case .session(let s): out.append(s.uniqueIdentifier)
        case .node(let n): walk(n, into: &out)
        case .none: break
        }
    }
}

func run() async -> Bool {
    let client = ITermClient()
    var enumerateOK = false, sendOK = false, streamOK = false
    var latencyMS: Double?

    do {
        try await client.connect()
    } catch {
        line("[CONNECT-ERROR] \(error.localizedDescription)")
        line("  -> Likely the iTerm2 Python API is not enabled, or permission was denied.")
        return false
    }

    // ---- LEG 1: ENUMERATE -------------------------------------------------
    do {
        let sessions = try await client.listSessions()
        var ids: [String] = []
        for window in sessions.windows {
            for tab in window.tabs where tab.hasRoot {
                walk(tab.root, into: &ids)
            }
        }
        line("[LEG 1] ENUMERATE: \(ids.count) live session(s)")
        for sid in ids.prefix(10) {
            let vars = (try? await client.variables(sessionID: sid, names: ["path", "autoName", "jobName"])) ?? [:]
            line("          - \(sid)  cwd=\(vars["path"] ?? "?")  title=\(vars["autoName"] ?? "?")  job=\(vars["jobName"] ?? "?")")
        }
        enumerateOK = !ids.isEmpty
    } catch {
        line("[LEG 1] ENUMERATE FAILED: \(error.localizedDescription)")
    }

    // ---- isolated test target (never clobber the user's sessions) ---------
    do {
        let (testSession, testWindow) = try await client.createWindow()
        line("[setup] isolated test session = \(testSession)")
        try await client.subscribe(.notifyOnScreenUpdate, sessionID: testSession)
        let stream = await client.notifications()
        try await Task.sleep(nanoseconds: 600_000_000) // let the shell prompt settle

        // ---- LEG 2: SEND --------------------------------------------------
        let payload = "echo \"\(token) :: please look at \(fakeShot)\"\n"
        let t0 = Date()
        try await client.sendText(sessionID: testSession, text: payload)
        line("[LEG 2] SEND: injected \(payload.debugDescription)")
        sendOK = true

        // ---- LEG 3: STREAM ------------------------------------------------
        let deadline = Date().addingTimeInterval(8)
        var sawCommand = false, sawOutput = false
        streamLoop: for await notification in stream {
            guard notification.hasScreenUpdateNotification,
                  notification.screenUpdateNotification.session == testSession else { continue }
            let buffer = try await client.screenContents(sessionID: testSession)
            for lineContents in buffer.contents {
                let text = lineContents.text
                guard text.contains(token), text.contains(fakeShot) else { continue }
                if text.contains("echo") {
                    sawCommand = true
                } else {
                    sawOutput = true
                    if latencyMS == nil { latencyMS = Date().timeIntervalSince(t0) * 1000 }
                }
            }
            if sawOutput || Date() > deadline { break streamLoop }
        }
        streamOK = sawOutput
        sendOK = sendOK && (sawCommand || sawOutput)
        let lat = latencyMS.map { String(format: "  (round-trip %.0fms)", $0) } ?? ""
        line("[LEG 3] STREAM: command-echoed=\(sawCommand) executed-output=\(sawOutput)\(lat)")

        try await client.closeWindow(windowID: testWindow)
        line("[cleanup] closed isolated test window")
    } catch {
        line("[setup/send/stream ERROR] \(error.localizedDescription)")
    }

    await client.disconnect()

    line("\n==================== SPIKE RESULT ====================")
    let legs: [(String, Bool)] = [
        ("ENUMERATE sessions (picker)", enumerateOK),
        ("SEND text+path to a session", sendOK),
        ("STREAM screen back live", streamOK),
    ]
    for (name, ok) in legs { line("  [\(ok ? "PASS" : "FAIL")] \(name)") }
    let overall = legs.allSatisfy { $0.1 }
    line("  ---> \(overall ? "ALL GREEN — native tunnel is real" : "INCOMPLETE")")
    line("======================================================")
    return overall
}

let ok = await run()
exit(ok ? 0 : 1)
