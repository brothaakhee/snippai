# GOAL: SnippAI drives Claude Code wherever it runs

> Branch: `feat/claude-code-app`. Stable POC stays on `main`.

## North star

A SnippAI version with two must-have flows working **smoothly**, against Claude Code
**both** in a terminal and in the Claude desktop app — whichever is smoothest:

1. **Screenshot → inject** — capture a region, type a message, send `message + screenshot`
   into the *existing* Claude session, no alt-tab.
2. **Live conversation mirror** — show Claude's conversation live in the panel.

Built on a **UI-agnostic core** (transcript tailing + hook bridge) plus per-host inject
adapters. Every step is audited/tested/verified by adversarial multi-agent loops and
validated against the real app.

## Method (non-negotiable, per user)

- Adversarial multi-agent loops at every step: propose → refute → referee → fix.
- Combine multiple solutions where needed for a smooth experience.
- Test through the **actual app** (computer-use on the real desktop app; live terminals).

---

## Phase 0 recon — ground truth (verified on this machine, 2026-06-21)

Environment: Claude Code CLI `2.1.177`; Claude desktop app `com.anthropic.claudefordesktop`
installed + running; iTerm2 running with 4 live `claude` sessions (all parented by `-zsh`,
i.e. terminal). No Ghostty/Warp/WezTerm/kitty installed.

### The two targets are architecturally different

| Capability | **Terminal Claude Code** | **Desktop app (Cowork / local-agent mode)** |
|---|---|---|
| Where it runs | host shell, real PTY | inside a **5.6 GB Apple-Virtualization Linux VM** (`vm_bundles/claudevm.bundle`: `rootfs.img` 10G, `sessiondata.img` 10G, `efivars.fd`, `vmIP`, gVisor MAC) with its **own** bundled `claude` 2.1.170 |
| Host `~/.claude` hooks fire? | ✅ yes | ❌ almost certainly no — VM has its own `.claude` root *(to verify)* |
| Transcript JSONL (for mirror) | ✅ `~/.claude/projects/<proj>/<uuid>.jsonl` | ✅ **same schema**, but nested at `~/Library/Application Support/Claude/local-agent-mode-sessions/<a>/<b>/local_<id>/.claude/projects/.../<uuid>.jsonl` (+ HMAC-signed `audit.jsonl`) |
| Working directory | ✅ user's real project | ❌ sandboxed VM path `.../local_<id>/outputs` — **not the user's repo** |
| Inject text | ✅ iTerm2 API (built) / tmux / kitty / CGEvent | ⚠️ no host port/socket, opaque Electron AX → only CGEvent-typing into the window or CDP/remote-debug *(to verify)* |
| Screenshot path resolves? | ✅ host `/tmp` | ⚠️ host path invisible in VM — must land the PNG in the host-mapped `outputs/` mount *(to verify mount)* |

### What this means

- **Mirror is UI-agnostic and feasible for both** via transcript tailing. This also flips the
  README's rejection of native chat ("Flavor B"): parsing the *transcript* is clean and
  structured, unlike scraping the TUI. Active-session discovery differs per target.
- **Inject is where the targets diverge hard.** Terminal is tractable and mostly built.
  Desktop inject is brittle: VM sandbox + opaque Electron + screenshot-invisibility, and the
  agent's cwd isn't even the user's project (so "fix this in my app" semantics partially break
  unless the repo is mounted into the VM).
- **TIOCSTI is dead on macOS** (EPERM without root — tested). No silent universal keystroke
  injection primitive exists.

### Clever combined avenues to verify for the desktop app

1. **Write the screenshot into the host-mapped `local_<id>/outputs/` dir** so it appears at the
   VM's cwd and Claude's Read tool can ingest it. (Needs: confirm that dir is a live host↔VM
   shared mount.)
2. **CGEvent type/paste into the Claude desktop window** (native app = "full" tier for
   computer-use; SnippAI would post events itself). Combine with #1 for a full screenshot→inject.
3. **CDP / Electron remote-debug** port, `claude://` URL scheme targeting an existing session,
   or an MCP surface — verify whether any exist.

---

## Build sequence (revised by Phase 0)

0. **Phase 0 feasibility** — adversarial recon workflow + live-app tests. *(in progress)*
1. **UI-agnostic mirror** — transcript-tail adapter; active-session discovery for terminal +
   desktop; native chat render.
