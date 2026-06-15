import Foundation
import SnippAIKit
import Observation

/// The single source of truth for the panel UI. Owns the adapter connection,
/// the discovered sessions, the active screenshot, and the live screen mirror.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case picking          // choosing which session to target
        case composing        // a session is selected; mirror + input shown
    }

    var phase: Phase = .picking
    var sessions: [TerminalSession] = []
    var selectedSessionID: String?
    var pickerQuery: String = ""
    /// Bumped each time the picker is (re)presented so the search field re-grabs focus.
    var pickerFocusToken = 0
    var screenshotURL: URL?
    var screen: TerminalScreen = .empty
    var messageText: String = ""
    var statusMessage: String?
    var connectionError: String?
    var isSending = false
    var isLoadingSessions = false
    var justSent = false

    /// Push-hook-derived agent state per session id (iTerm GUID). Pure enrichment
    /// over the mirror — see docs/hook-bridge-spec.md. `.unknown` when no signal.
    var agentStates: [String: AgentStateEntry] = [:]
    /// Fired when the aggregate "any session needs attention" changes, so the
    /// menu-bar item can show/hide its dot without polling.
    var onAttentionChange: ((Bool) -> Void)?
    /// Every session GUID/tty we've ever discovered — the anti-spoof allowlist that
    /// also lets frames correlate while the panel (and its fresh session list) is closed.
    private var knownSessionIDs: Set<String> = []
    private var ttyToSessionID: [String: String] = [:]
    private var lastAttention = false
    /// Last rendered frame per session, so re-selecting a target (e.g. via ⌘-arrow
    /// cycling) repaints its mirror instantly instead of flashing the placeholder.
    private var screenCache: [String: TerminalScreen] = [:]

    let adapter: any TargetAdapter
    private var streamTask: Task<Void, Never>?
    private var streamGeneration = 0
    private static let lastSessionKey = "lastUsedSessionID"
    private var lastUsedSessionID: String?

    init(adapter: any TargetAdapter = AdapterRouter(adapters: [ITermAdapter(), TerminalAppAdapter()])) {
        self.adapter = adapter
        lastUsedSessionID = UserDefaults.standard.string(forKey: Self.lastSessionKey)
    }

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    /// Sessions matching the picker query — every whitespace-separated token must
    /// appear somewhere in the session's searchable text (case-insensitive).
    var filteredSessions: [TerminalSession] {
        let tokens = pickerQuery.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return sessions }
        return sessions.filter { session in
            let haystack = session.searchHaystack
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    /// Keeps a valid highlight as the filtered set changes: if the current
    /// selection dropped out of the results, jump to the first match.
    func ensureSelectionInFilter() {
        let results = filteredSessions
        if !results.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = results.first?.id
        }
    }

    /// Called when a new screenshot arrives and the panel is shown.
    func beginSession(screenshot: URL?) async {
        screenshotURL = screenshot
        justSent = false
        messageText = ""
        pickerQuery = ""
        connectionError = nil
        await refreshSessions()   // sets selectedSessionID to an agent-preferred visible session
        if ProcessInfo.processInfo.environment["SNIPPAI_DEMO_STATES"] == "1" { seedDemoStates() }
        let forcePicker = ProcessInfo.processInfo.environment["SNIPPAI_FORCE_PICKER"] == "1"
        // Auto-jump to composing only when the default target is an agent session;
        // otherwise show the picker (with that default highlighted for keyboard use).
        if !forcePicker, let session = selectedSession, session.looksLikeAgent {
            startComposing(sessionID: session.id)
            // Debug (SNIPPAI_DEMO_CYCLE=1): auto-cycle the target so the ⌘-arrow
            // behavior + directional slide can be screenshotted without synthetic keys.
            if ProcessInfo.processInfo.environment["SNIPPAI_DEMO_CYCLE"] == "1" {
                Task { @MainActor in
                    for _ in 0..<6 {
                        try? await Task.sleep(nanoseconds: 1_300_000_000)
                        cycleTarget(by: 1)
                    }
                }
            }
        } else {
            phase = .picking
            pickerFocusToken += 1
        }
    }

    func refreshSessions() async {
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        do {
            try await adapter.connect()
            let discovered = try await adapter.discover()
            observeDiscovered(discovered)
            // Pin the last-used session to the top so it's immediately visible.
            if let last = lastUsedSessionID, let idx = discovered.firstIndex(where: { $0.id == last }) {
                var reordered = discovered
                reordered.insert(reordered.remove(at: idx), at: 0)
                sessions = reordered
            } else {
                sessions = discovered
            }
            connectionError = nil
            // Default/repair selection against the CURRENT filter: prefer the
            // last-used session, then an agent session, then the first result.
            // Also drops a stale selection (closed, or filtered out).
            if !filteredSessions.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = filteredSessions.first(where: { $0.id == lastUsedSessionID })?.id
                    ?? filteredSessions.first(where: { $0.looksLikeAgent })?.id
                    ?? filteredSessions.first?.id
            }
        } catch {
            connectionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            sessions = []
        }
    }

    /// Moves the picker highlight up/down (over the filtered results).
    func moveSelection(by delta: Int) {
        let results = filteredSessions
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedSessionID }
        let start = current ?? (delta > 0 ? -1 : 0)
        let next = max(0, min(results.count - 1, start + delta))
        selectedSessionID = results[next].id
    }

    /// Confirms the current highlight, or the first result if nothing is highlighted.
    func confirmSelection() {
        let id = selectedSessionID ?? filteredSessions.first?.id
        if let id, filteredSessions.contains(where: { $0.id == id }) { choose(sessionID: id) }
    }

    func choose(sessionID: String) {
        selectedSessionID = sessionID
        lastUsedSessionID = sessionID
        UserDefaults.standard.set(sessionID, forKey: Self.lastSessionKey)
        justSent = false
        statusMessage = nil
        startComposing(sessionID: sessionID)
    }

    func backToPicker() {
        streamTask?.cancel()
        streamTask = nil
        streamGeneration += 1   // invalidate the cancelled stream's late writes
        pickerQuery = ""
        justSent = false
        statusMessage = nil
        connectionError = nil
        phase = .picking
        pickerFocusToken += 1
    }

    /// Clears the transient "Sent" confirmation (e.g. when the user starts typing again).
    func clearSentBadge() {
        if justSent { justSent = false; statusMessage = nil }
    }

    /// +1 when the last target change moved forward (⌘→/⌘↓), -1 backward — drives the
    /// directional slide of the target header so the switch reads as left/right motion.
    private(set) var cycleDirection = 1

    /// 1-based position of the current target among all sessions, and the total —
    /// shown as "n / total" next to the switch control so cycling is legible.
    var targetPosition: (index: Int, total: Int)? {
        guard let id = selectedSessionID, let idx = sessions.firstIndex(where: { $0.id == id })
        else { return nil }
        return (idx + 1, sessions.count)
    }

    /// Cycles the composing target through the discovered sessions (wrapping), used by
    /// the ⌘+arrow shortcuts. Reuses `choose` so the mirror, header, and badge all
    /// follow. No-op outside composing or with fewer than two sessions.
    func cycleTarget(by delta: Int) {
        guard phase == .composing, sessions.count > 1 else { return }
        let ids = sessions.map(\.id)
        let current = selectedSessionID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = cycledIndex(from: current, by: delta, count: ids.count)
        guard ids[next] != selectedSessionID else { return }
        cycleDirection = delta >= 0 ? 1 : -1
        choose(sessionID: ids[next])
    }

    private func startComposing(sessionID: String) {
        phase = .composing
        // Show this session's last-known frame instantly (keyed by session, so it's
        // never another session's content) — only fall back to the "Connecting…"
        // placeholder for a target we haven't mirrored yet. Keeps cycling smooth.
        screen = screenCache[sessionID] ?? .empty
        connectionError = nil
        streamTask?.cancel()
        streamGeneration += 1
        let generation = streamGeneration
        let adapter = self.adapter
        // This Task inherits MainActor isolation, so it can touch model state
        // directly. Only the latest stream (matching `generation`) may mutate UI
        // state, so a stale producer ending late can't paint over a new session.
        streamTask = Task { [weak self] in
            do {
                let stream = try await adapter.screenStream(forSession: sessionID)
                for await snapshot in stream {
                    guard let self, self.streamGeneration == generation else { return }
                    self.screen = snapshot
                    self.screenCache[sessionID] = snapshot
                    self.reconcileStateWithMirror(sessionID: sessionID)
                }
                // Stream ended without an error → the connection dropped (e.g. iTerm
                // restarted). Surface it instead of freezing on the last frame.
                if let self, self.streamGeneration == generation {
                    let app = self.selectedSession?.source ?? "the terminal"
                    self.connectionError = "Connection to \(app) was lost. Choose the session again to reconnect."
                }
            } catch {
                if let self, self.streamGeneration == generation {
                    self.connectionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    /// Composes the outgoing message (user text + screenshot path) and submits it.
    func send() async {
        guard let sessionID = selectedSessionID else { return }
        let composed = Self.composeMessage(text: messageText, screenshot: screenshotURL)
        guard !composed.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            // The adapter owns submission (iTerm appends a newline; Terminal's
            // `do script` auto-submits). We pass a single-line message so it lands
            // as ONE prompt, never fragmented into multiple submissions.
            try await adapter.send(text: composed, toSession: sessionID)
            justSent = true
            messageText = ""
            statusMessage = "Sent to \(selectedSession?.folderName ?? "session")"
            // We just gave this session work → it's busy again. Clears any prior
            // "needs you"/"done" badge (and the menu-bar dot) until the next hook event.
            agentStates[sessionID] = AgentStateEntry(state: .working, lastEventAt: Date())
            notifyAttention()
        } catch {
            connectionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Builds the single-line text injected into the session. Kept to one line so a
    /// live agent CLI receives it as one prompt (embedded newlines would submit
    /// prematurely / run as separate commands). The bare screenshot path lets
    /// Claude's Read tool ingest the PNG without a native image attachment.
    static func composeMessage(text: String, screenshot: URL?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard let screenshot else { return trimmed }
        let path = screenshot.path
        if trimmed.isEmpty {
            return "Look at this screenshot: \(path)"
        }
        return "\(trimmed)  (screenshot: \(path))"
    }

    func teardown() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Hook-derived agent state (enrichment over the mirror)

    /// The push-hook state for a session, or `.unknown` if no signal yet.
    func agentState(for sessionID: String) -> AgentState {
        agentStates[sessionID]?.state ?? .unknown
    }

    /// True when any tracked session is finished/waiting — drives the menu-bar dot.
    var anyNeedsAttention: Bool {
        agentStates.values.contains { $0.state.needsAttention }
    }

    /// Folds a fresh discovery into our identity maps and prunes dead state.
    ///
    /// - `knownSessionIDs` grows monotonically: GUIDs are unique and stable, so an
    ///   ever-seen allowlist both gates spoofed frames and lets frames correlate
    ///   while the panel (and its live session list) is closed.
    /// - `ttyToSessionID` is REBUILT from the live set, because ttys are recycled —
    ///   a stale tty→closed-session mapping would mis-correlate a reused tty.
    /// - `agentStates` is pruned to live sessions so a finished/closed session can't
    ///   keep the menu-bar attention dot lit forever.
    private func observeDiscovered(_ discovered: [TerminalSession]) {
        for s in discovered { knownSessionIDs.insert(s.id) }
        ttyToSessionID = Dictionary(
            discovered.compactMap { $0.tty.isEmpty ? nil : ($0.tty, $0.id) },
            uniquingKeysWith: { _, latest in latest })
        let liveIDs = Set(discovered.map { $0.id })
        let before = agentStates.count
        agentStates = agentStates.filter { liveIDs.contains($0.key) }
        screenCache = screenCache.filter { liveIDs.contains($0.key) }
        if agentStates.count != before { notifyAttention() }
    }

    /// Debug only (SNIPPAI_DEMO_STATES=1): paints a spread of agent states across the
    /// discovered sessions so the badge UI can be screenshotted without a live Claude.
    private func seedDemoStates() {
        let demo: [AgentState] = [.waitingForInput, .finished, .working]
        for (session, state) in zip(sessions, demo) {
            agentStates[session.id] = AgentStateEntry(state: state, lastEventAt: Date())
        }
        notifyAttention()
    }

    /// Seeds identities without disturbing UI — used at launch / on enable so the
    /// menu-bar badge can light up before the panel is ever opened.
    func seedIdentities() async {
        do {
            try await adapter.connect()
            observeDiscovered(try await adapter.discover())
        } catch { /* best effort — correlation simply waits for the next discovery */ }
    }

    /// Applies one decoded hook frame. Drops frames that don't correlate to a known
    /// session (anti-spoof) or carry an unrecognized event (schema drift).
    func applyHookFrame(_ frame: HookFrame) {
        guard let id = HookCorrelator.sessionID(
            for: frame, knownIDs: knownSessionIDs, ttyToID: ttyToSessionID),
              let state = AgentState.from(event: frame.event) else { return }
        agentStates[id] = AgentStateEntry(
            state: state, lastEventAt: Date(), message: frame.claudePayload?.message)
        notifyAttention()
    }

    private func notifyAttention() {
        let now = anyNeedsAttention
        if now != lastAttention {
            lastAttention = now
            onAttentionChange?(now)
        }
    }

    /// Fresh mirror output means Claude is doing something, so a prior "done"/"needs
    /// you" badge has gone stale (e.g. the user answered a prompt directly in the
    /// terminal). Clear it — but guardedly: a `.waitingForInput` prompt TUI repaints
    /// (spinner/cursor) within milliseconds, so only treat output that arrives a
    /// beat AFTER the event as real progress; `.finished` clears immediately since
    /// nothing repaints after Stop.
    private func reconcileStateWithMirror(sessionID: String) {
        guard let entry = agentStates[sessionID] else { return }
        let stale: Bool
        switch entry.state {
        case .finished: stale = true
        case .waitingForInput: stale = Date().timeIntervalSince(entry.lastEventAt) > 2.0
        case .working, .unknown: stale = false
        }
        guard stale else { return }
        agentStates[sessionID] = AgentStateEntry(state: .working, lastEventAt: Date())
        notifyAttention()
    }
}
