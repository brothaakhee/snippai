import Foundation

/// `TargetAdapter` backed by the native iTerm2 client.
public actor ITermAdapter: TargetAdapter {
    public nonisolated let displayName = "iTerm2"
    private let client: ITermClient

    public init(client: ITermClient = ITermClient()) {
        self.client = client
    }

    public func connect() async throws { try await client.connect() }
    public func disconnect() async { await client.disconnect() }

    // MARK: - Discovery

    public func discover() async throws -> [TerminalSession] {
        let response = try await client.listSessions()
        var stubs: [TerminalSession] = []
        for window in response.windows {
            let windowNumber = Int(window.number)
            for (tabIndex, tab) in window.tabs.enumerated() where tab.hasRoot {
                var paneIDs: [String] = []
                collectSessions(tab.root, into: &paneIDs)
                for (paneIndex, sid) in paneIDs.enumerated() {
                    stubs.append(TerminalSession(
                        id: sid, windowID: window.windowID, tabID: tab.tabID,
                        windowNumber: windowNumber, tabIndex: tabIndex, paneIndex: paneIndex,
                        source: "iTerm2"))
                }
            }
        }

        // Enrich each session (variables + last visible line) concurrently.
        let client = self.client
        return try await withThrowingTaskGroup(of: TerminalSession.self) { group in
            for stub in stubs {
                group.addTask {
                    var session = stub
                    let vars = (try? await client.variables(
                        sessionID: stub.id, names: ["path", "autoName", "jobName"])) ?? [:]
                    session.cwd = vars["path"] ?? ""
                    session.title = vars["autoName"] ?? ""
                    session.jobName = vars["jobName"] ?? ""
                    if let screen = try? await client.screenContents(sessionID: stub.id) {
                        session.lastLine = TerminalScreenParser.parse(screen).lastNonEmptyLine ?? ""
                    }
                    return session
                }
            }
            var enriched: [TerminalSession] = []
            for try await session in group { enriched.append(session) }
            // Stable ordering: window, then tab, then pane.
            enriched.sort {
                ($0.windowNumber, $0.tabIndex, $0.paneIndex) < ($1.windowNumber, $1.tabIndex, $1.paneIndex)
            }
            return enriched
        }
    }

    private func collectSessions(_ node: Iterm2_SplitTreeNode, into out: inout [String]) {
        for link in node.links {
            switch link.child {
            case .session(let s): out.append(s.uniqueIdentifier)
            case .node(let n): collectSessions(n, into: &out)
            case .none: break
            }
        }
    }

    // MARK: - Send

    public func send(text: String, toSession sessionID: String) async throws {
        // Append the newline that submits the prompt (the adapter owns submission).
        try await client.sendText(sessionID: sessionID, text: text + "\n")
    }

    // MARK: - Stream

    public func snapshot(ofSession sessionID: String) async throws -> TerminalScreen {
        let buffer = try await client.screenContents(sessionID: sessionID)
        return TerminalScreenParser.parse(buffer)
    }

    public func screenStream(forSession sessionID: String) async throws -> AsyncStream<TerminalScreen> {
        // Subscribe every time — idempotent (tolerates .alreadySubscribed) and, crucially,
        // re-establishes the subscription after a reconnect so the mirror never silently freezes.
        try await client.subscribe(.notifyOnScreenUpdate)
        let notifications = await client.notifications()
        let client = self.client
        return AsyncStream { continuation in
            let task = Task {
                // Emit an immediate snapshot so the panel isn't blank.
                if let initial = try? await client.screenContents(sessionID: sessionID) {
                    continuation.yield(TerminalScreenParser.parse(initial))
                }
                for await notification in notifications {
                    guard notification.hasScreenUpdateNotification,
                          notification.screenUpdateNotification.session == sessionID else { continue }
                    if let buffer = try? await client.screenContents(sessionID: sessionID) {
                        continuation.yield(TerminalScreenParser.parse(buffer))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Focus

    public func focus(sessionID: String) async throws {
        try await client.activate(sessionID: sessionID)
    }
}
