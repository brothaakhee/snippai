import SwiftUI
import Observation

/// Drives the onboarding window: holds the live permission snapshot and exposes
/// actions that refresh state afterward.
@MainActor
@Observable
final class OnboardingModel {
    var snapshot = PermissionsSnapshot()
    var automationError: String?
    var busyAction: String?

    /// Whether Screen Recording is granted but the app must relaunch to use it.
    var needsRelaunch: Bool { snapshot.screenRecording == .needsRelaunch }

    init() { refresh() }

    func refresh() {
        snapshot = PermissionsService.snapshot()
        // Don't keep showing a stale error once access is actually granted.
        if snapshot.iTermAutomation == .granted { automationError = nil }
    }

    func grantScreenRecording() {
        // Prompt, and also deep-link to System Settings (covers the "previously
        // denied" case where the prompt no longer appears). The next snapshot
        // derives .granted / .needsRelaunch / .notDetermined from real preflight
        // state — no manual latch that could lie after a denial.
        PermissionsService.requestScreenRecording()
        PermissionsService.openScreenRecordingSettings()
        refresh()
    }

    func launchITerm() {
        guard busyAction != "iterm" else { return }
        busyAction = "iterm"
        PermissionsService.launchITerm()
        // Refresh once iTerm actually finishes launching (fall back to a timeout).
        Task {
            await PermissionsService.waitForITerm(timeout: 5)
            busyAction = nil
            refresh()
        }
    }

    func openITermSettings() {
        PermissionsService.launchITerm()
        Task { try? await Task.sleep(nanoseconds: 800_000_000); refresh() }
    }

    func grantAutomation() {
        guard busyAction == nil else { return }
        busyAction = "automation"
        automationError = nil
        Task {
            let error = await PermissionsService.requestAutomation()
            busyAction = nil
            automationError = error
            refresh()
        }
    }

    func openAutomationSettings() {
        PermissionsService.openAutomationSettings()
    }

    func relaunch() {
        PermissionsService.relaunch()
    }
}
