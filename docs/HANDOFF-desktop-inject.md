# HANDOFF — Desktop inject is the #1 feature. Make it work.

> Branch: `feat/claude-code-app` (NOT committed; `main` untouched). 89 tests green, build clean.
> Status: **mirror done for terminal + desktop; desktop INJECT not yet built — this is the priority.**
> User directive: "if you don't have inject into the Claude desktop app working, none of this branch
> has any point. That is the #1 feature we need."

---

## 1. The insight that makes desktop inject achievable (I had this wrong)

The Phase-0 recon rejected desktop inject (matrix avenue **D4**) on the **VM-sandbox path problem**:
"the desktop agent's cwd is a VM-sandboxed share, so a host screenshot is unreadable." **That is only
true for Cowork / `local-agent-mode` (VM) sessions.** It is **NOT true for the foreground desktop
session**, which the recon itself proved (avenue D1/D2) runs **on the host**:

- `ps eww` on the desktop's `claude` (pid 59287 earlier) → `HOME=/Users/hammad`, **no
  `CLAUDE_CONFIG_DIR`**, `CLAUDE_CODE_ENTRYPOINT=claude-desktop`, `--setting-sources=user,project,local`.
- `lsof` → **cwd is a REAL host path** (e.g. `/Users/hammad/pers/snippai`), and it writes its transcript
  to host `~/.claude/projects/.../<cliSessionId>.jsonl` — exactly like the terminal CLI.
- This very Claude Code session (`311d3889…`) IS that foreground desktop session.

**Consequences that reopen inject:**
1. A screenshot saved to host `/tmp` **is readable** by the foreground session — the agent's `Read`
   tool ingests it. So the SAME inject format SnippAI already uses for terminals works:
   `"<message>\nlook at this screenshot: /tmp/snippai-shot-<ts>.png"` → the agent reads the PNG.
   **No VM file-mapping, no image-paste-UI dependency required.**
2. "The open conversation" is the **foreground window** — unambiguous, not "blind across 116 sessions."

So the only real problem is **UI automation**: get the text into the desktop app's chat input and submit.

---

## 2. The mechanism to build

**Per-session targeting + inject:**
1. **Bring the chosen conversation to the foreground** via the URL scheme (verified in the matrix as a
   navigate-only focus primitive): `open "claude://chat/<cliSessionId>"`. The adapter already does this
   in `focus()`. `cliSessionId` is the `TerminalSession.id` for desktop sessions.
2. **Activate the app** so its window takes key focus. VERIFIED working:
   `osascript -e 'tell application "Claude" to activate'` reliably makes Claude frontmost AND switches
   to its Space (plain `NSRunningApplication.activate` / `open -a Claude` did NOT pull it out of a
   fullscreen-Space situation in testing — use the AppleScript `activate`, or `open` the URL which also
   activates).
3. **Focus the chat input.** The web content is opaque to Accessibility (README `ax_probe`: AXWebArea=0,
   0 text inputs), so you can't find the input via AX. Options, in order of robustness:
   - Click the input region by computing coordinates from the window bounds (input is the bottom strip
     of the Claude window; get bounds from `CGWindowListCopyWindowInfo` filtered to owner "Claude",
     the large `layer=3` window — see §4).
   - Many chat UIs auto-focus the input on window focus; test whether a paste lands without a click.
