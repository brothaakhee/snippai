# SnippAI

A native macOS app that collapses *"screenshot → cmd-tab to your terminal → paste the image → type → enter"* into **one step on one screen**, wired directly into a running Claude Code session.

> **Status:** **POC built and verified end-to-end.** A native Swift menu-bar app (SwiftPM, AppKit + SwiftUI) captures a screen region, lists live iTerm2 sessions with rich labels, mirrors the chosen session's screen, and sends `message + screenshot path` straight into it. The native iTerm tunnel, the ScreenCaptureKit capture, the crosshair overlay, the session picker, and the live mirror are each verified working (screenshots below). Build it with `./scripts/build_app.sh`.

---

## The idea

You're working on an app in a Claude Code session. You load the app in the browser, spot a UI bug, and take a screenshot. Today you then alt-tab back to your terminal, drag/paste the image in, and type "fix this." SnippAI replaces that whole dance: take the screenshot, and a panel appears right there to type your message and fire it — plus the screenshot — straight into the **existing** Claude session you were already working in. The response streams back in the same panel.

### Non-negotiables
**Fast · feels native · not buggy · perfect UI · perfect UX.**

---

## Architecture (locked)

### 1. Capture — we own it
Register our own global hotkey (can rebind ⌘⇧4), draw our own crosshair selection overlay (a transparent borderless `NSPanel`), and capture pixels via **ScreenCaptureKit**. We deliberately do **not** rely on the system screenshot + watching the save folder — that's racy and slow. Owning capture means the panel appears instantly with pixels already in hand.

- Permissions: Screen Recording (TCC). Accessibility only if later required.
- Shell: menu-bar app (`LSUIElement`, no dock icon). Swift + AppKit for the overlay/hotkey/panel; SwiftUI for panel content.

### 2. Integration strategy — augment, don't replace. **iTerm first.**
We keep the user's existing Claude session exactly where it is. We do **not** ask them to adopt a new terminal.

**Hard constraint (verified via Claude Code docs):** there is no supported way to inject into a live interactive `claude` we don't host — no socket/pipe/IPC, the Agent SDK can't attach, and a running session ignores external edits to its on-disk JSONL transcript. `--resume` always spawns a *new* process from saved state (the "split session" fork we must avoid). Channels / remote-control exist but are research-preview and cloud-routed — not for the POC.

The escape hatch is the terminal emulator's own API.

### 3. The tunnel — iTerm2's scripting API
iTerm2 exposes a local scripting API (protobuf over a websocket on a Unix socket) that lets an external process:
- **enumerate** every session (id + working directory + title) — feeds our picker,
- **send** text to a *specific* session by id,
- **stream** that session's screen contents back live (event-driven).

iTerm owns the PTY; our panel is just a second window onto the *same* live session — so there is **no split** and **no second process**. The user can type in our panel or in iTerm and both stay in sync.

- Setup gate: the user enables "Enable Python API" once (Settings → General → Magic) and approves a one-time permission dialog on first connect. This is the real onboarding friction, and it's small.

