import Foundation

/// Wrap-around index helper for cycling a selection through a list in either
/// direction. Pure (and so unit-testable) — the UI layer owns the list and the
/// keyboard mapping; this just does the modular arithmetic correctly for negative
/// deltas, which Swift's `%` does not on its own.
public func cycledIndex(from current: Int, by delta: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return ((current + delta) % count + count) % count
}
