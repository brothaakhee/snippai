import AppKit
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
    /// Maintained by PanelController (show/hide). Views consult it before starting
    /// anything that must never run off-screen — the SwiftUI hierarchy stays mounted
    /// in an ordered-out window, so `onAppear` alone can fire while hidden (e.g.
    /// ComposeView remounting after Ask dismissal must NOT hot-mic a hidden panel).
    var panelIsVisible = false

    // MARK: - Update banner (fed by UpdateController via AppDelegate)

    /// The newer version the update check found, if any. Set by AppDelegate whenever
    /// the check result changes; the panel shows a dismissible banner for it.
    var availableUpdateVersion: String?
    /// Opens the update download — wired by AppDelegate to UpdateController.
    var openUpdate: (() -> Void)?
    /// The version whose banner the user dismissed. Persisted so dismissing 1.0.5's
    /// banner silences 1.0.5 across launches but a later 1.0.6 shows again. The
    /// menu-bar "Update to…" item remains available either way. Kept as stored
    /// (observable) state — the UserDefaults write is only persistence.
    private static let dismissedUpdateVersionKey = "update.dismissedBannerVersion"
    private var dismissedUpdateVersion: String?

    /// The version the banner should advertise, or nil when there's nothing to show
    /// (no update, or this version's banner was dismissed).
    var updateBannerVersion: String? {
        guard let v = availableUpdateVersion, v != dismissedUpdateVersion else { return nil }
        return v
    }

    func dismissUpdateBanner() {
        dismissedUpdateVersion = availableUpdateVersion
        UserDefaults.standard.set(availableUpdateVersion, forKey: Self.dismissedUpdateVersionKey)
    }
    var selectedSessionID: String?
    var pickerQuery: String = ""
    /// Bumped each time the picker is (re)presented so the search field re-grabs focus.
    var pickerFocusToken = 0
    /// Screenshots staged for the current prompt. Multiple can be accumulated (the
    /// hotkey/"+" appends) and all are sent together. Capped at `maxScreenshots`.
    var screenshotURLs: [URL] = []
    static let maxScreenshots = 5
    var screen: TerminalScreen = .empty
    var messageText: String = ""
    var statusMessage: String?
    var connectionError: String?
    var isSending = false
    var isLoadingSessions = false
    var justSent = false
    /// Bumped when the user sends, so the mirror snaps to the tail to show the result.
    private(set) var mirrorScrollTick = 0
    /// Key the mirror uses to decide when to force-scroll to the bottom (session
    /// switch or a fresh send) vs. follow-only-if-at-bottom during live updates.
    var mirrorScrollKey: String { "\(selectedSessionID ?? "")#\(mirrorScrollTick)" }

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

    /// The native-chat mirror's conversation, built by tailing the selected session's
    /// transcript JSONL. This is the UI-agnostic mirror — it renders the same whether
    /// the session runs in a terminal or the Claude desktop app (both write the same
    /// host `~/.claude/projects/.../<uuid>.jsonl`).
    let conversation = ConversationStore()
    @ObservationIgnored private lazy var transcriptMirror = TranscriptMirrorController(store: conversation)
    /// Exact transcript path per session id, learned from hook frames — overrides the
    /// cwd-based cold-start guess once a hook pins the pane's actual transcript.
    private var sessionTranscriptPaths: [String: String] = [:]

    let adapter: any TargetAdapter
    private var streamTask: Task<Void, Never>?
    private var streamGeneration = 0
    private static let lastSessionKey = "lastUsedSessionID"
    private var lastUsedSessionID: String?

    init(adapter: (any TargetAdapter)? = nil) {
        // Desktop inject is UI automation (AppKit/CGEvent), which SnippAIKit can't do —
        // hand the adapter an app-layer injector closure so the desktop app becomes a
        // first-class send target, not mirror-only.
        self.adapter = adapter ?? AdapterRouter(adapters: [
            ITermAdapter(),
            TerminalAppAdapter(),
            ClaudeDesktopAdapter(inject: DesktopInjector.make()),
        ])
        lastUsedSessionID = UserDefaults.standard.string(forKey: Self.lastSessionKey)
        dismissedUpdateVersion = UserDefaults.standard.string(forKey: Self.dismissedUpdateVersionKey)
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

    /// Starts a FRESH compose session with the given screenshots (resets the draft).
    /// Used on first capture and when reopening the panel.
    func beginSession(screenshots: [URL]) async {
        screenshotURLs = Array(screenshots.prefix(Self.maxScreenshots))
        justSent = false
        messageText = ""
        pickerQuery = ""
        connectionError = nil
        await refreshSessions()   // sets selectedSessionID to the last-used / preferred session
        var forcePicker = false
        #if DEBUG
        if ProcessInfo.processInfo.environment["SNIPPAI_DEMO_STATES"] == "1" { seedDemoStates() }
        forcePicker = ProcessInfo.processInfo.environment["SNIPPAI_FORCE_PICKER"] == "1"
        #endif
        // Always drop straight into the terminal for the resolved target (the
        // last-used session, per refreshSessions' selection) to cut steps — even if
        // it isn't obviously an agent. The picker only appears when there's nothing
        // to target. Switch later via ⌘-arrow or "Change".
        if !forcePicker, let session = selectedSession {
            startComposing(sessionID: session.id)
            #if DEBUG
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
            #endif
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
                // Prefer an INJECTABLE target so a mirror-only desktop session never
                // becomes the silent default (which would disable send with no picker).
                selectedSessionID = filteredSessions.first(where: { $0.id == lastUsedSessionID })?.id
                    ?? filteredSessions.first(where: { $0.looksLikeAgent && $0.supportsInject })?.id
                    ?? filteredSessions.first(where: { $0.supportsInject })?.id
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
        // Don't persist a mirror-only target as the launch default — it would be
        // auto-restored next launch and strand the user on a can't-send panel.
        if sessions.first(where: { $0.id == sessionID })?.supportsInject != false {
            lastUsedSessionID = sessionID
            UserDefaults.standard.set(sessionID, forKey: Self.lastSessionKey)
        }
        justSent = false
        statusMessage = nil
        startComposing(sessionID: sessionID)
    }

    /// Resolves and mirrors the session's transcript as a native chat. Prefers the
    /// exact path a hook pinned for this pane; otherwise cold-starts from the newest
    /// transcript in the session's working directory.
    private func bindTranscriptMirror(forSession sessionID: String) {
        let session = sessions.first { $0.id == sessionID }
        // 1) Exact path the adapter already knows (e.g. the desktop registry).
        if let exact = session?.transcriptPath, !exact.isEmpty {
            transcriptMirror.bind(toPath: exact)
            return
        }
        // 2) Exact path a hook pinned for this pane.
        if let exact = sessionTranscriptPaths[sessionID] {
            transcriptMirror.bind(toPath: exact)
            return
        }
        // 3) Cold-start: newest transcript in the session's working directory —
        // excluding any co-resident desktop session's transcript (which is always the
        // newest while active), so a terminal target never mirrors the desktop's chat.
        let desktopPaths = Set(sessions.filter { !$0.hasScreenStream }
            .map(\.transcriptPath).filter { !$0.isEmpty })
        if let cwd = session?.cwd, !cwd.isEmpty,
           let url = TranscriptLocator.newestTranscript(forCWD: cwd, excluding: desktopPaths) {
            transcriptMirror.bind(toPath: url.path)
        } else {
            transcriptMirror.stop()
            conversation.reset()
        }
    }

    #if DEBUG
    /// Debug (SNIPPAI_MIRROR_TRANSCRIPT): mirror a specific transcript file directly,
    /// so the native chat can be inspected/screenshotted against a real conversation.
    func debugMirrorTranscript(path: String) {
        phase = .composing
        transcriptMirror.bind(toPath: path)
    }
    #endif

    func backToPicker() {
        teardown()
        conversation.reset()
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
        // The faithful, cell-accurate terminal mirror is the display for sessions with
        // a real screen (iTerm/Terminal) — it shows exactly what's on screen, ANSI and
        // all. The transcript-driven native chat is ONLY for targets that have no
        // terminal screen to mirror (the Claude desktop app); using it for terminals
        // would replace the true render with a less-faithful reconstruction.
        if sessions.first(where: { $0.id == sessionID })?.hasScreenStream == false {
            bindTranscriptMirror(forSession: sessionID)
        } else {
            transcriptMirror.stop()
            conversation.reset()
        }
        // Show this session's last-known frame instantly (keyed by session, so it's
        // never another session's content) — only fall back to the "Connecting…"
        // placeholder for a target we haven't mirrored yet. Keeps cycling smooth.
        screen = screenCache[sessionID] ?? .empty
        connectionError = nil
        streamTask?.cancel()
        streamGeneration += 1
        // Start the terminal screen stream only for a target that actually has one.
        // The Claude desktop app has no terminal screen — the transcript-driven
        // conversation mirror is its display — and an unknown/not-yet-discovered id
        // defaults to skip, so the stream's "ended → connection lost" path can't fire
        // a false error against a session with no terminal.
        if sessions.first(where: { $0.id == sessionID })?.hasScreenStream != true {
            streamTask = nil
            return
        }
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

    // MARK: - Screenshot accumulation

    /// Whether another screenshot can be staged (under the cap).
    var canAddScreenshot: Bool { screenshotURLs.count < Self.maxScreenshots }

    /// Appends a screenshot to the current draft (used by the hotkey/"+"), keeping
    /// the typed message and selected session intact. No-op at the cap.
    func addScreenshot(_ url: URL) {
        guard canAddScreenshot, !screenshotURLs.contains(url) else { return }
        screenshotURLs.append(url)
        clearSentBadge()
    }

    /// Removes a staged screenshot.
    func removeScreenshot(_ url: URL) {
        screenshotURLs.removeAll { $0 == url }
    }

    /// The transcript path of the session the user most recently worked in — the
    /// MVP context heuristic for Ask ("explain why the assistant said this").
    /// Hook-derived, so it's only known when the Claude Code status integration
    /// has seen the session; nil otherwise (Ask degrades to a context-free answer).
    var lastUsedSessionTranscriptPath: String? {
        guard let id = lastUsedSessionID else { return nil }
        return sessionTranscriptPaths[id]
    }

    /// Appends text into the draft (voice transcript, future paste/drop sources) —
    /// the single mutation surface for the message, with separator smarts so a
    /// transcript never lands as "foo  bar" after trailing whitespace.
    func appendToMessage(_ text: String) {
        if messageText.isEmpty || messageText.hasSuffix(" ") || messageText.hasSuffix("\n") {
            messageText += text
        } else {
            messageText += " " + text
        }
    }

    /// Composes the outgoing message (user text + screenshot paths) and submits it.
    /// Returns whether the prompt was actually delivered — the caller closes the
    /// panel only on a real send, never on a guard bail-out or a failure.
    @discardableResult
    func send() async -> Bool {
        guard let sessionID = selectedSessionID else { return false }
        // Defense-in-depth: the UI disables send for mirror-only targets; never try to
        // inject into one (the adapter would just throw).
        guard selectedSession?.supportsInject != false else { return false }
        let composed = composeMessage(text: messageText, screenshots: screenshotURLs)
        guard !composed.isEmpty else { return false }
        isSending = true
        defer { isSending = false }
        guard await confirmTargetCanReceive(sessionID: sessionID) else { return false }
        do {
            // The adapter owns submission (iTerm appends a newline; Terminal's
            // `do script` auto-submits). We pass a single-line message so it lands
            // as ONE prompt, never fragmented into multiple submissions.
            try await adapter.send(text: composed, toSession: sessionID)
            justSent = true
            messageText = ""
            screenshotURLs = []     // consumed — next prompt starts clean
            mirrorScrollTick += 1   // snap the mirror to the tail to show the result
            statusMessage = "Sent to \(selectedSession?.folderName ?? "session")"
            // Don't fake a "Working" badge here: the status badge is purely hook-driven.
            // If the integration is enabled, the sent prompt fires UserPromptSubmit →
            // Working → Stop → Done on its own. If it's off, there's no badge to clear
            // and faking one would get stuck forever (no Stop event ever arrives).
            return true
        } catch {
            connectionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Guards against typing into a pane whose agent has exited: the message (text +
    /// screenshot path) would land at the shell prompt and run as a shell command.
    /// Re-discovers at send time — the cached session list can be stale, and "Claude
    /// exited since the panel opened" is exactly the dangerous case. A terminal pane
    /// that isn't running an agent CLI needs explicit confirmation; a vanished session
    /// blocks the send outright. Desktop targets have no shell, so they skip the check,
    /// and a failed discovery falls through to `send`, whose error path covers a dead
    /// connection.
    private func confirmTargetCanReceive(sessionID: String) async -> Bool {
        guard let cached = sessions.first(where: { $0.id == sessionID }),
              cached.hasScreenStream else { return true }
        guard let discovered = try? await adapter.discover() else { return true }
        // Don't discard the round trip — fold the fresh discovery into the identity
        // maps (same bookkeeping refreshSessions does) while we have it.
        observeDiscovered(discovered)
        guard let current = discovered.first(where: { $0.id == sessionID }) else {
            connectionError = "That session is no longer open. Choose another target."
            return false
        }
        if current.looksLikeAgent { return true }
        // The job name only reflects the pane's FOREGROUND process — an agent that's
        // busy running a compiler/LSP/test child reads as that child (e.g. Claude
        // building Swift shows "sourcekit-lsp"). Before warning, ask the ground
        // truth: is an agent CLI alive on this pane's tty?
        let tty = current.tty
        if !tty.isEmpty, await Task.detached(operation: { AgentProbe.agentAlive(onTTY: tty) }).value {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This pane isn’t running an AI agent"
        alert.informativeText = """
        The \(current.source) pane in “\(current.folderName)” is running “\(current.jobName)”. \
        Your message would be typed at the shell prompt — and could run as a shell command.
        """
        alert.addButton(withTitle: "Cancel")            // default (Return) — safe choice
        alert.addButton(withTitle: "Send Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Brings the selected session's terminal (or app) to the front so the user can
    /// jump straight to where their message landed. Best-effort: surfaces a status
    /// message on failure rather than interrupting with an error.
    func focusSelectedSession() {
        guard let sessionID = selectedSessionID else { return }
        // Capture the name now: the user may cycle targets before the async call returns.
        let appName = selectedSession?.source ?? "the terminal"
        Task {
            do { try await adapter.focus(sessionID: sessionID) }
            catch { statusMessage = "Couldn’t open \(appName)" }
        }
    }

    /// Stops all live mirroring (terminal screen stream + transcript tailer). Called
    /// when the panel closes — otherwise the stream keeps round-tripping full screen
    /// buffers in the background for as long as the app runs. Reopening the panel
    /// always goes through `beginSession` → `startComposing`, which restarts it.
    func teardown() {
        streamTask?.cancel()
        streamTask = nil
        streamGeneration += 1   // invalidate the cancelled stream's late writes
        transcriptMirror.stop()
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

    #if DEBUG
    /// Debug only (SNIPPAI_DEMO_STATES=1): paints a spread of agent states across the
    /// discovered sessions so the badge UI can be screenshotted without a live Claude.
    private func seedDemoStates() {
        let demo: [AgentState] = [.waitingForInput, .finished, .working]
        for (session, state) in zip(sessions, demo) {
            agentStates[session.id] = AgentStateEntry(state: state, lastEventAt: Date())
        }
        notifyAttention()
    }
    #endif

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
            for: frame, knownIDs: knownSessionIDs, ttyToID: ttyToSessionID) else { return }
        // Learn this pane's exact transcript path (per-pane ground truth) even when the
        // event itself isn't a state transition — it upgrades the mirror's cold-start
        // guess and rebinds the live mirror if this is the session being viewed.
        if let path = frame.claudePayload?.transcriptPath, !path.isEmpty {
            sessionTranscriptPaths[id] = path
            if id == selectedSessionID, phase == .composing {
                transcriptMirror.bind(toPath: path)
            }
        }
        guard let state = AgentState.from(event: frame.event) else { return }
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

}
