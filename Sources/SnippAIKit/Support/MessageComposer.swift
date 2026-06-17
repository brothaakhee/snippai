import Foundation

/// Builds the single-line text injected into the session: the user's message with
/// the screenshot file path(s) appended. Kept to ONE line so a live agent CLI
/// receives it as a single prompt (embedded newlines would submit prematurely).
/// Bare paths let Claude's Read tool ingest the PNGs without a native attachment.
///
/// Pure, so it's unit-testable. The single-screenshot wording is preserved exactly
/// for backward compatibility; multiple paths are comma-joined.
public func composeMessage(text: String, screenshots: [URL]) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ")
    guard !screenshots.isEmpty else { return trimmed }
    let paths = screenshots.map(\.path)

    if paths.count == 1 {
        let path = paths[0]
        return trimmed.isEmpty ? "Look at this screenshot: \(path)"
                               : "\(trimmed)  (screenshot: \(path))"
    }
    let joined = paths.joined(separator: ", ")
    return trimmed.isEmpty ? "Look at these screenshots: \(joined)"
                           : "\(trimmed)  (screenshots: \(joined))"
}
