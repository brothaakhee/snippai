import XCTest
@testable import SnippAIKit

final class AgentProbeTests: XCTestCase {
    func testAgentInvocationsMatch() {
        XCTAssertTrue(AgentProbe.commandLooksLikeAgent("claude"))
        XCTAssertTrue(AgentProbe.commandLooksLikeAgent("claude --resume abc123"))
        XCTAssertTrue(AgentProbe.commandLooksLikeAgent("/usr/local/Caskroom/claude-code@latest/2.1.196/claude --session-id x"))
        XCTAssertTrue(AgentProbe.commandLooksLikeAgent("node /usr/local/bin/claude"))
        XCTAssertTrue(AgentProbe.commandLooksLikeAgent("python3 /opt/aider/aider --model foo"))
        XCTAssertTrue(AgentProbe.commandLooksLikeAgent("CLAUDE"))   // case-insensitive
    }

    func testChildProcessesDoNotMatch() {
        // The real false positive: Claude foregrounded the Swift LSP in its pane.
        XCTAssertFalse(AgentProbe.commandLooksLikeAgent("sourcekit-lsp"))
        XCTAssertFalse(AgentProbe.commandLooksLikeAgent("/usr/bin/sourcekit-lsp --stdio"))
        XCTAssertFalse(AgentProbe.commandLooksLikeAgent("swift build -c release"))
        XCTAssertFalse(AgentProbe.commandLooksLikeAgent("-zsh"))
        XCTAssertFalse(AgentProbe.commandLooksLikeAgent("node server.js"))
    }

    func testAgentNameInsideArgumentsDoesNotMatch() {
        // Only a token's basename counts — a mention inside a filename must not.
        XCTAssertFalse(AgentProbe.commandLooksLikeAgent("vim claude-notes.md"))
        XCTAssertFalse(AgentProbe.commandLooksLikeAgent("tail -f claude.log"))
        XCTAssertFalse(AgentProbe.commandLooksLikeAgent("git commit -m add-claude-support"))
    }

    func testFilenameThatIsExactlyAnAgentName() {
        // Basename-of-token matching accepts "…/claude" wherever it appears; a bare
        // argument literally named "claude" is indistinguishable and acceptable.
        XCTAssertTrue(AgentProbe.commandLooksLikeAgent("less /docs/claude"))
    }

    func testAgentAliveRejectsDetachedAndEmptyTTYs() {
        // Detached processes (tty "??") must never count, whatever is running.
        XCTAssertFalse(AgentProbe.agentAlive(onTTY: "??"))
        XCTAssertFalse(AgentProbe.agentAlive(onTTY: ""))
    }
}
