import Foundation
import Observation
import SnippAIKit

/// Drives "Ask": a highlighted piece of the screen becomes a one-off, constrained
/// Claude question whose answer streams into the panel — the user's main session
/// is never touched. Cheap by construction (haiku, tools forbidden) and killable
/// (Esc terminates the subprocess).
@MainActor
@Observable
final class AskController {
    enum State: Equatable {
        case inactive
        case composingQuestion(quote: String)   // quote captured; user speaks/types the question
        case answering(quote: String)
        case done(quote: String)
    }

    private(set) var state: State = .inactive
    private(set) var answer = ""
    private(set) var statusMessage: String?
    var isActive: Bool { state != .inactive }

    /// Fired on enable/disable so the app can claim/release the global hotkey —
    /// a disabled feature must not keep swallowing ⌥⇧A system-wide.
    var onEnabledChange: (() -> Void)?

    /// Kill switch (Settings). Default on — the feature no-ops anyway when the
    /// `claude` CLI isn't installed.
    private(set) var isEnabled: Bool =
        UserDefaults.standard.object(forKey: AskController.enabledKey) as? Bool ?? true

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if !on { cancel() }
        onEnabledChange?()
    }
    private static let enabledKey = "ask.enabled"

    static var claudeAvailable: Bool { ClaudeOneShot.binaryPath() != nil }

    private var process: Process?
    private var streamTask: Task<Void, Never>?
    /// Invalidates a superseded ask's late writes: an old stream task resuming
    /// after cancellation must never touch the new ask's state.
    private var generation = 0

    private var transcriptPath: String?

    /// Enters the question phase for a captured quote: the panel shows it and
    /// waits for the user's question (spoken or typed; empty = "explain this").
    func prepare(highlighted: String, transcriptPath: String?) {
        cancel()
        self.transcriptPath = transcriptPath
        statusMessage = nil
        state = .composingQuestion(quote: highlighted)
    }

    /// Runs the one-shot with the user's question (nil/empty → canned "explain").
    func submit(question: String?) {
        guard case .composingQuestion(let quote) = state else { return }
        begin(highlighted: quote, question: question)
    }

    /// Starts the one-shot for the current quote + question. Context comes from
    /// the transcript path captured in `prepare`.
    private func begin(highlighted: String, question: String?) {
        let transcriptPath = self.transcriptPath
        cancelWork()   // a new ask replaces any previous one (keep view mounted)
        generation += 1
        let gen = generation
        answer = ""
        statusMessage = nil
        state = .answering(quote: highlighted)

        streamTask = Task { [weak self] in
            // Transcripts grow to tens of MB — read/decode off the main actor.
            let context: String? = await Task.detached {
                AskContext.contextIfRelevant(highlighted: highlighted, transcriptPath: transcriptPath, maxLength: 4000)
            }.value
            guard let self, self.generation == gen else { return }

            let prompt = AskContext.prompt(question: question, highlighted: highlighted, context: context)
            let events: AsyncStream<ClaudeOneShot.StreamEvent>
            do {
                let started = try ClaudeOneShot.run(prompt: prompt)
                self.process = started.process
                events = started.events
            } catch {
                // Keep the view mounted so the failure is visible, not a vanish.
                self.state = .done(quote: highlighted)
                self.statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return
            }

            for await event in events {
                guard self.generation == gen else { return }
                switch event {
                case .text(let t): self.answer += t
                case .finished: self.state = .done(quote: highlighted)
                case .ignored: break
                }
            }
            // Stream ended without a result (process died / killed): if we got
            // nothing, say so rather than leaving an eternal spinner.
            guard self.generation == gen else { return }
            if case .answering = self.state {
                self.state = .done(quote: highlighted)
                if self.answer.isEmpty {
                    self.statusMessage = "No answer — is Claude Code signed in? (Try `claude` in a terminal.)"
                }
            }
        }
    }

    /// Stops everything and leaves ask mode (Esc, panel close, new capture).
    func cancel() {
        cancelWork()
        state = .inactive
        answer = ""
    }

    /// Stops the subprocess/stream without leaving ask mode (used when a new
    /// question replaces a streaming answer inside the same panel).
    private func cancelWork() {
        generation += 1            // orphan any in-flight task's late writes
        streamTask?.cancel()
        streamTask = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}