4. **Set the clipboard** to the composed text (message + host screenshot path). Use `NSPasteboard`.
   (Optionally ALSO put the PNG on the pasteboard to test native image-attach — but the host-path-in-text
   approach is the robust primary; don't depend on image paste.)
5. **Post `Cmd+V` then `Return`** via `CGEvent` (paste + submit). Requires **Accessibility TCC**.

**This is UI automation; it lives in the app layer (AppKit/CGEvent), NOT SnippAIKit** (which
deliberately avoids linking AppKit — see the comment in `TerminalAppAdapter`). See §3 for wiring.

---

## 3. Where to build it (architecture)

`ClaudeDesktopAdapter` is in **SnippAIKit** and currently `send()` THROWS `injectNotSupported`
(`Sources/SnippAIKit/Transcript/ClaudeDesktopAdapter.swift`). SnippAIKit can't do CGEvent/AppKit, so:

**Recommended:** add a `DesktopInjector` in the **SnippAI app target** (has AppKit) that does steps
2–5 above, and inject it into `ClaudeDesktopAdapter` as a closure at construction:

```swift
// SnippAIKit: ClaudeDesktopAdapter
public init(inject: (@Sendable (_ text: String, _ sessionID: String) async throws -> Void)? = nil)
// send(): if let inject { try await inject(text, sessionID) } else { throw .injectNotSupported }
```
Then in `AppModel.init` build the adapter with a closure that calls the app-layer `DesktopInjector`.
(Alternative: special-case desktop sessions in `AppModel.send()` and call `DesktopInjector` directly —
simpler but leaks adapter responsibility into AppModel.)

**Then flip the mirror-only gating that's currently in place:**
- `ClaudeDesktopAdapter.discover()` sets `supportsInject: false` → change to `true` once inject works.
- `AppModel.send()` has `guard selectedSession?.supportsInject != false` (defense) — fine to keep.
- `PanelView`: `canSend` checks `supportsInject != false`; `footer` shows "Mirror only — type in the
  Claude app". Remove/adjust these once desktop is injectable. (Search `supportsInject` across the repo.)
- `startComposing` skips the screen stream for `supportsInject != true` — desktop still has no terminal
  screen stream (mirror is transcript-driven), so KEEP that skip; gate it on `source == "Claude Desktop"`
  or a new `hasScreenStream` flag instead of `supportsInject` once desktop becomes injectable.

**Permissions:** add an Accessibility request to `Sources/SnippAI/Onboarding/PermissionsService.swift`
(today it handles Screen Recording). The stable "SnippAI Dev" signing identity makes the grant persist
across rebuilds (see `scripts/make_signing_cert.sh` and the memory note on dev signing).

---

## 4. Test recipe (prove the mechanism before/after building)

**Environment gotchas observed:**
- **Steam was frontmost in a fullscreen Space**, blocking computer-use from seeing Claude. Use
  `osascript -e 'tell application "Claude" to activate'` to pull Claude to the front + its Space.
- Claude is sometimes **windowless** (main window closed). `osascript activate` surfaced its existing
  window (id varied; the chat window is the large `layer=3` one, ~520×720, was at x≈1188). If truly no
  window, `Cmd+N` or clicking the dock icon creates one.
- The foreground desktop session is THIS conversation (`311d3889`). **Test in a NEW chat (`Cmd+N`)** so
  you don't pollute a working session, OR accept a self-referential test turn.

**Find the Claude chat window bounds (for click coordinates):**
```bash
swift /tmp/wins.swift   # (recreate: CGWindowListCopyWindowInfo, owner=="Claude", pick layer==3 large window)
```

**Put a PNG on the clipboard (to test native image attach):**
```bash
osascript -e 'set the clipboard to (read (POSIX file "/tmp/shot.png") as «class PNGf»)'
```

**Manual mechanism proof (computer-use, in a new chat):**
1. `osascript -e 'tell application "Claude" to activate'`
2. computer-use: click the input (bottom of the Claude window), `type` a test message that references a
   real host file, e.g. `what is in /Users/hammad/pers/snippai/Package.swift?`, press `Return`.
3. Confirm a user turn appears AND the agent reads the host file → proves host-path inject works for the
   foreground desktop session.
4. Repeat with `Cmd+V` of clipboard text (the actual shippable path) instead of `type`.

**SnippAI app run/verify harness (already wired):**
```bash
./scripts/build_app.sh release
# persist across calls (run_in_background) — direct backgrounding gets reaped:
SNIPPAI_AUTO_PANEL=1 ./build/SnippAI.app/Contents/MacOS/SnippAI
screencapture -x -o /tmp/s.png   # then crop with /tmp/crop.swift  <src> <dst> x y w h  (retina 3456x2234)
```
Debug env hooks (AppDelegate): `SNIPPAI_AUTO_PANEL=1`, `SNIPPAI_FORCE_PICKER=1`,
`SNIPPAI_MIRROR_TRANSCRIPT=<path>`. Pin a target: `defaults write com.snippai.app lastUsedSessionID <id>`
(delete it after). Bundle id `com.snippai.app`.

---

## 5. Key facts / paths

- **Desktop session registry:** `~/Library/Application Support/Claude/claude-code-sessions/<a>/<b>/local_*.json`
  → fields used: `cliSessionId` (== transcript id == `TerminalSession.id`), `originCwd`, `lastFocusedAt`
  (epoch ms), `isArchived`, `title`, `model`. (Do NOT use `local-agent-mode-sessions` — that's the dormant VM/Cowork class.)
- **Transcript path:** `~/.claude/projects/<slug(originCwd)>/<cliSessionId>.jsonl`, where
  `slug` maps every non-`[A-Za-z0-9]` char → `-` (verified: `/private/tmp/live_pr` → `-private-tmp-live-pr`).
- **Inject format (reuse terminal's):** see `Sources/SnippAIKit/Support/MessageComposer.swift` /
  `AppModel.composeMessage` — it already appends screenshot paths; the desktop injector should send the
  SAME composed string.
- **Why no other inject channel exists** (so don't re-chase): desktop `claude` stdin is an Electron-owned
  anonymous `socketpair()` (unaddressable); no host IPC port; CDP/`--inspect` fused off; `claude://` has
  an OAuth-only param allowlist (no prompt/image). Full detail: `docs/claude-code-feasibility-matrix.md`.
  UI automation (CGEvent paste) is the path. The ONE other lead is the native **Quick Entry** overlay
  (`Alt+Space`, `quickAccess.overlay.{toggle,setActiveChatId}`, native AppKit so possibly AX-drivable) —
  but it's **disabled by default** on this machine (no persisted pref); evaluate only if CGEvent-paste
  proves unreliable.

---

## 6. What's already built & verified (the mirror — keep it)

Native-chat **mirror** works for terminal AND desktop (renders transcript JSONL; verified rendering 3
real conversations in the running app). Files:
- SnippAIKit: `Transcript/TranscriptEvent.swift` (decoder), `TranscriptTailer.swift` (vnode tail),
  `TranscriptLocator.swift` (slug/cold-start), `ClaudeDesktopSessions.swift` (registry reader),
  `ClaudeDesktopAdapter.swift` (discovery + mirror-only send — **this is what you'll make inject**).
- SnippAI app: `Mirror/ConversationStore.swift`, `Mirror/TranscriptMirrorController.swift`
  (generation-guarded), `Mirror/ConversationMirrorView.swift` (native chat). Wired into `AppModel` +
  `PanelView` (mirror replaces the TUI mirror when a transcript is bound).
- Tests: `Tests/SnippAIKitTests/{TranscriptDecoder,TranscriptTailer,ClaudeDesktopSessions}Tests.swift`.
- Two bugs already caught by real-app runs + fixed: `TranscriptTailer.deinit` dispatch-deadlock (must
  NOT `queue.sync` in deinit — use `source?.cancel()`); cross-session event bleed (generation guard).

## 7. Definition of done

Capture a screenshot in SnippAI, pick the **desktop** session, type a message, hit send → the message
**appears in that desktop conversation** and the agent **reads the screenshot** — verified by a real-app
screenshot of the injected turn landing in the Claude desktop window. Then: adversarial review loop,
fix, re-verify. Update `docs/claude-code-app-goal.md` and flip the mirror-only UI.