### 4. The panel — Flavor A: a faithful terminal mirror
The panel renders the chosen session's already-emulated screen cells (no VT100 emulator to build). It looks like Claude's TUI — spinners, redraws and all. The user types → Enter → we send `message + screenshot file path` (Claude's Read tool ingests the local PNG, so no native image attachment is needed) → they watch Claude work in the panel.

A cleaned-up native chat UI (Flavor B) was rejected for the POC: it requires parsing the unstable TUI, which is brittle. A real native-chat mode would require *hosting* the session (the "host model") and is the **v2 north star**, offered as a separate engine behind the same panel.

### 5. Overall shape — target picker + per-target adapters
The panel shows discoverable sessions; a router dispatches to a per-target delivery adapter:

| Adapter | Capability | Status |
|---|---|---|
| iTerm2 | enumerate + send + stream a specific session | ✅ verified, POC target |
| Terminal.app | AppleScript send/read | planned |
| Claude Code desktop app | needs hands-on Accessibility probe (are sessions individually addressable? does input accept a pasted image?) | open question |
| Hosted PTY | we own stdin/stdout; perfect targeting; enables Flavor B | v2 |

---

## Verified: the tunnel is real

A de-risking spike ([`spike_iterm.py`](./spike_iterm.py)) proved the full loop against a live iTerm, **all green**:

```
[PASS] ENUMERATE   7 live sessions, each with id + cwd + title
[PASS] SEND        injected "echo … look at /tmp/…png" into a chosen session
[PASS] STREAM      read it back live — round-trip 48ms
---> ALL GREEN — tunnel is real
```

- **48ms** send → execute → read-back, locally, event-driven — comfortably inside "feels instant."
- `iterm2` lib 2.20 works on Python 3.14.
- Confirmed gate: the iTerm2 Python API must be enabled + a one-time Allow dialog approved.

### Concrete finding that shapes the UI
On a real machine the spike found **5 sessions sharing one working directory, 4 of them with blank titles.** So the session picker **cannot disambiguate by cwd alone.** It will need richer labels — last-active time, the last on-screen line, window/tab position, or a small live screen-preview thumbnail.

---

## Open questions / decisions pending
1. ~~**iTerm client in the real app:** native Swift vs bundled Python.~~ **RESOLVED → native Swift, verified.** A native client (`Sources/SnippAIKit/ITerm/`) speaks the exact wire protocol — AppleScript cookie/key → WebSocket over iTerm2's **Unix domain socket** (`~/Library/Application Support/iTerm2/private/socket`) → SwiftProtobuf messages generated from a version-exact `proto/api.proto`. The Swift spike (`swift run iterm-spike`) is **ALL GREEN at 22ms round-trip** with **zero Python runtime** in the app. (Note: the protocol is served on the Unix socket, not TCP `:1912` as the reference lib's fallback URI implies; the native client connects to the socket directly.)
2. **Picker labeling** design, given the multi-session finding above.
3. **Claude Code desktop app** adapter viability — needs a hands-on Accessibility Inspector probe.

## What's built (POC)

A native Swift app, no Python runtime. `SnippAIKit` is the engine (iTerm client + protocol + models); `SnippAI` is the menu-bar app.

- **Native iTerm2 client** — AppleScript cookie/key → hand-rolled WebSocket (RFC 6455) over iTerm2's Unix domain socket → SwiftProtobuf messages generated from a version-exact `proto/api.proto`. Enumerate / send / stream / variables / activate. (`Sources/SnippAIKit/ITerm/`)
- **Capture** — Carbon global hotkey (default ⌥⌘4, no Accessibility needed) → full-screen crosshair overlay (dim + clear selection hole + live dimension badge) → ScreenCaptureKit region capture → PNG. Multi-display + retina aware. (`Sources/SnippAI/Capture/`)
- **Panel** (SwiftUI in a floating `NSPanel`) — screenshot header, **session picker** with rich disambiguating labels (folder · job · window/tab/pane · last on-screen line, agent sessions badged), a **live terminal mirror** that renders the session's emulated cells with ANSI colors + the cursor, and a message input. (`Sources/SnippAI/Panel/`)
- **Adapter abstraction** — `TargetAdapter` protocol (iTerm2 is the first impl) so Terminal.app / Claude desktop / hosted-PTY adapters slot in later.

### Build & run the app
```bash
./scripts/build_app.sh            # assembles + ad-hoc signs build/SnippAI.app
open build/SnippAI.app            # menu-bar icon appears; press ⌥⌘4 to capture
```
First run prompts for **Screen Recording** (capture) and **Automation → iTerm2** (the tunnel). iTerm2's Python API must be enabled once: Settings → General → Magic → "Enable Python API".

### Verifying without the GUI
```bash
swift run iterm-spike              # native enumerate/send/stream against live iTerm, ALL GREEN ~22ms
swift test                         # unit tests: RFC 6455 frame decoder + terminal-screen parser
```

## Remaining / next steps
- [ ] Hotkey rebinding UI + onboarding for the two TCC grants.
- [ ] Picker live screen-preview thumbnails (current labels already disambiguate).
- [ ] Terminal.app + Claude-desktop adapters (Accessibility probe for the latter).
- [ ] v2 "host model" (own the PTY) → enables the native-chat Flavor B.

---

## Repo contents
| Path | What |
|---|---|
| `README.md` | This document — current state, decisions, and verification. |
| `Package.swift`, `Sources/` | The native app: `SnippAIKit` (engine) + `SnippAI` (menu-bar app) + `iterm-spike` (native tunnel spike/diagnostic). |
| `proto/api.proto` | Version-exact iTerm2 API schema, reconstructed offline from the installed `iterm2` lib by `tools/extract_proto.py`. |
| `scripts/build_app.sh` | Assembles and ad-hoc-signs `SnippAI.app`. |
| `spike_iterm.py` | The original Python de-risking spike (kept for reference). Safe — reads existing sessions; runs its send/stream test in a throwaway window it closes. |
