import AppKit
import SwiftUI

/// Hosts the onboarding window. Because SnippAI is an accessory (menu-bar) app,
/// it temporarily becomes a regular app while the window is open so the window
/// is properly focusable, then drops back to accessory on close.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = OnboardingModel()
    private var activationObserver: NSObjectProtocol?

    /// Supplies the current capture-shortcut glyphs for the "All set" footer line.
    var shortcutDisplayProvider: () -> String = { "⌥⇧4" }

    var isReady: Bool { model.snapshot.allReady }

    func show() {
        model.refresh()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)
        let hosting = NSHostingController(rootView: OnboardingView(model: model,
                                                                   shortcutDisplay: shortcutDisplayProvider(),
                                                                   onDone: { [weak self] in
            self?.close()
        }))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "Set up SnippAI"   // for Mission Control / window menu
        window.titleVisibility = .hidden  // custom header in the content instead
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.center()
        clampToScreen(window)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Re-check whenever the user returns to the app (e.g. after granting in
        // System Settings) so the checklist reflects reality without a manual poke.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.refresh() }
            }
    }

    func close() {
        window?.close()
    }

    /// Keeps the (content-sized) window within the visible screen so larger
    /// Dynamic Type can't push the footer/buttons off-screen.
    private func clampToScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size.height = min(frame.height, visible.height)
        frame.size.width = min(frame.width, visible.width)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Persist completion here — the chokepoint every dismissal path (Done button,
        // red traffic light, ⌘W) funnels through. Only when truly ready (a pending
        // relaunch is not ready, so the user is re-prompted next launch).
        if model.snapshot.allReady {
            UserDefaults.standard.set(true, forKey: OnboardingController.completedKey)
        }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - First-run policy

    static let completedKey = "didCompleteOnboarding"

    /// Shows onboarding on first run (or any run where setup is incomplete).
    /// If everything is already granted on first run, silently marks it complete.
    func showIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: OnboardingController.completedKey) { return }
        if PermissionsService.snapshot().allReady {
            defaults.set(true, forKey: OnboardingController.completedKey)
        } else {
            show()
        }
    }
}
