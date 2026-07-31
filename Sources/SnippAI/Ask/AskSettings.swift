import Foundation
import Observation
import SnippAIKit

/// The Ask feature flag + availability, shared by the Settings toggle and the
/// ⌥⇧A hotkey binding. The actual ask experience is the in-place overlay
/// annotator (`AnnotationOverlayController`); this type is just the switch.
@MainActor
@Observable
final class AskSettings {
    /// Fired on enable/disable so the app can claim/release the global hotkey —
    /// a disabled feature must not keep swallowing ⌥⇧A system-wide.
    var onEnabledChange: (() -> Void)?

    /// Kill switch (Settings). Default on — the feature no-ops anyway when the
    /// `claude` CLI isn't installed.
    private(set) var isEnabled: Bool =
        UserDefaults.standard.object(forKey: AskSettings.enabledKey) as? Bool ?? true

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        onEnabledChange?()
    }
    private static let enabledKey = "ask.enabled"

    /// Whether the `claude` CLI is installed (Ask answers via a one-off session).
    static var claudeAvailable: Bool { ClaudeOneShot.binaryPath() != nil }
}
