import Foundation

/// Maps a noisy OCR/selection fragment of what the user pointed at back to the
/// exact sentence in the full response — so the anchor quote is the real text,
/// not the OCR's mangled guess. Character-bigram (Dice) overlap, which shrugs off
/// the common OCR errors (l↔1, rn↔m, dropped punctuation, case) without needing a
/// full edit-distance pass over a long response.
public enum SentenceMatcher {
    /// The best-matching sentence in `text` for `fragment`, or nil when nothing
    /// overlaps enough to trust (so an unrelated fragment doesn't force an anchor).
    ///
    /// Scored by CONTAINMENT — how much of the fragment's character bigrams appear
    /// in the sentence — because the user typically points at a *piece* of a
    /// sentence, and a short pointer into a long sentence scores near-zero on
    /// symmetric similarity. A minimum fragment length keeps a trivial pointer
    /// ("the") from matching everything. On a tie, the shorter sentence wins (the
    /// tightest sentence that fully contains the pointer).
    public static func bestSentence(forFragment fragment: String, in text: String, minScore: Double = 0.6) -> String? {
        let needle = bigrams(of: fragment)
        guard needle.count >= 5 else { return nil }   // ~≥6 alphanumeric chars

        var best: (sentence: String, score: Double, length: Int)?
        for sentence in sentences(in: text) {
            let score = containment(needle, in: bigrams(of: sentence))
            let length = sentence.count
            if let b = best, !(score > b.score || (score == b.score && length < b.length)) { continue }
            best = (sentence, score, length)
        }
        guard let best, best.score >= minScore else { return nil }
        return best.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The clean sentence anchor for what the user pointed at, or — when no
    /// sentence matches confidently — the raw fragment itself (trimmed). Either
    /// way the caller has *something* to tell Claude "they're asking about this",
    /// with the full response supplying the real context.
    public static func anchor(forFragment fragment: String, in text: String) -> String {
        bestSentence(forFragment: fragment, in: text)
            ?? fragment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits into sentences on terminal punctuation + newlines, keeping only
    /// non-trivial ones.
    static func sentences(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count > 3 { out.append(t) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.count > 3 { out.append(tail) }
        return out
    }

    /// Normalized character bigrams: lowercased, letters/digits only (so
    /// punctuation and spacing differences don't cost anything).
    private static func bigrams(of s: String) -> Set<String> {
        let cleaned = s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let chars = Array(String(String.UnicodeScalarView(cleaned)))
        guard chars.count >= 2 else { return [] }
        var grams = Set<String>()
        for i in 0..<(chars.count - 1) { grams.insert(String(chars[i...i+1])) }
        return grams
    }

    /// Fraction of the needle's bigrams present in the haystack (0…1).
    private static func containment(_ needle: Set<String>, in haystack: Set<String>) -> Double {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        return Double(needle.intersection(haystack).count) / Double(needle.count)
    }
}
