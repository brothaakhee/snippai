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

    let adapter: any TargetAdapter
    private var streamTask: Task<Void, Never>?
    private var streamGeneration = 0

    init(adapter: any TargetAdapter = AdapterRouter(adapters: [ITermAdapter(), TerminalAppAdapter()])) {
        self.adapter = adapter
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
        let forcePicker = ProcessInfo.processInfo.environment["SNIPPAI_FORCE_PICKER"] == "1"
        // Auto-jump to composing only when the default target is an agent session;
        // otherwise show the picker (with that default highlighted for keyboard use).
        if !forcePicker, let session = selectedSession, session.looksLikeAgent {
            startComposing(sessionID: session.id)
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
            sessions = discovered
            connectionError = nil
            // Default/repair selection against the CURRENT filter: prefer an agent
            // session, else the first visible result. Also drops a stale selection
            // (closed session, or filtered out after cwd/lastLine changed).
            if !filteredSessions.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = filteredSessions.first(where: { $0.looksLikeAgent })?.id
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

    private func startComposing(sessionID: String) {
        phase = .composing
        screen = .empty
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
}
