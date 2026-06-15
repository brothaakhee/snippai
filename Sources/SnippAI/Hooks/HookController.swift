import Foundation
import SnippAIKit
import Observation

/// Owns the opt-in Claude Code status integration: the Unix-socket listener, the
/// settings.json installer, and the persisted on/off preference. Default OFF.
///
/// All edits to the user's `~/.claude/settings.json` go through `HookInstaller`
/// (backup + merge + idempotent + reversible). The listener feeds decoded frames
/// to `AppModel` on the main actor.
@MainActor
@Observable
final class HookController {
    private let model: AppModel
    private let installer = HookInstaller()
    private var server: HookSocketServer?
    private static let enabledKey = "claudeStatusHooksEnabled"

    /// User-facing result of the last enable/disable, surfaced in Settings.
    var statusMessage: String?
    var statusIsWarning = false

    private(set) var isEnabled: Bool

    init(model: AppModel) {
        self.model = model
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Call once at launch: if the user previously enabled the integration, bring the
    /// listener back up and re-assert the (consented) hooks, then seed identities so
    /// the menu-bar badge can light up before the panel is first opened.
    func startIfEnabled() {
        guard isEnabled else { return }
        do {
            try startServer()
            try installer.enable()   // idempotent; repairs a partial prior install
            Task { await model.seedIdentities() }
        } catch {
            report(error, enabling: true)
            isEnabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
        }
    }

    /// Toggles the integration. On any failure the requested state is rolled back so
    /// the UI never shows "on" while the socket/hooks aren't actually wired.
    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        if on {
            do {
                try startServer()
                try installer.enable()
                Task { await model.seedIdentities() }
                persist(true)
                statusMessage = "Claude Code status enabled. Backed up settings.json before editing."
                statusIsWarning = false
            } catch {
                stopServer()
                try? installer.disable()
                report(error, enabling: true)
            }
        } else {
            stopServer()
            do {
                try installer.disable()
                persist(false)
                statusMessage = "Disabled. Removed SnippAI's hooks from settings.json."
                statusIsWarning = false
            } catch {
                report(error, enabling: false)
                // Listener is already down; reflect off regardless so we don't strand the UI "on".
                persist(false)
            }
        }
    }

    // MARK: - Private

    private func startServer() throws {
        guard server == nil else { return }
        let server = HookSocketServer { [weak self] frame in
            // Hop from the socket's background queue onto the main actor.
            Task { @MainActor in self?.model.applyHookFrame(frame) }
        }
        try server.start()
        self.server = server
    }

    private func stopServer() {
        server?.stop()
        server = nil
    }

    private func persist(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
    }

    private func report(_ error: Error, enabling: Bool) {
        let verb = enabling ? "enable" : "disable"
        statusMessage = "Couldn't \(verb): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        statusIsWarning = true
    }
}
