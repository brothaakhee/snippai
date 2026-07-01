# Launch checklist

Sequenced runbook for the marketing launch. The **technical** release steps (signing,
notarization, cutting the GitHub release, Lemon Squeezy IDs) live in `../docs/LAUNCH.md` — do
those first. This checklist is the go-to-market layer on top.

## Pre-launch (get these ready before any launch day)

- [ ] **Product is live & buyable** — v1.0.3 DMG published, trial + paywall working, Lemon
      Squeezy checkout confirmed (see `../docs/LAUNCH.md`).
- [ ] **Site sanity check** — snippai.dev up, download link resolves, version shows current,
      demo video plays.
- [ ] **Demo assets cut** — looping GIF + ~15-sec vertical clip from `../site/demo.mp4`.
- [ ] **README has the GIF** — the repo/landing visuals sell it at a glance.
- [ ] **Homebrew cask** — submitted (or own tap live). `brew install --cask snippai` works.
- [ ] **Awesome-list PRs** — opened for awesome-claude-code, awesome-macos, awesome-command-line.
- [ ] **Copy drafted & reviewed** — `copy/show-hn.md`, `copy/product-hunt.md`,
      `copy/reddit-posts.md`, `copy/x-reply-templates.md`.
- [ ] **Creator seeding** — free licenses sent to 3–5 Claude Code creators, with a short note.
- [ ] **Directories** — AlternativeTo / MacUpdate submissions queued.

## Launch week (sequence the spikes — one big push per day)

- [ ] **Day 1 — Show HN.** Post early US morning (Tue–Thu, ~7–9am ET). Use `copy/show-hn.md`.
      Post the maker first-comment immediately. **Be in the thread all day** answering fast.
- [ ] **Day 2 — Reddit.** Post the tailored variants (`copy/reddit-posts.md`) to r/ClaudeAI,
      r/macapps, r/commandline — space them out, lead each with the GIF. Follow each sub's rules.
- [ ] **Day 3 — Product Hunt** (schedule 12:01am PT) + **Peerlist**. Use `copy/product-hunt.md`.
      Line up a handful of real users to try it and comment honestly that day.
- [ ] **All week — social listening + X.** Keep the listening job hot; post the launch-day X
      thread (`copy/x-reply-templates.md`) and reply to every mention same-day.

## Post-launch

- [ ] **Attribute** — log where downloads/purchases came from in `social-listening.md` + notes.
- [ ] **Respond everywhere** — no unanswered comment on any launch thread.
- [ ] **Newsletter test** — if organic looks healthy, buy the one measured newsletter slot.
- [ ] **Iterate** — double down on whatever channel converted; drop what didn't.
- [ ] **Update this folder** — mark what shipped, capture lessons for the next version's launch.

## Quick reference (keep consistent everywhere)

- Price: **$8.99 once** · 7-day trial · no subscription
- Requirement: **macOS 14+**
- Hotkey: **⌥⇧4**
- Site: **snippai.dev** · Support: hello@snippai.dev
- Download: `github.com/brothaakhee/snippai-releases/releases/latest/download/SnippAI.dmg`
- Brand: mint **#13a066**, Archivo + JetBrains Mono
