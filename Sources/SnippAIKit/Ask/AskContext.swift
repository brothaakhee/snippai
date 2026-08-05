import Foundation

/// Builds the "explain this" prompt: the highlighted text plus (when available)
/// the tail of the conversation it appeared in — so the answer covers both what
/// the term means AND why it was said there, like asking the person who said it.
public enum AskContext {

    /// Every assistant message's plain text from a Claude Code transcript JSONL, in
    /// order (oldest→newest). The one place that reads + decodes the transcript.
    static func assistantMessages(transcriptPath: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: transcriptPath),
              let content = String(data: data, encoding: .utf8) else { return [] }
        var messages: [String] = []
        for line in content.split(separator: "\n") {
            guard let event = TranscriptDecoder.decode(line: Data(line.utf8)),
                  event.role == .assistant else { continue }
            let text = event.blocks.compactMap { block -> String? in
                if case .text(let t) = block { return t }
                return nil
            }.joined(separator: "\n")
            if !text.isEmpty { messages.append(text) }
        }
        return messages
    }

    /// The last assistant message's plain text, truncated from the FRONT (the
    /// highlighted term is almost always in the tail — that's what the user read).
    public static func lastAssistantText(transcriptPath: String, maxLength: Int) -> String? {
        truncatedTail(assistantMessages(transcriptPath: transcriptPath).suffix(1), maxLength: maxLength)
    }

    /// The last `count` assistant messages concatenated (oldest→newest), truncated
    /// from the FRONT to `maxLength`. Matching/attaching a few recent messages — not
    /// just the final one — lets Ask resolve even when the user points a little
    /// further up the answer they're reading.
    public static func recentAssistantText(transcriptPath: String, count: Int = 4, maxLength: Int) -> String? {
        truncatedTail(assistantMessages(transcriptPath: transcriptPath).suffix(count), maxLength: maxLength)
    }

    private static func truncatedTail(_ messages: ArraySlice<String>, maxLength: Int) -> String? {
        guard !messages.isEmpty else { return nil }
        let joined = messages.joined(separator: "\n\n")
        return joined.count > maxLength ? "…" + String(joined.suffix(maxLength)) : joined
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
