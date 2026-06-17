import Foundation

/// Wrap-around index helper for cycling a selection through a list in either
/// direction. Pure (and so unit-testable) — the UI layer owns the list and the
/// keyboard mapping; this just does the modular arithmetic correctly for negative
/// deltas, which Swift's `%` does not on its own.
public func cycledIndex(from current: Int, by delta: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return ((current + delta) % count + count) % count
}

/// Maps a key event to a target-cycle direction: +1 (next) for →/↓, -1 (prev) for
/// ←/↑, or nil if it isn't a bare ⌘+arrow. Pure (testable) and deliberately ignores
/// the `.function`/`.numericPad` flags macOS sets on arrow keys — comparing the full
/// modifier mask to exactly `.command` fails because arrows also carry `.function`.
/// Returns nil when ⌥/⌃/⇧ are also held so word/line caret motion still works.
public func targetCycleDelta(keyCode: Int, command: Bool, option: Bool, control: Bool, shift: Bool) -> Int? {
    guard command, !option, !control, !shift else { return nil }
    switch keyCode {
    case 124, 125: return 1    // kVK_RightArrow, kVK_DownArrow  → next
    case 123, 126: return -1   // kVK_LeftArrow,  kVK_UpArrow    → previous
    default: return nil
    }
}
