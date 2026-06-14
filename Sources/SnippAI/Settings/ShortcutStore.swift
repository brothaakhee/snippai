import Foundation
import Observation

/// Single source of truth for the capture shortcut. Loads the persisted combo on
/// init, persists changes, and fires `onChange` so the app can re-register the
/// global hotkey live (no relaunch).
@MainActor
@Observable
final class ShortcutStore {
    private static let key = "captureShortcut"

    private(set) var combo: HotKey.KeyCombo {
        didSet { persist() }
    }

    /// Set by the app to re-register the global hotkey when the combo changes.
    /// Returns whether the new combo registered successfully.
    var onChange: ((HotKey.KeyCombo) -> Bool)?

    init() {
        self.combo = Self.load() ?? .defaultCombo
    }

    /// Applies a new combo (persisted via `didSet`) and re-registers the hotkey.
    /// Returns false — without committing — if the OS rejects the registration.
    @discardableResult
    func update(to newCombo: HotKey.KeyCombo) -> Bool {
        let previous = combo
        combo = newCombo
        if let onChange, onChange(newCombo) == false {
            combo = previous   // revert (re-registers the previous combo via the caller)
            _ = onChange(previous)
            return false
        }
        return true
    }

    func resetToDefault() {
        update(to: .defaultCombo)
    }

    var isDefault: Bool { combo == .defaultCombo }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private static func load() -> HotKey.KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let combo = try? JSONDecoder().decode(HotKey.KeyCombo.self, from: data),
              combo.hasRequiredModifier else { return nil }
        return combo
    }
}
