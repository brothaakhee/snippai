import Foundation

/// Canonical on-disk locations for the hook bridge. Everything lives under
/// `~/Library/Application Support/SnippAI/`, created owner-only (0700) so the
/// Unix socket's only at-rest "auth" is filesystem permissions (POC-grade,
/// documented as not spoof-hardened in the spec).
public enum HookPaths {
    /// The SnippAI support directory (`~/Library/Application Support/SnippAI`).
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SnippAI", isDirectory: true)
    }

    /// The AF_UNIX socket the hook script connects to.
    public static var socket: URL { supportDirectory.appendingPathComponent("hooks.sock") }

    /// The installed hook shell script invoked by Claude Code's command hooks.
    public static var script: URL { supportDirectory.appendingPathComponent("snippai-hook.sh") }

    /// Creates the support directory if needed, with 0700 permissions.
    /// Returns the directory URL. Throws if it can't be created.
    @discardableResult
    public static func ensureSupportDirectory() throws -> URL {
        let dir = supportDirectory
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // createDirectory only applies attributes to dirs it creates; re-assert on an
        // existing dir so a previously-loose directory is tightened.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }
}
