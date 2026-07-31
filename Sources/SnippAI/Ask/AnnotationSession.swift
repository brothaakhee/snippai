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
    /// The full assistant response (from the active transcript), or nil when there
    /// is no resolvable Claude conversation — then answers rely on the quote alone.
    let fullResponse: String?

    private(set) var annotations: [Annotation] = []

    init(backdrop: CGImage, backdropSize: CGSize, fullResponse: String?) {
        self.backdrop = backdrop
        self.backdropSize = backdropSize
        self.fullResponse = fullResponse
    }

    /// The thread currently taking a question (voice/keyboard bind to it).
    var composing: Annotation? { annotations.last { $0.phase == .composing } }

    /// Adds a thread for a pointed-at region. `fragment` is the raw OCR/selection
    /// text; we resolve it to the exact sentence in the full response for a clean
    /// anchor quote.
    @discardableResult
    func addAnnotation(anchor: CGRect, fragment: String) -> Annotation {
        // Only one open composer at a time — asking is sequential (single mic).
        composing?.cancel()
        annotations.removeAll { $0.phase == .composing && $0.answer.isEmpty }

        // Only attach the response as context when the pointed-at text is actually
        // FROM it — a confident sentence match. Otherwise (e.g. text highlighted in
        // a browser) it's unrelated, so keep the raw fragment and no false context.
        let matched = fullResponse.flatMap { SentenceMatcher.bestSentence(forFragment: fragment, in: $0) }
        let quote = matched ?? fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        let annotation = Annotation(anchor: anchor, quote: quote, context: matched != nil ? fullResponse : nil)
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
