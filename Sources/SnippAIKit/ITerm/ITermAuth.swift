import Foundation

/// Errors surfaced while obtaining iTerm2 API credentials.
public enum ITermAuthError: Error, LocalizedError {
    case notRunning
    case apiDisabled
    case denied(String)
    case malformedResponse(String)
    case appleScriptFailed(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "iTerm2 is not running."
        case .apiDisabled:
            return "iTerm2's Python API is disabled. Enable it in Settings → General → Magic → \"Enable Python API\"."
        case .denied(let reason):
            return "iTerm2 denied API access: \(reason)"
        case .malformedResponse(let raw):
            return "iTerm2 returned an unexpected authentication response: \(raw)"
        case .appleScriptFailed(let code, let message):
            return "AppleScript authentication failed (\(code)): \(message)"
        }
    }
}

/// A short-lived credential pair used to authenticate the WebSocket handshake.
public struct ITermCredentials: Sendable {
    public let cookie: String
    public let key: String
}

/// Obtains the iTerm2 API cookie + key.
///
/// Mirrors the reference Python client: it runs the AppleScript
/// `request cookie and key` command, which triggers iTerm2's one-time "Allow"
/// dialog on first use and returns a `"COOKIE KEY"` pair thereafter. Honours the
/// `ITERM2_COOKIE` / `ITERM2_KEY` environment variables when present (matching the
/// reference client) so the app can run inside an already-authorised context.
public enum ITermAuth {
    public static let advisoryName = "SnippAI"

    public static func obtain() throws -> ITermCredentials {
        if let cookie = ProcessInfo.processInfo.environment["ITERM2_COOKIE"],
           let key = ProcessInfo.processInfo.environment["ITERM2_KEY"] {
            return ITermCredentials(cookie: cookie, key: key)
        }
        // First confirm iTerm2 is actually running so we can give a precise error
        // instead of AppleScript silently launching it.
        guard isITermRunning() else { throw ITermAuthError.notRunning }

        let script = "tell application \"iTerm2\" to request cookie and key for app named \"\(advisoryName)\""
        let raw = try runAppleScript(script)
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ITermAuthError.malformedResponse(raw)
        }
        return ITermCredentials(cookie: parts[0], key: parts[1])
    }

    static func isITermRunning() -> Bool {
        let script = "if application \"iTerm2\" is running then\nreturn \"yes\"\nelse\nreturn \"no\"\nend if"
        return (try? runAppleScript(script)) == "yes"
    }

    /// Runs an AppleScript via the `osascript` CLI and returns the trimmed output.
    ///
    /// We deliberately shell out rather than use `NSAppleScript`: `NSAppleScript`
    /// must run on the main thread, but auth is invoked from the `ITermClient`
    /// actor's executor, where an off-main call can deadlock. Shelling out (as the
    /// reference Python client does) is thread-safe and deterministic.
    static func runAppleScript(_ source: String) throws -> String {
        do {
            return try AppleScript.run(source)
        } catch let AppleScriptError.scriptError(code, message) {
            // -2740/-2741 are the documented "iTerm2 too old" / disabled-API codes.
            if code == -2740 || code == -2741 { throw ITermAuthError.apiDisabled }
            // -1743 is errAEEventNotPermitted: the user denied Automation control.
            if code == -1743 {
                throw ITermAuthError.denied("SnippAI isn’t allowed to control iTerm2. Enable it in System Settings → Privacy & Security → Automation.")
            }
            throw ITermAuthError.appleScriptFailed(code: code, message: message)
        } catch let AppleScriptError.launchFailed(message) {
            throw ITermAuthError.appleScriptFailed(code: -1, message: message)
        }
    }
}
