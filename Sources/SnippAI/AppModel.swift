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

    init(adapter: any TargetAdapter = ITermAdapter()) {
        self.adapter = adapter
    }

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    /// Called when a new screenshot arrives and the panel is shown.
    func beginSession(screenshot: URL?) async {
        screenshotURL = screenshot
        justSent = false
        messageText = ""
        connectionError = nil
        await refreshSessions()
        if ProcessInfo.processInfo.environment["SNIPPAI_FORCE_PICKER"] == "1" {
            selectedSessionID = nil
            phase = .picking
            return
        }
        // If we already had a valid selection, jump straight to composing.
        if let id = selectedSessionID, sessions.contains(where: { $0.id == id }) {
            startComposing(sessionID: id)
        } else {
            selectedSessionID = nil
            phase = .picking
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
            // Default selection: prefer an agent-looking session if none chosen.
            if selectedSessionID == nil {
                selectedSessionID = discovered.first(where: { $0.looksLikeAgent })?.id
            }
        } catch {
            connectionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            sessions = []
        }
    }

    /// Moves the picker highlight up/down for keyboard navigation.
    func moveSelection(by delta: Int) {
        guard !sessions.isEmpty else { return }
        let current = sessions.firstIndex { $0.id == selectedSessionID }
        let start = current ?? (delta > 0 ? -1 : 0)
        let next = max(0, min(sessions.count - 1, start + delta))
        selectedSessionID = sessions[next].id
    }

    /// Confirms the current picker highlight (Return key).
    func confirmSelection() {
        if let id = selectedSessionID { choose(sessionID: id) }
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
        justSent = false
        statusMessage = nil
        connectionError = nil
        phase = .picking
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
                    self.connectionError = "Connection to iTerm2 was lost. Choose the session again to reconnect."
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
            try await adapter.send(text: composed + "\n", toSession: sessionID)
            justSent = true
            messageText = ""
            statusMessage = "Sent to \(selectedSession?.folderName ?? "session")"
        } catch {
            connectionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Builds the text injected into the session. The bare screenshot path lets
    /// Claude's Read tool ingest the PNG without a native image attachment.
    static func composeMessage(text: String, screenshot: URL?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let screenshot else { return trimmed }
        let path = screenshot.path
        if trimmed.isEmpty {
            return "Look at this screenshot: \(path)"
        }
        return "\(trimmed)\n\nScreenshot: \(path)"
    }

    func teardown() {
        streamTask?.cancel()
        streamTask = nil
    }
}
