import Foundation

public enum HookInstallError: Error, LocalizedError {
    case settingsNotJSONObject
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .settingsNotJSONObject: return "~/.claude/settings.json isn't a JSON object — left untouched."
        case .writeFailed(let why): return "Couldn't update settings.json: \(why)"
        }
    }
}

/// Installs / removes SnippAI's Claude Code hooks by editing `settings.json`.
///
/// Safety contract (spec rule #3): always back up before writing, **merge** into
/// existing `hooks` arrays (never clobber), be idempotent, and remove exactly our
/// own entries on uninstall. No FileWatcher / self-heal / orphan cleanup.
public struct HookInstaller {
    /// Hook events SnippAI registers. Both are read-only/non-blocking signals.
    public static let events = ["Stop", "Notification"]

    public let settingsURL: URL
    public let scriptURL: URL
    public let socketURL: URL

    public init(settingsURL: URL? = nil,
                scriptURL: URL = HookPaths.script,
                socketURL: URL = HookPaths.socket) {
        self.settingsURL = settingsURL
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
        self.scriptURL = scriptURL
        self.socketURL = socketURL
    }

    // MARK: - Status

    /// True when every SnippAI hook event is already present in settings.json.
    public func isInstalled() -> Bool {
        guard let root = readSettings() else { return false }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return Self.events.allSatisfy { event in
            commandExists(in: hooks[event] as? [[String: Any]] ?? [])
        }
    }

    // MARK: - Enable

    /// Writes the hook script and merges our hook entries into settings.json.
    /// Idempotent: if everything is already present, nothing is written.
    public func enable() throws {
        try writeScript()

        var root = readSettings() ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for event in Self.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            if commandExists(in: groups) { continue }
            groups.append([
                "hooks": [[
                    "type": "command",
                    "command": HookScript.command(scriptPath: scriptURL.path, event: event),
                ]],
            ])
            hooks[event] = groups
            changed = true
        }

        guard changed else { return }   // already fully installed → no backup, no write
        root["hooks"] = hooks
        try backupThenWrite(root)
    }

    // MARK: - Disable

    /// Removes exactly SnippAI's hook entries, prunes emptied containers, and
    /// deletes the installed script. Restores settings.json toward its pre-install shape.
    public func disable() throws {
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        guard var root = readSettings(),
              var hooks = root["hooks"] as? [String: Any] else { return }

        var changed = false
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard var inner = group["hooks"] as? [[String: Any]] else { return group }
                let before = inner.count
                inner.removeAll { isOurs($0) }
                if inner.count == before { return group }      // untouched group
                changed = true
                if inner.isEmpty { return nil }                 // group emptied → drop it
                var g = group; g["hooks"] = inner; return g
            }
            groups = kept
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }

        guard changed else { return }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try backupThenWrite(root)
    }

    // MARK: - Helpers

    private func writeScript() throws {
        try HookPaths.ensureSupportDirectory()
        let body = HookScript.source(socketPath: socketURL.path)
        try body.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return obj as? [String: Any]
    }

    /// A command-hook entry is ours if its command references the SnippAI hook script.
    private func isOurs(_ entry: [String: Any]) -> Bool {
        let command = (entry["command"] as? String) ?? (entry["bash"] as? String) ?? ""
        return command.contains(HookScript.commandMarker)
    }

    private func commandExists(in groups: [[String: Any]]) -> Bool {
        groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains(where: isOurs)
        }
    }

    private func backupThenWrite(_ root: [String: Any]) throws {
        let fm = FileManager.default
        // Back up the current file (if any) before overwriting.
        if fm.fileExists(atPath: settingsURL.path) {
            let stamp = Self.timestamp()
            let backup = settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.json.snippai-backup.\(stamp)")
            try? fm.copyItem(at: settingsURL, to: backup)
        } else {
            try? fm.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            throw HookInstallError.writeFailed(error.localizedDescription)
        }
    }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
