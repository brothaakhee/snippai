# SnippAI Hook Bridge — Implementation Spec

> Status: **approved for build** via adversarial debate (proponent → adversary → referee → synthesizer, 22 agents).
> This spec is the surviving, reduced-scope consensus of patterns reverse-engineered from Vibe Island.

## Goal

Give SnippAI an **authoritative, push-based session-state signal** ("Claude finished its turn" /
"Claude is waiting for you") instead of inferring state by parsing the terminal mirror (TUI). This
closes the #1 documented gap in the architecture notes — state is currently parsed *nowhere*; it's
whatever a human reads off the mirror.

## Hard rules (non-negotiable, from the debate)

1. **Pure enrichment.** Hooks add a *semantic badge*; the live iTerm mirror remains the source of
   truth for display and the fallback for any state a hook can't deliver. Never retire mirror logic.
2. **Non-blocking + fail-open.** The hook script returns immediately and `exit 0` always. If SnippAI
   is not running / socket absent, Claude is never blocked or slowed. **No blocking approval gate.**
3. **Consented + reversible.** Default **OFF**. A Settings toggle installs/uninstalls. Writing to
   `~/.claude/settings.json` always makes a timestamped backup, **merges** (never clobbers), is
   idempotent, and one-click uninstall removes exactly our entries.
4. **No new signed binary.** The hook is a POSIX shell script piping JSON to a Unix socket via
   `nc -U`. Avoids the fragile TCC/cdhash signing story a second notarized executable would inherit.
5. **No self-heal tarpit.** No FileWatcher / re-assert / orphan grace-period cleanup. If the user
   removes our config, it stays removed.

## Out of scope (deferred by consensus)

