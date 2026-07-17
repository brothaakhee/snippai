import Foundation

/// Builds the "explain this" prompt: the highlighted text plus (when available)
/// the tail of the conversation it appeared in — so the answer covers both what
/// the term means AND why it was said there, like asking the person who said it.
public enum AskContext {

    /// The last assistant message's plain text from a Claude Code transcript
    /// JSONL, truncated from the FRONT (the highlighted term is almost always in
    /// the tail — that's what the user just read).
    public static func lastAssistantText(transcriptPath: String, maxLength: Int) -> String? {
        guard let data = FileManager.default.contents(atPath: transcriptPath),
              let content = String(data: data, encoding: .utf8) else { return nil }
        var last: String?
        for line in content.split(separator: "\n") {
            guard let event = TranscriptDecoder.decode(line: Data(line.utf8)),
                  event.role == .assistant else { continue }
            let text = event.blocks.compactMap { block -> String? in
                if case .text(let t) = block { return t }
                return nil
            }.joined(separator: "\n")
            if !text.isEmpty { last = text }
        }
        guard var text = last else { return nil }
        if text.count > maxLength {
            text = "…" + String(text.suffix(maxLength))
        }
        return text
    }

    /// The transcript context, but ONLY when the highlighted text actually appears
    /// in it — the last-used-session heuristic attaches this regardless of where the
    /// selection came from, so without this guard a phrase highlighted in a browser
    /// would be falsely framed as "from that Claude message". Returns nil when the
    /// selection isn't found (or there's no transcript), so the prompt stays honest.
    public static func contextIfRelevant(highlighted: String, transcriptPath: String?, maxLength: Int) -> String? {
        guard let path = transcriptPath,
              let text = lastAssistantText(transcriptPath: path, maxLength: maxLength) else { return nil }
        let needle = highlighted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, text.localizedCaseInsensitiveContains(needle) else { return nil }
        return text
    }

    /// The one-shot prompt. Keep it boring and directive: brief answer, own
    /// knowledge only (belt-and-braces with the CLI's tool ban), then stop.
    /// `question` is the user's own words (spoken or typed); nil falls back to
    /// the canned "explain this" — the two never appear together.
    public static func prompt(question: String?, highlighted: String, context: String?) -> String {
        var p = ""
        if let context, !context.isEmpty {
            p += """
            In the conversation below, an AI assistant wrote this (conversation below is \
            the tail of its last message):

            ---
            \(context)
            ---

            """
        }
        p += """
        The user highlighted this text\(context != nil ? " from that message" : " on their screen"):

        "\(highlighted)"

        """
        if let question, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            p += "Their question about it: \(question)\n\nAnswer that question briefly (a few sentences)"
        } else {
            p += "Briefly explain what it means\(context != nil ? " and why it was used in that context" : ""). 2-4 sentences"
        }
        // One constraint sentence for both paths.
        p += ", then stop. Answer from your own knowledge only — do not use any tools."
        return p
    }
}
