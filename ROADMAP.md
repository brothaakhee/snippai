# Roadmap

SnippAI v1.1.2 is shipped and selling. This is the work ahead, roughly in order.

## Ship what's on `main`
- **Ask.** Finish and release the "highlight anything on screen, get an instant
  explanation" overlay on `main`: resolve the source conversation in the background so a
  question asked early still carries context, then cut 1.2.0 through `scripts/release.sh`.
- **Site.** Bring snippai.dev back up and point its download at the latest release.

## More places Claude Code runs
- **Scriptless terminals.** A "SnippAI-managed terminal" mode that launches `claude`
  under tmux with a session-to-pane registry, which covers Ghostty, kitty, WezTerm and
  Alacritty (`docs/claude-code-feasibility-matrix.md`, option T4).
- **Warp.** Investigate an adapter; Warp has no scripting API, so this likely means the
  CGEvent-paste path with its focus-steal disclosed.
- **Claude Desktop.** Take the beta adapter out of beta: harden the clipboard-swap
  inject and its frontmost-app guards, and confirm the transcript mirror across several
  concurrent desktop windows.

## Mirror fidelity
- **Sub-agents.** Watch `subagents/**/*.jsonl` so sub-agent and parallel turns show up
  in the mirror, and verify against live growing transcripts (validation items 1–2 in
  the feasibility matrix).
- **Approve or deny from the panel.** An opt-in PreToolUse hook that round-trips a
  permission decision over the existing hook socket (feasibility matrix, Phase 4).

## Distribution
- **Homebrew cask** so `brew install --cask snippai` works (the `brothaakhee/homebrew-tap`
  tap already serves kiddyproof).
