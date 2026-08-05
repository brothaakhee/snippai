import CoreGraphics
import Observation
import SnippAIKit

/// The state of one overlay session: the frozen backdrop, the full response
/// everything is asked against, and the anchored question threads.
@MainActor
@Observable
final class AnnotationSession {
    /// Frozen screenshot shown behind the annotations (pixel-resolution).
    let backdrop: CGImage
    /// Logical size of the screen the backdrop covers (points).
    let backdropSize: CGSize

    private(set) var annotations: [Annotation] = []

    init(backdrop: CGImage, backdropSize: CGSize) {
        self.backdrop = backdrop
        self.backdropSize = backdropSize
    }

    /// The thread currently taking a question (voice/keyboard bind to it).
    var composing: Annotation? { annotations.last { $0.phase == .composing } }

    /// Adds a thread for a pointed-at region. `fragment` is the raw OCR/selection
    /// text. We find the Claude conversation those on-screen words actually came
    /// from — a content match across the recent transcripts — and attach its full
    /// response as context, so the answer knows what was being said there. When no
    /// session contains the text (e.g. a browser selection) there's no context and
    /// the answer relies on the quote alone.
    @discardableResult
    func addAnnotation(anchor: CGRect, fragment: String) async -> Annotation {
        // Only one open composer at a time — asking is sequential (single mic).
        composing?.cancel()
        annotations.removeAll { $0.phase == .composing && $0.answer.isEmpty }

        // Resolve off the main actor — it reads several transcript files.
        let resolved = await Task.detached { ActiveTranscript.match(fragment: fragment) }.value
        let quote = resolved.flatMap { SentenceMatcher.bestSentence(forFragment: fragment, in: $0.response) }
            ?? fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        let annotation = Annotation(anchor: anchor, quote: quote, context: resolved?.response)
        annotations.append(annotation)
        return annotation
    }

    /// Removes a single thread (its × button).
    func remove(_ annotation: Annotation) {
        annotation.cancel()
        annotations.removeAll { $0 === annotation }
    }

    func clear() {
        annotations.forEach { $0.cancel() }
        annotations = []
    }
}
