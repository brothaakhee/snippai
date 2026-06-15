import Foundation

/// The POSIX shell script Claude Code invokes on hook events. It is the *only*
/// executable in this integration (no compiled/signed binary — see spec rule #4):
/// it captures terminal identity from its inherited environment, base64-encodes
/// Claude's raw hook JSON (so the shell never parses/escapes it), and pushes one
/// JSON line to SnippAI's Unix socket.
///
/// Critical properties:
/// - **Fail-open / non-blocking:** delivery is backgrounded and the script always
///   `exit 0`, so Claude is never blocked or slowed even if SnippAI is down.
/// - **No external escaping needed:** every interpolated value is either a known
///   identity token (GUID, /dev/ttysN, tmux "%N", "iTerm.app") or base64 — none
///   can contain a `"` or `\`, so the hand-built JSON stays valid.
public enum HookScript {
    /// The script body. `\(socketPath)` is interpolated at install time so the
    /// path is fixed and space-safe regardless of the user's home directory.
    public static func source(socketPath: String) -> String {
        """
        #!/bin/sh
        # SnippAI hook bridge — auto-generated, do not edit.
        # Pushes a Claude Code hook event to the running SnippAI app over a Unix
        # socket. Always exits 0 (fail-open) so Claude is never blocked.
        SOCK='\(socketPath)'
        EVENT="${1:-unknown}"
        RAW=$(/usr/bin/base64 | /usr/bin/tr -d '\\n')
        T=$(/bin/ps -o tty= -p $$ 2>/dev/null | /usr/bin/tr -d ' ')
        if [ -n "$T" ] && [ "$T" != "??" ]; then TTY="/dev/$T"; else TTY=""; fi
        printf '{"v":1,"event":"%s","iterm":"%s","term_session":"%s","tmux_pane":"%s","tty":"%s","term_program":"%s","payload_b64":"%s"}\\n' \\
          "$EVENT" "${ITERM_SESSION_ID:-}" "${TERM_SESSION_ID:-}" "${TMUX_PANE:-}" "$TTY" "${TERM_PROGRAM:-}" "$RAW" \\
          | /usr/bin/nc -U -w 1 "$SOCK" >/dev/null 2>&1 &
        exit 0
        """
    }

    /// Marker substring present in every settings.json command we install, used to
    /// find and remove exactly our entries on uninstall.
    public static let commandMarker = "snippai-hook.sh"

    /// The settings.json command string for a given hook event.
    public static func command(scriptPath: String, event: String) -> String {
        "'\(scriptPath)' \(event)"
    }
}