2. **Terminal inject (smooth)** — finish iTerm path UX; add generic fallback (CGEvent) + tmux.
3. **Desktop inject** — exhaust avenues (#1+#2+#3); deliver smooth if possible, else mirror-only
   for desktop with documented limits.
4. **Panel UX integration** — combine mirror + inject into one smooth flow per host.
5. **Adversarial verification + real-app E2E** at every step.

See [hook-bridge-spec.md](./hook-bridge-spec.md) for the already-built state-detection bridge.
See [claude-code-feasibility-matrix.md](./claude-code-feasibility-matrix.md) for the full adversarial recon.

---

## Phase 0 addendum — "find another way" for existing-session inject (2026-06-21)

User constraint hardened: **screenshot → the EXISTING session; never spawn a fresh session**
(hosted-PTY rejected for that reason). Findings:

### OS-level: existing-session inject is PTY-only (definitive)
Live `lsof` on a running terminal `claude` (pid 20727): stdin/stdout/stderr are all the **PTY**
(`/dev/ttys000`); the only other fds are KQUEUEs, a netsrc ctl, and one unrelated unix socket.
**No on-disk message queue, no control socket, no alternate writable channel.** (`last-prompt` is a
resume record; the only `.lock` is the task-list lock.) Therefore injecting into a *running* session
means writing to its PTY — which only the **terminal emulator** can do. There is **no universal
backchannel**; TIOCSTI is EPERM (proven). So "another way" at the OS layer does not exist:
- **Terminal inject** = the emulator's own API, one adapter per emulator that exposes one:
  iTerm2 ✅(built) · Terminal.app ✅(built) · tmux `send-keys` · WezTerm `wezterm cli send-text` ·
  kitty `kitten @ send-text` · VS Code/Cursor `terminal.sendText`. Holdouts with no API
  (Ghostty, Warp) → CGEvent paste (focus-steal, last resort).
- **Desktop inject** = its stdin is an Electron-owned `socketpair()`, not even a PTY → none of the
  above apply. Closed at the OS layer.

### Product-level lead for DESKTOP: native **Quick Entry** (promising, needs live test)
From the app bundle (`app.asar`): the desktop app ships a **Quick Entry** overlay —
- togglable native surface: `quickAccess.overlay.{toggle,setActiveChatId,setRecentChats,setLoggedIn}`,
- bound to a **global shortcut** (default `Alt+Space`), driven by a **Swift/AppKit bridge**
  (`[Swift] getCurrentChatInfo`) — i.e. **native, not the opaque Chromium web area** the README's
  ax_probe found blind. A native overlay may be **Accessibility-automatable**.
- **Aware of the active chat** (`setActiveChatId`) + recent chats → can target the **existing**
  conversation, not only a new one.

**This is the candidate "another way" for desktop screenshot→existing-session.** Open questions that
require driving the real app: (1) does Quick Entry accept an **image** (paste/attach)? (2) does submit
go to the **active** chat or always new? (3) is the overlay AX-addressable enough for SnippAI to drive
reliably? **Live-tested result:** Quick Entry is **disabled by default** on this machine (no persisted
shortcut/enabled pref); proving it out needs enabling a feature in the user's live app + more testing.
Deferred — desktop ships **mirror-only** for v1 (the honest, correct behavior).

---

## v1 DELIVERED (2026-06-21) — both must-haves, both targets

Built on `feat/claude-code-app`, 89 tests, verified in the real app (screenshots in session).

### Live conversation mirror (must-have #2) — ✅ terminal AND desktop
One UI-agnostic engine tails the host transcript JSONL and renders a **native chat** (text bubbles,
tool-call/result chips, collapsible thinking) — replacing the brittle TUI scrape the README rejected.
- Engine: `TranscriptEvent`/`TranscriptDecoder` (defensive, ~10-type schema), `TranscriptTailer`
  (vnode-watch, incremental, rotation-safe), `TranscriptLocator` (cwd→`[^A-Za-z0-9]`→`-` slug).
- App: `ConversationStore` + `TranscriptMirrorController` (generation-guarded) + `ConversationMirrorView`.
- Binding: exact via adapter/hook `transcript_path`, else cwd cold-start (excludes desktop transcripts
  so a terminal target never mirrors the desktop's chat).
- Verified rendering three distinct real conversations (live terminal, tg-brain, desktop).

### Screenshot → inject (must-have #1) — ✅ terminal AND desktop
- **Terminal:** existing iTerm2 + Terminal.app adapters inject into the *existing* running session
  (PTY via the emulator API — the only OS-level path; proven by `spike_iterm.py`). The inject-aware
  default selection auto-targets an injectable Claude session; send is enabled.
- **Desktop:** ✅ **working.** `ClaudeDesktopAdapter` discovers the foreground session from the
  `claude-code-sessions` registry, mirrors it, AND injects via `DesktopInjector` (app-layer UI
  automation — the only viable path; Electron socketpair stdin, opaque web content, and
  CDP/`claude://`/MCP were all rejected in the matrix). The foreground desktop session runs on the
  **host**, so a host `/tmp` screenshot is readable by its `Read` tool — same `message + screenshot
  path` format as terminals. Recipe: `claude://chat/<id>` (focus) → activate → set `NSPasteboard` →
  CGEvent ⌘V → CGEvent Return; the input auto-focuses on window focus (no click). Frontmost is
  re-verified immediately before each synthetic keypress so keys can never land in the wrong app.
  Requires a one-time **Accessibility** grant (prompted just-in-time). **Proven end-to-end against
  the live app:** an injected message landed as a user turn and the agent `Read` a test PNG, replying
  with the exact marker. `supportsInject:true`, `hasScreenStream:false` (display = transcript mirror).

### Method
Adversarial multi-agent loops at every step (Phase-0 recon 23 agents; mirror-core review 4 agents →
fixed 1 critical + 1 latent; desktop-discovery review 4 agents → fixed 2 high + 2 medium; desktop-inject
review 19 agents → fixed a TOCTOU focus race + a main-thread block). Bugs caught only by running the
**real app**: a `deinit` dispatch-deadlock and cross-session event bleed. Desktop inject was de-risked
against the live app *before* building (proved the paste+read loop), then re-verified after each change.

### Known follow-ups (documented, not blocking)
- Terminal adapters beyond iTerm/Terminal (tmux `send-keys`, WezTerm/kitty CLIs) — not built: the
  user's environment lacks those terminals, so they'd be unverifiable. Each is a thin `TargetAdapter`.
- Desktop inject via Quick Entry — revisit if the user enables it; needs image-support + routing tests.
- Multi-window desktop foreground disambiguation (registry validated against 1 entry).

