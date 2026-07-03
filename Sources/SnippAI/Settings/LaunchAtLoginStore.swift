import Foundation
import Observation
import ServiceManagement

/// Observable wrapper around `SMAppService.mainApp` for the Settings toggle.
/// A hotkey menu-bar utility that silently dies on reboot is a daily paper-cut,
/// so launch-at-login is offered as a first-class setting.
@MainActor
@Observable
final class LaunchAtLoginStore {
    private(set) var isEnabled: Bool
    /// User-facing note for the non-happy paths (approval pending, register failed).
    private(set) var statusMessage: String?

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            statusMessage = nil
        } catch {
            statusMessage = "Couldn’t update the login item: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        // The user may have previously denied SnippAI in System Settings — macOS then
        // parks a new registration as "requires approval" instead of enabling it.
        if on, status == .requiresApproval {
            statusMessage = "Approve SnippAI under System Settings → General → Login Items."
        }
    }

    /// Re-reads the live status — the user can flip the login item in System
    /// Settings while ours is open.
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
