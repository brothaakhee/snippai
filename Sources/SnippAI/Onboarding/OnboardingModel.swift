import AppKit
import SwiftUI
import Observation

/// Drives the onboarding window: holds the live permission snapshot and exposes
/// actions that refresh state afterward.
@MainActor
@Observable
final class OnboardingModel {
    /// Which page of the onboarding window is showing: the "How it works" intro or
    /// the permission checklist.
    enum Page { case welcome, checklist }
    var page: Page = .checklist

    var snapshot = PermissionsSnapshot()
    var automationError: String?
    var busyAction: String?
    /// Stray SnippAI bundles besides the running one — a permission granted to one of
    /// these wouldn't apply to the app the user is actually running.
    var duplicateCopies: [InstallGuard.StrayCopy] = []
    /// Outcome of the last removal attempt (nil = nothing to report).
    var duplicateStatus: String?
    /// True once the user tried granting Screen Recording this session — used to
    /// escalate the stale-grant repair from a footnote link to a real button when
    /// the grant visibly didn't take.
    var screenRecordingGrantAttempted = false

    /// Whether Screen Recording is granted but the app must relaunch to use it.
    var needsRelaunch: Bool { snapshot.screenRecording == .needsRelaunch }

    init() {
        refresh()
        refreshDuplicates()
    }

    func refresh() {
        snapshot = PermissionsService.snapshot()
        // Don't keep showing a stale error once access is actually granted.
        if snapshot.iTermAutomation == .granted { automationError = nil }
        // While the stray-copies banner is showing, re-scan on each refresh: the set
        // changes outside the app too (the user ejects the installer DMG or deletes a
        // copy in Finder), and a stale banner reads as "the button did nothing". With
        // no banner up there's nothing to live-update, so skip the LaunchServices query.
        if !duplicateCopies.isEmpty { refreshDuplicates() }
    }

    private func refreshDuplicates() {
        duplicateCopies = InstallGuard.otherCopies()
        if duplicateCopies.isEmpty { duplicateStatus = nil }
    }

    func grantScreenRecording() {
        // Prompt, and also deep-link to System Settings (covers the "previously
        // denied" case where the prompt no longer appears). The next snapshot
        // derives .granted / .needsRelaunch / .notDetermined from real preflight
        // state — no manual latch that could lie after a denial.
        screenRecordingGrantAttempted = true
        PermissionsService.requestScreenRecording()
        PermissionsService.openScreenRecordingSettings()
        refresh()
    }

    /// Leaves the intro for the permission checklist, remembering that the user has
    /// seen the walkthrough so it isn't forced again on later incomplete-setup launches.
    func advanceToChecklist() {
        UserDefaults.standard.set(true, forKey: OnboardingController.welcomeSeenKey)
        page = .checklist
    }

    /// Repairs a stale Screen Recording grant (Settings shows it on, but the app is
    /// denied because the binary was re-signed) by clearing the TCC decision and
    /// relaunching so a clean grant can bind to the current identity.
    func repairScreenRecording() {
        PermissionsService.resetScreenRecordingPermission()
        PermissionsService.relaunch()
    }

    /// Prompts for Accessibility (needed only to type into the Claude desktop app).
    /// Takes effect immediately for CGEvent — no relaunch required.
    func grantAccessibility() {
        PermissionsService.requestAccessibility()
        PermissionsService.openAccessibilitySettings()
        refresh()
    }

    func revealDuplicates() {
        guard !duplicateCopies.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(duplicateCopies.map(\.url))
    }

    func removeDuplicates() {
        guard busyAction == nil else { return }
        busyAction = "duplicates"
        duplicateStatus = nil
        Task {
            let problem = await InstallGuard.removeCopies(duplicateCopies)
            busyAction = nil
            refreshDuplicates()
            // On success the banner disappears — that's the feedback. A failure keeps
            // the banner up, so say why (a silent no-op reads as a broken button).
            duplicateStatus = problem
        }
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
