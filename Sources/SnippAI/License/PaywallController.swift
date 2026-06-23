import AppKit
import SwiftUI

/// Hosts the paywall window. Like the onboarding window, the accessory app briefly
/// becomes regular so the window is focusable. Resolves with whether the in-flight
/// capture should proceed: activation and "Maybe later" both proceed; closing the
/// window cancels (no capture, no deferral spent).
@MainActor
final class PaywallController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onResolve: ((Bool) -> Void)?
    private var resolved = false

    func show(store: LicenseStore, canDefer: Bool, onResolve: @escaping (Bool) -> Void) {
        // If a paywall is somehow already open, cancel the prior request cleanly.
        if window != nil { resolve(false) }
        self.onResolve = onResolve
        self.resolved = false

        let view = PaywallView(
            store: store,
            canDefer: canDefer,
            onActivated: { [weak self] in self?.resolve(true) },
            onLater: { [weak self] in
                guard let self else { return }
                if store.recordDeferral() { self.resolve(true) } else { self.resolve(false) }
            }
        )

        NSApp.setActivationPolicy(.regular)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "Unlock SnippAI"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resolve(_ proceed: Bool) {
        guard !resolved else { return }
        resolved = true
        let callback = onResolve
        onResolve = nil
        window?.close()   // triggers windowWillClose, but `resolved` guards re-entry
        window = nil
        NSApp.setActivationPolicy(.accessory)
        callback?(proceed)
    }

    func windowWillClose(_ notification: Notification) {
        // User clicked the close button without choosing — cancel the capture.
        resolve(false)
    }
}
