import AppKit
import SwiftUI

/// Hosts the Settings window. Like onboarding, SnippAI is an accessory app, so it
/// temporarily becomes a regular app while the window is open (so the window — and
/// the shortcut recorder's local key monitor — can receive key events), then drops
/// back to accessory on close.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: ShortcutStore
    private let hooks: HookController
    private let license: LicenseStore
    private let launchAtLogin: LaunchAtLoginStore
    private let voice: VoiceController
    private let ask: AskSettings

    init(store: ShortcutStore, hooks: HookController, license: LicenseStore,
         launchAtLogin: LaunchAtLoginStore, voice: VoiceController, ask: AskSettings) {
        self.store = store
        self.hooks = hooks
        self.license = license
        self.launchAtLogin = launchAtLogin
        self.voice = voice
        self.ask = ask
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.setActivationPolicy(.regular)
        let hosting = NSHostingController(rootView: SettingsView(store: store, hooks: hooks, license: license, launchAtLogin: launchAtLogin, voice: voice, ask: ask, onDone: { [weak self] in
            self?.close()
        }))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "SnippAI Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Whether the Settings window is currently open — the hotkey watchdog pauses
    /// while it is, so a re-assert can't fight the shortcut recorder (which needs
    /// the combo released while listening for a new one).
    var isOpen: Bool { window != nil }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
