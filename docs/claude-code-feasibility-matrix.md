# Claude Code Integration — Feasibility Matrix

Adversarially-tested verdicts for every avenue SnippAI can use to drive Claude Code, across two targets (TERMINAL = host CLI, DESKTOP = Claude desktop app whose agent often runs inside an Apple-Virtualization Linux VM) and two must-have flows (screenshot→inject into the existing session, live conversation mirror).

All probing was read-only. No claim below rests on writing into a live session, controlling the VM, or killing a process.

## 1. Feasibility Matrix

| Avenue | Target | Feasible | Smooth (1–5) | Confidence | One-line why |
|---|---|---|---|---|---|
| **T1** transcript tail (mirror) | terminal | **yes** | **4** | high | Inode-stable in-place appends + hook-delivered exact `transcript_path` → vnode-watch & byte-offset tail is exact; app is unsandboxed so no TCC. Tail+parse+render is net-new code. |
| **T2** blocking PreToolUse hook (approve/deny) | terminal | partial | 2 | high | PreToolUse fires in all modes with model-visible `permissionDecisionReason`; but user default is `auto`, full chain never live-verified, and it's only the approve/deny half — not injection. |
| **T3** CGEvent Cmd-V paste (inject) | terminal | partial | 2 | high | One TCC grant (Accessibility) away, but mandatory focus-steal every inject + silent failure under Secure Keyboard Entry / sudo prompts. Scriptless-terminal last-resort only. |
| **T4** tmux send-keys (inject) | terminal | partial | 3 | high | Literal injection + separate Enter works cleanly, but ONLY for sessions SnippAI itself launches under tmux; cannot adopt already-open iTerm/Terminal tabs. |
| **D1** host `~/.claude` hooks | desktop | partial | 2 | medium | Host-entrypoint desktop sessions load host settings (hooks likely fire); the 116 VM sessions have isolated per-session `.claude` with no hooks. Live firing not empirically confirmed. |
| **D2** desktop transcript mirror | desktop | partial | 3 | high | Foreground desktop session writes to **host** `~/.claude` (same as CLI), discoverable via `claude-code-sessions` registry — NOT via `local-agent-mode-sessions` (that's the VM/scheduled class). |
| **D3** outputs-dir shared mount (deliver file) | desktop | partial | 3 | high | The `local-agent-mode-sessions` tree IS the VM's shared dir (proven by open root-dir fd); host-dropped PNG appears live in-guest at identical path. But file-only + active-session targeting unsolved. |
| **D4** CGEvent into Electron (inject) | desktop | **no** | 1 | high | VM-sandboxed cwd makes host screenshots unreadable (kills the image flow by construction); blind targeting across 9 windows / 116 sessions; no pre-send verification. |
| **D5** CDP / `--inspect` debug | desktop | **no** | 1 | high | Zero LISTEN sockets / debug flags; Electron fuses hard-disable RunAsNode + NodeOptions + NodeCliInspect; asar integrity enforced. No surface, can't enable non-destructively. |
| **D6** `claude://` URL scheme | desktop | partial | 2 | high | `code/new?prompt=` carries text but always spawns NEW; `resume`/`chat`/`project` target existing sessions but are navigate-only — param allowlist forbids any prompt/image. Focus primitive only. |
| **D7** MCP / IPC / local server | desktop | **no** | 1 | high | No local MCP/HTTP/XPC server exists; the real inject path is an anonymous `socketpair()` stdin owned by Electron main — no port, no path, unaddressable by a third party. |

## 2. Recommended Approach Per Flow × Target

### Flow A — Live conversation mirror

**TERMINAL (T1) — smooth, ship first.**
1. On each hook frame (already delivered via `HookSocketServer` → `HookFrame`), read `claudePayload.transcriptPath` + `.sessionID`; correlate to `TerminalSession.id` via existing `HookCorrelator` (GUID→tty). `UserPromptSubmit` binds at turn start — no Stop-only cold-start gap.
2. **Net-new:** open `transcriptPath`, seek EOF, attach `DispatchSource.makeFileSystemObjectSource(fd, eventMask:[.write,.extend])` (a different API than the repo's socket `makeReadSource`). On fire, read bytes after `lastOffset`, split on `\n`, JSON-decode each line. Inode-stable append is confirmed, so offset math is exact. Guard `size < lastOffset` → reopen from 0 (rotation/compaction).
3. Render by top-level `type`: mirror `user`/`assistant` (+ optional `system` stop summaries); walk `message.content` blocks (text→bubble, thinking→collapsed, tool_use/tool_result→chip). **Defensively skip ~10 other types** (`mode`, `pr-link`, `file-history-snapshot`, `queue-operation`, `attachment`, `custom-title`, `last-prompt`, `permission-mode`, …) and tolerate missing fields — schema is undocumented and version-drifts.
4. **Sub-agent fidelity:** to mirror sub-agent / parallel-workflow turns, also watch `<transcriptDir>/<sessionId>/subagents/**/*.jsonl` — those appends do NOT land in the top-level file. Optional for a basic main-thread mirror; required for completeness.

**DESKTOP (D2) — same engine, different discovery.** The foreground desktop session writes to **host** `~/.claude/projects/...`, identical to the CLI — so the SAME parser + tail engine serves both. The only desktop-specific piece is foreground discovery:
1. Watch `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json`; pick max `lastFocusedAt` (ignore `isArchived`). Read `cliSessionId` + `originCwd`.
2. Resolve transcript on host: `~/.claude/projects/` + `-` + `originCwd.strip('/').replace('/','-')` + `/` + `cliSessionId` + `.jsonl` (verified to resolve; glob `**/<cliSessionId>.jsonl` as fallback).
3. Use transcript **size/mtime** as the liveness/turn signal — NOT the sidecar `lastFocusedAt`, which is event-driven and stale (frozen at focus-change, not per-turn).
4. **Do NOT** mirror from `local-agent-mode-sessions` — that tree holds VM/scheduled agent sessions (108/116 are `scheduled`, dormant today). Building on it mirrors the wrong, stale sessions.

> Caveat: desktop foreground discovery was validated against only ONE `claude-code-sessions` entry. Validate against ≥2 concurrent desktop windows before trusting it.

### Flow B — Screenshot → inject into existing session

**TERMINAL — best smooth path is the repo's existing automation adapters, NOT a new injection primitive.** The repo already has iTerm WebSocket + Terminal.app `do-script` adapters that inject text with no focus-steal and no clipboard clobber — strictly better than T3/T4. Pair with the host filesystem path (terminal cwd is a real host path, so a `/tmp/snippai-shot-<ts>.png` reference resolves) and a separate Enter to submit.
- **T4 (tmux)** is viable only for a dedicated "SnippAI-managed terminal" mode: launch `claude` under `tmux new-session`, persist a `{session, pane_id, cwd, pane_pid, cliSessionId}` registry at launch (cwd alone is non-unique), then `capture-pane` idle-check → `send-keys -l '<msg + path>'` → separate `send-keys Enter`. Cannot adopt externally-launched tabs.
- **T3 (CGEvent paste)** is a degraded last resort for scriptless terminals (Alacritty/kitty/WezTerm/Ghostty) only — gate on `AXIsProcessTrusted()`, hard-abort on `IsSecureEventInputEnabled()`, save/restore the full pasteboard, and disclose the unavoidable focus-steal.

**DESKTOP — no smooth path exists (see §3).** The least-bad partial recipe combines two avenues, and even then targeting is unsolved:
- **Deliver the file via D3:** the share is rooted at `local-agent-mode-sessions` (proven by the VM's open root-dir fd), so an atomic write (`tmp` + `rename()` in the same dir) into `local_<id>/outputs` appears live in-guest at the identical absolute path; a bare relative `Read` resolves because host cwd == guest cwd.
- **Reference it via a message-injection channel** — which does not exist for desktop. D4/D5/D6/D7 are all rejected for injection. Without a companion channel that posts a user turn naming the file, the dropped PNG is inert.
- **Targeting is the real blocker:** `max(lastActivityAt)` does NOT track the VM's live-served set; you must filter to `sessionType != 'scheduled'` AND correlate to the session the VM currently holds open / the visible window. **Writing into a live `local-agent-mode-sessions` dir is forbidden by the project's hard safety rules**, so even the delivery half cannot ship without lifting that rule under supervision.

## 3. Verdict — Desktop Screenshot → Inject

**NOT achievable as a smooth experience today. Partial at best, and only by violating a current safety rule.**

**Single biggest blocker:** the desktop agent's working directory is the **VM-sandboxed share** (`.../local_<id>/outputs`), and the ONLY host→VM bridge is that per-session `outputs/` dir — which the project's hard safety rules forbid writing to. Host screenshots saved anywhere else (`/tmp`, `~/Desktop`) are simply invisible inside the VM, so a "paste the file path as text" fallback resolves to a non-existent path. Compounding this, there is **no programmatic message-injection channel on desktop at all**: CGEvent is blind across 9 windows / 116 sessions (D4), CDP/inspect is fused off (D5), `claude://` carries no payload past an OAuth-only allowlist (D6), and the real stdin inject path rides an unaddressable `socketpair()` owned by Electron main (D7).

The only credible future smooth path is an **Anthropic-supported attach/inject API into the VM session** — none exists today. Do not ship a blind CGEvent text-poke; it is a liability (wrong-conversation risk + no image), not a feature.

## 4. Prioritized Build Order

**Phase 1 — Terminal live mirror (T1). Fastest smooth win.**
The correlation half is already built (`HookCorrelator`, `HookFrame`, `HookSocketServer`). Build only the net-new tail engine: vnode `makeFileSystemObjectSource` watcher + incremental JSONL decoder + block renderer with defensive unknown-type skipping. Smoothness 4, high confidence, no TCC prompt. Add subagents/ subtree watching for full fidelity.

**Phase 2 — Desktop live mirror (D2) reusing the Phase 1 engine.**
Same parser/tail engine; add only foreground discovery via the `claude-code-sessions` registry (max `lastFocusedAt` → `cliSessionId` + `originCwd` → host transcript path). Liveness from transcript size/mtime. Validate against multiple concurrent desktop windows.

**Phase 3 — Terminal screenshot → inject via existing iTerm/Terminal.app adapters.**
Reuse the repo's WebSocket / `do-script` adapters (no focus-steal, no clipboard clobber). Reference a host `/tmp` PNG by path + separate Enter to submit. Optionally add the "SnippAI-managed tmux terminal" mode (T4) for scriptless coverage with a launch-time session↔pane registry.

**Phase 4 — Terminal approve/deny + feedback via PreToolUse hook (T2), optional.**
Merge (never overwrite) a command-type PreToolUse hook into the existing vibe-island chain; round-trip a decision via local IPC and return `permissionDecision` + `permissionDecisionReason`. Live-verify the full real-tool-call → hook → allow-honored chain on a network-enabled box before trusting it.

**Phase 5 — Desktop screenshot → inject: DO NOT BUILD until unblocked.**
Treat as research, not delivery. Two prerequisites, both currently unmet: (a) a sanctioned write path into the live VM session share (requires lifting the safety rule under supervision, or an Anthropic API), and (b) a real message-injection channel that references the file. Until both exist, desktop remains mirror-only.

### Validate against the real app next

1. **T1 sub-agent fidelity:** confirm a real sub-agent / parallel-workflow turn appends to `subagents/**/*.jsonl` and not the top-level file, and that the mirror surfaces it.
2. **T1/D2 liveness:** capture an actually-growing transcript during a live turn (probes so far inferred append from mtime, never caught a live byte-delta).
3. **D2 multi-session:** open ≥2 concurrent desktop windows and confirm `claude-code-sessions` carries one correctly-`lastFocusedAt`-ordered entry per session (only 1 entry was ever observed).
4. **D1 host-hook firing (with user consent):** append a reversible marker-writing PreToolUse hook to host `~/.claude/settings.json`, trigger a tool in a desktop-host session, verify the marker fires, then restore. (Blocked under read-only rules so far.)
5. **T2 end-to-end:** on a network-enabled box, fire a real tool call and confirm PreToolUse fires → `allow` honored → tool runs. The whole chain is currently inferred only (401/synthetic-model blocked every live attempt).
6. **D3 write-back semantics (supervised):** with the safety rule lifted under supervision, write a PNG into an ARCHIVED (VM-detached) session's `outputs/` to confirm host-side write semantics before any live drop.
