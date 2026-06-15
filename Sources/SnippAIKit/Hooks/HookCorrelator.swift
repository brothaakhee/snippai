import Foundation

/// Maps an incoming `HookFrame` to the session it belongs to. Pure and testable.
///
/// Precedence (spec): iTerm GUID (ground truth — `TerminalSession.id`) → tty match
/// → drop. Correlating against *known* identities (not just currently-listed
/// sessions) lets the menu-bar badge work while the panel is closed, while still
/// refusing frames that don't match any real session we've seen (anti-spoof).
public enum HookCorrelator {
    public static func sessionID(
        for frame: HookFrame,
        knownIDs: Set<String>,
        ttyToID: [String: String]
    ) -> String? {
        if let guid = frame.itermSessionGUID, knownIDs.contains(guid) {
            return guid
        }
        if let tty = frame.tty, !tty.isEmpty, let id = ttyToID[tty] {
            return id
        }
        return nil
    }
}
