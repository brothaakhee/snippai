import AppKit
import CoreGraphics
import SnippAIKit

enum DesktopInjectError: Error, LocalizedError {
    case notRunning
    case notTrusted
    case didNotFocus

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "The Claude desktop app isn’t running."
        case .notTrusted:
            return "SnippAI needs Accessibility access to send into the Claude app. Enable it in System Settings → Privacy & Security → Accessibility."
        case .didNotFocus:
            return "Couldn’t bring the Claude conversation to the front."
        }
    }
}

/// Drives the Claude desktop app's chat input via UI automation — the only viable
/// inject path (its stdin is an Electron-owned socketpair; web content is opaque to
/// Accessibility). Recipe, proven against the live app:
///   focus the conversation (URL scheme) → activate → set clipboard → ⌘V → Return.
/// The input auto-focuses on window focus, so no click/coordinate guessing is needed.
/// The injected text carries the host screenshot path; the desktop session runs on
/// the host, so its Read tool ingests the PNG — same format SnippAI uses for terminals.
@MainActor
enum DesktopInjector {
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// The closure handed to `ClaudeDesktopAdapter` at construction.
    static func make() -> DesktopInject {
        { text, sessionID in try await inject(text: text, sessionID: sessionID) }
    }

    static func inject(text: String, sessionID: String) async throws {
        // Accessibility is required to post the synthetic ⌘V/Return. If it's missing,
        // guide the user right here (system prompt + deep-link) instead of failing mute.
        guard PermissionsService.isAccessibilityTrusted() else {
            PermissionsService.requestAccessibility()
            PermissionsService.openAccessibilitySettings()
            throw DesktopInjectError.notTrusted
        }
        guard let claude = NSRunningApplication
            .runningApplications(withBundleIdentifier: claudeBundleID).first
        else { throw DesktopInjectError.notRunning }

        // 1. Focus the conversation (navigates + activates the app).
        let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
        if let url = URL(string: "claude://chat/\(encoded)") {
            NSWorkspace.shared.open(url)
        }

        // 2. Make sure Claude is frontmost (it can sit in another Space / fullscreen).
        if !(await waitUntilFrontmost(timeout: 1.2)) {
            claude.activate(options: [.activateAllWindows])
            activateViaAppleScript()
            if !(await waitUntilFrontmost(timeout: 1.0)) { throw DesktopInjectError.didNotFocus }
        }
        // Let the chat input take key focus before pasting.
        try? await Task.sleep(nanoseconds: 250_000_000)

        // 3. Re-verify Claude is STILL frontmost immediately before synthesizing keys.
        // CGEvent posts to the system foreground (not a targeted window), so if focus
        // shifted during activation/settle (⌘-Tab, an alert stealing focus, a crash),
        // ⌘V+Return would land in the wrong app. Bail instead — before touching the
        // clipboard, so the user's clipboard is never even disturbed on this path.
        guard frontmostIsClaude() else { throw DesktopInjectError.didNotFocus }

        // 4. Clipboard: snapshot the user's, set ours, paste, submit, then restore.
        let pasteboard = NSPasteboard.general
        let saved = snapshotPasteboard()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postKey(0x09, command: true)   // ⌘V
        try? await Task.sleep(nanoseconds: 120_000_000)
        // Re-check before Return too: focus could shift in the inter-key gap, and a
        // stray Return in another app is the worst stray keypress. If it shifted, the
        // paste already landed in Claude (harmless); just skip the submit + restore.
        guard frontmostIsClaude() else { restorePasteboard(saved); throw DesktopInjectError.didNotFocus }
        postKey(0x24, command: false)  // Return (submit)

        // Restore after the paste has consumed the clipboard.
        try? await Task.sleep(nanoseconds: 450_000_000)
        restorePasteboard(saved)
    }

    // MARK: - Focus helpers

    private static func frontmostIsClaude() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID
    }

    private static func waitUntilFrontmost(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if frontmostIsClaude() { return true }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        return frontmostIsClaude()
    }

    /// AppleScript `activate` reliably pulls Claude out of a fullscreen Space when
    /// `NSRunningApplication.activate` alone doesn't (observed in testing). Fire-and-
    /// forget — never `waitUntilExit()` here: this runs on the main actor and the
    /// caller already polls `waitUntilFrontmost` for the result, so blocking would
    /// just freeze the UI for the subprocess's lifetime.
    private static func activateViaAppleScript() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application id \"\(claudeBundleID)\" to activate"]
        try? process.run()
    }

    // MARK: - Synthetic keys (requires Accessibility)

    private static func postKey(_ keyCode: CGKeyCode, command: Bool) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        if command { down?.flags = .maskCommand; up?.flags = .maskCommand }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Clipboard preservation

    private static func snapshotPasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { dict[type] = data } }
            return dict
        }
    }

    private static func restorePasteboard(_ snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = snapshot.compactMap { dict -> NSPasteboardItem? in
            guard !dict.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
