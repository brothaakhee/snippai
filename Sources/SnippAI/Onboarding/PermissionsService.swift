import AppKit
import CoreGraphics
import SnippAIKit

/// State of a single permission, kept UI-agnostic.
enum PermissionState: Equatable {
    case granted
    case needsRelaunch     // granted this session, but the process must relaunch to use it
    case denied
    case notDetermined
    case blocked(String)   // a precondition isn't met (e.g. iTerm not running)
}

/// A non-prompting snapshot of everything SnippAI needs to function.
struct PermissionsSnapshot: Equatable {
    var screenRecording: PermissionState = .notDetermined
    var iTermRunning = false
    var iTermAPIEnabled = false
    var iTermAutomation: PermissionState = .notDetermined

    /// True when a capture + send can actually succeed end to end.
    var allReady: Bool {
        screenRecording == .granted && iTermRunning && iTermAPIEnabled && iTermAutomation == .granted
    }
}

/// Reads and requests the macOS permissions SnippAI depends on. All checks are
/// non-prompting so the onboarding UI can reflect real state without side effects.
enum PermissionsService {
    static let iTermBundleID = "com.googlecode.iterm2"

    /// Whether Screen Recording was already granted when this process started.
    /// A grant made *after* launch (in-app prompt or System Settings) doesn't reach
    /// ScreenCaptureKit until relaunch, so we must distinguish the two.
    static let grantedAtLaunch: Bool = CGPreflightScreenCaptureAccess()

    // MARK: - Non-prompting checks

    static func snapshot() -> PermissionsSnapshot {
        var s = PermissionsSnapshot()
        s.screenRecording = screenRecordingState()
        s.iTermRunning = isITermRunning()
        s.iTermAPIEnabled = isITermAPIEnabled()
        s.iTermAutomation = s.iTermRunning ? automationState() : .blocked("iTerm2 isn’t running")
        return s
    }

    /// Maps live preflight + the launch baseline to a state. A grant that appeared
    /// after launch is `.needsRelaunch`, never `.granted`.
    static func screenRecordingState() -> PermissionState {
        guard CGPreflightScreenCaptureAccess() else { return .notDetermined }
        return grantedAtLaunch ? .granted : .needsRelaunch
    }

    static func isITermRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == iTermBundleID }
    }

    /// Reads iTerm2's `EnableAPIServer` preference directly (fresh, uncached).
    static func isITermAPIEnabled() -> Bool {
        CFPreferencesAppSynchronize(iTermBundleID as CFString)
        let value = CFPreferencesCopyAppValue("EnableAPIServer" as CFString, iTermBundleID as CFString)
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
    }

    /// Whether we're allowed to send Apple Events to iTerm2 — without prompting.
    static func automationState() -> PermissionState {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: iTermBundleID).aeDesc else {
            return .notDetermined
        }
        let status = AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .blocked("iTerm2 isn’t running")
        default: return .notDetermined
        }
    }

    // MARK: - Actions

    /// Prompts for Screen Recording. Returns true if it was already granted; a
    /// fresh grant requires relaunching the app before ScreenCaptureKit works.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    // MARK: - Accessibility (for desktop-app inject via synthetic keystrokes)

    /// Whether SnippAI may post synthetic keystrokes (CGEvent) — required to inject
    /// into the Claude desktop app. Non-prompting.
    static func isAccessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    /// Surfaces the system Accessibility prompt (adds SnippAI to the list). The grant
    /// takes effect immediately once toggled on — no relaunch needed for CGEvent.
    @discardableResult
    static func requestAccessibility() -> Bool {
        // The literal key avoids the non-Sendable global `kAXTrustedCheckOptionPrompt`.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func launchITerm() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: iTermBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Polls (briefly) until iTerm2 is running, so the UI refreshes exactly when
    /// it's ready rather than after a guessed delay.
    static func waitForITerm(timeout: TimeInterval) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if isITermRunning() { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Triggers the one-time Automation consent dialog by actually requesting the
    /// iTerm cookie (the same call the live client makes). Returns nil on success,
    /// else a human-readable error.
    static func requestAutomation() async -> String? {
        do {
            _ = try ITermAuth.obtain()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Relaunches SnippAI (needed after a fresh Screen Recording grant).
    @MainActor
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}
