import Foundation
import Observation
import SnippAIKit

/// One in-place question anchored to a region of the frozen screen — a PR-style
/// comment thread. Owns its own constrained one-shot so many can stream at once.
@MainActor
@Observable
final class Annotation: Identifiable {
    enum Phase: Equatable { case composing, answering, done }

    let id = UUID()
    /// The selected region in overlay-view points — where the card anchors.
    let anchor: CGRect
    /// The exact sentence the user pointed at (matched from the full response),
    /// or the raw fragment when no confident match.
    let quote: String

    private(set) var phase: Phase = .composing
    private(set) var answer = ""
    private(set) var status: String?

    /// The full assistant response this question is about (already resolved).
    private let context: String?
    private var process: Process?
    private var task: Task<Void, Never>?

    init(anchor: CGRect, quote: String, context: String?) {
        self.anchor = anchor
        self.quote = quote
        self.context = context
    }

    /// Runs the one-shot with the user's question (nil/empty → "explain this").
    func submit(question: String?) {
        guard phase == .composing else { return }
        phase = .answering
        answer = ""
        status = nil

        let prompt = AskContext.prompt(question: question, highlighted: quote, context: context)
        do {
            let started = try ClaudeOneShot.run(prompt: prompt)
            process = started.process
            task = Task { [weak self] in
                for await event in started.events {
                    guard let self else { return }
                    switch event {
                    case .text(let t): self.answer += t
                    case .finished: self.phase = .done
                    case .ignored: break
                    }
                }
                guard let self, self.phase == .answering else { return }
                self.phase = .done
                if self.answer.isEmpty {
                    self.status = "No answer — is Claude Code signed in?"
                }
            }
        } catch {
            phase = .done
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}