- StatusLine rate-limit scrape (identity mismatch: conversation-id ≠ pane-id).
- VS Code/Cursor focus extension (focus-only can't satisfy the send+mirror adapter contract).
- SSH remote tunnel / cross-compiled hooks (no remote requirement at POC).
- Blocking PermissionRequest approval gate (couples Claude uptime to POC; hangs the agent on crash).
- Pre/PostToolUse, SubagentStart/Stop, PreCompact hooks (only Stop + Notification ship now).

## Verified facts (checked before coding)

- Claude Code `2.1.177` installed.
- `/usr/bin/nc` supports `-U` (Unix domain sockets).
- **Join key is deterministic:** `TerminalSession.id` (iTerm `uniqueIdentifier`) ==
  the GUID after the colon in `ITERM_SESSION_ID` (`w0t5p0:<GUID>`). Confirmed live via `iterm-spike`.
- `tty` inside a hook is unreliable (stdin is the JSON pipe → `tty` prints "not a tty"); use
  `ps -o tty= -p $$` as a secondary, and `ITERM_SESSION_ID` / `TERM_SESSION_ID` as primary.

## Architecture

```
Claude Code (Stop / Notification hook fires)
   │  runs command hook, passes hook JSON on stdin
   ▼
~/Library/Application Support/SnippAI/snippai-hook.sh  <event>
   │  reads stdin (Claude JSON), grabs identity env (ITERM_SESSION_ID, TERM_SESSION_ID,
   │  TMUX_PANE, TERM_PROGRAM, ps-derived tty), base64-encodes the Claude payload,
   │  emits ONE JSON line → nc -U → socket. Always exit 0.
   ▼
~/Library/Application Support/SnippAI/hooks.sock   (AF_UNIX, dir 0700)
   ▼
HookSocketServer (SnippAIKit)  — POSIX socket + DispatchSource, parses newline JSON frames
   ▼
HookEventRouter → HookStateStore (@MainActor @Observable)  — correlates frame → session id
   ▼
AppModel reads HookStateStore → AgentState badge in:
   • menu-bar statusItem (aggregate: any session needs-you)
   • SessionPickerView rows (per-session dot)
   • PanelView header (replaces static "Sent — watch Claude work above")
```

## Components & build order

### Step 1 — Identity enrichment (S)
- `TerminalSession`: add `var tty: String = ""`.
- `ITermAdapter.discover()`: extend the `variables(names:)` read from
  `["path","autoName","jobName"]` to also request `"tty"`; populate `session.tty`.
- Use `tty` as a secondary picker disambiguator and a fallback correlation key.
- Primary correlation stays the GUID (already ground truth).

### Step 2 — Shared foundation (L)
- **`HookPaths`** (SnippAIKit): canonical paths under
  `~/Library/Application Support/SnippAI/` (`hooks.sock`, `snippai-hook.sh`), dir created `0700`.
- **`HookSocketServer`** (SnippAIKit): `socket(AF_UNIX, SOCK_STREAM)`, unlink-then-bind, listen,
  `DispatchSource.makeReadSource` on the listen fd; per-connection read to EOF on a serial queue;
  split on `\n`; decode each line as `HookFrame`; deliver via an `AsyncStream<HookFrame>` /
  callback hopped to `@MainActor`. Clean teardown unlinks the socket. Tolerates `EADDRINUSE`
  (unlink stale socket first).
- **`HookFrame`** (Codable): `{ v:Int, event:String, iterm:String?, termSession:String?,
  tmuxPane:String?, tty:String?, termProgram:String?, payloadB64:String? }`. The decoded payload
  yields Claude's `{ session_id, cwd, message? }`.
- **`snippai-hook.sh`** writer: materialized to `HookPaths.script`, `chmod 0755`, content embedded
  in the app (single source of truth, rewritten on enable to stay current).
- **`HookInstaller`** (SnippAI app): enable → backup `settings.json` to
  `settings.json.snippai-backup.<ISO8601>`, parse JSON, merge a Stop + Notification command hook
  (command = absolute path to `snippai-hook.sh` + event arg, tagged so we can find it), write
  atomically. Idempotent (skip if our entry present). Disable → remove exactly our entries, drop
  emptied arrays/`hooks` key, write. Both operate via `JSONSerialization` with sorted keys +
  pretty printing to minimize diffs.

### Step 3 — State model + badge (M)
- **`AgentState`** enum (SnippAIKit): `.working`, `.finished`, `.waitingForInput`, `.unknown`.
  Each carries a short label, an SF Symbol, and a tint for the UI.
- **`HookStateStore`** (`@MainActor @Observable`, SnippAI app): `[sessionID: AgentStateEntry]`
  where entry = `{ state, lastEventAt, message? }`. `apply(frame:)` correlates:
  1. GUID from `iterm` (substring after last `:`) → session id  **[primary]**
  2. `termSession` GUID → session id
  3. `tty` match against enriched `TerminalSession.tty`
  4. else drop (ignore uncorrelated frames — don't flip arbitrary panels).
  Map event → state: `Stop`→`.finished`, `Notification`→`.waitingForInput`. A subsequent mirror
  update or a new send resets to `.working`/`.unknown` as appropriate.
- **UI**:
  - `SessionPickerView` row: a small status dot + word when state is known.
  - `PanelView` header: replace the static "Sent — watch Claude work above" with the live state
    of the *selected* session when known; fall back to existing copy otherwise.
  - Menu-bar `statusItem`: overlay a tiny dot when **any** session is `.waitingForInput`/`.finished`
    (look-away affordance), cleared when attended.

### Step 4 — Wire the hooks (after 1–3) (M)
- Settings toggle "Enable Claude Code status (beta)" (default OFF) → `HookInstaller.enable()`
  writes the script + merges hooks; OFF → `disable()`.
- Verify the **actual** Stop/Notification JSON shape emitted by claude 2.1.177 end-to-end (decode a
  real frame) before trusting field names; degrade gracefully (badge simply stays `.unknown`) on any
  schema drift — never error.

## Security / trust notes

- Socket dir is `0700` (owner-only) — the only "auth" at POC. Documented as not spoof-hardened;
  uncorrelated frames are dropped, so a stray local process can't flip an arbitrary pane's badge.
- We never execute anything from the frame; we only parse JSON and set enum state.
- `settings.json` is the user's primary tool config — backup + merge + idempotent + tested uninstall
  are mandatory before the toggle is exposed.

## Test plan

- **Unit (SnippAIKit):** `HookFrame` decode (well-formed, missing fields, bad base64);
  GUID-extraction from `ITERM_SESSION_ID`; `HookInstaller` merge is idempotent and a
  round-trip enable→disable restores the original `settings.json` byte-for-semantics; correlation
  precedence (GUID > termSession > tty > drop).
- **Integration:** start `HookSocketServer`, send a frame with `nc -U`, assert the store updates the
  right session; send an uncorrelated frame, assert it's dropped.
- **End-to-end:** enable the toggle, run a real Claude turn in iTerm, observe the badge flip to
  `.waitingForInput` on a permission prompt and `.finished` on Stop; disable, confirm `settings.json`
  restored.
- **UI/UX:** screenshots of the picker dot, the panel header states, and the menu-bar badge.
