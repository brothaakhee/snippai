import XCTest
import Foundation
@testable import SnippAIKit

final class HookInstallerTests: XCTestCase {
    private var tempDir: URL!
    private var settingsURL: URL!
    private var scriptURL: URL!
    private var installer: HookInstaller!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snippai-hooktest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        settingsURL = tempDir.appendingPathComponent(".claude/settings.json")
        scriptURL = tempDir.appendingPathComponent("snippai-hook.sh")
        installer = HookInstaller(
            settingsURL: settingsURL, scriptURL: scriptURL,
            socketURL: tempDir.appendingPathComponent("hooks.sock"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func commands(in root: [String: Any], event: String) -> [String] {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func testEnableCreatesFileWithBothHooks() throws {
        XCTAssertFalse(installer.isInstalled())
        try installer.enable()
        XCTAssertTrue(installer.isInstalled())

        let root = try readSettings()
        for event in HookInstaller.events {
            let cmds = commands(in: root, event: event)
            XCTAssertEqual(cmds.count, 1, "\(event) should have exactly one command")
            XCTAssertTrue(cmds[0].contains("snippai-hook.sh"))
            XCTAssertTrue(cmds[0].contains(event))
        }
        // The script is materialized + executable.
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scriptURL.path))
    }

    func testEnableIsIdempotent() throws {
        try installer.enable()
        let first = try Data(contentsOf: settingsURL)
        try installer.enable()   // second call must not duplicate
        let second = try Data(contentsOf: settingsURL)
        XCTAssertEqual(first, second, "re-enabling should not change the file")
        for event in HookInstaller.events {
            XCTAssertEqual(commands(in: try readSettings(), event: event).count, 1)
        }
    }

    func testEnableMergesAndPreservesExistingUserHooks() throws {
        // A user already has a Stop hook + an unrelated PreToolUse hook.
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "echo user-stop"]]]],
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "echo pre"]]]],
            ],
        ]
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        try installer.enable()
        let root = try readSettings()

        // Our entries were added…
        XCTAssertTrue(commands(in: root, event: "Stop").contains { $0.contains("snippai-hook.sh") })
        XCTAssertTrue(commands(in: root, event: "Notification").contains { $0.contains("snippai-hook.sh") })
        // …without clobbering the user's.
        XCTAssertTrue(commands(in: root, event: "Stop").contains("echo user-stop"))
        XCTAssertTrue(commands(in: root, event: "PreToolUse").contains("echo pre"))
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertEqual(commands(in: root, event: "Stop").count, 2)
    }

    func testDisableRemovesOnlyOurEntriesAndScript() throws {
        let existing: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "echo user-stop"]]]]],
        ]
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        try installer.enable()
        try installer.disable()

        let root = try readSettings()
        // The user's Stop hook survives; ours is gone; Notification (which we created) is pruned.
        XCTAssertEqual(commands(in: root, event: "Stop"), ["echo user-stop"])
        XCTAssertNil((root["hooks"] as? [String: Any])?["Notification"])
        XCTAssertFalse(installer.isInstalled())
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptURL.path))
    }

    func testEnableThenDisableOnEmptyStartRemovesHooksKey() throws {
        try installer.enable()
        try installer.disable()
        let root = try readSettings()
        // We created everything; disabling should leave no "hooks" key behind.
        XCTAssertNil(root["hooks"])
    }

    func testEnableBacksUpExistingFile() throws {
        let existing: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "echo x"]]]]]]
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        try installer.enable()

        let backups = try FileManager.default.contentsOfDirectory(atPath: settingsURL.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("settings.json.snippai-backup.") }
        XCTAssertEqual(backups.count, 1, "exactly one timestamped backup should exist")
    }
}
