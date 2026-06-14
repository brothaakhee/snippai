import AppKit
import Observation

/// Captures the next key combination the user presses, while the Settings window is
/// active, via a local event monitor. Bare Escape cancels; a combo with no modifier
/// is reported so the UI can prompt for one (we keep listening). Swallows the events
/// so they don't act on the app while recording.
@MainActor
@Observable
final class ShortcutRecorder {
    private(set) var isRecording = false
    private var monitor: Any?
    private var onCapture: ((HotKey.KeyCombo) -> Void)?
    private var onCancel: (() -> Void)?

    func start(onCapture: @escaping (HotKey.KeyCombo) -> Void, onCancel: @escaping () -> Void) {
        guard !isRecording else { return }
        isRecording = true
        self.onCapture = onCapture
        self.onCancel = onCancel
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            // Bare Escape cancels recording (Escape + modifiers is a legal shortcut).
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                self.stop(); self.onCancel?()
                return nil
            }
            if let combo = HotKey.KeyCombo.from(event: event) {
                self.onCapture?(combo)
            }
            return nil   // swallow — don't let the keystroke act on the app
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        onCapture = nil
        onCancel = nil
    }
}
