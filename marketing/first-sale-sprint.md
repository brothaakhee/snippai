# SnipAI First-Sale Sprint — 7 days, one goal: sale #1
*2026-07-22. Evidence-backed (receipts researched; sources in conversation). The loop (product → trial → Lemon Squeezy checkout) already exists; distribution is the only missing piece. Every comparable receipt found (AI Audio Kit $5, Scriber Pro $3.99) got sale #1 within hours-to-days of a niche-community post.*

## Why SnipAI and not the others
- **SnipAI**: shipped, notarized, trial, $8.99 checkout live. Audience = Claude Code users: r/ClaudeAI (1.0M), r/ClaudeCode (~355k), r/macapps (229k), HN. Densest, most reachable niche possible.
- **KiddyProof**: PARKED for first-dollar. Competitors are free (BabyKeyboard Lock, tinyfingers.net), paid comps price at $0.99, r/daddit bans self-promo. Only viable as TikTok content play (weeks-months).
- **tg-brain**: no buyer channel identified; skip.

## Pre-flight (Day 0, ~2 hrs)
- [ ] **Launch coupon**: Lemon Squeezy coupon `LAUNCH` → $5.99 (reg $8.99), visible on site. (Evidence: launch discounts/LTDs are the one proven first-sale accelerant; PWYW tested worse for software.)
- [ ] **15-second demo GIF/video**: hotkey → drag region → type "fix this" → lands in Claude Code → response streams back. This asset is 80% of every post below. (marketing/demo.gif exists — check it's tight enough; ideally re-record at 15s.)
- [ ] **Read the actual sidebar rules** of r/ClaudeCode, r/ClaudeAI ("Built with Claude" flair requires: what you built, how, screenshots, ≥1 prompt used), r/macapps (self-promo OK, max once/30 days per dev).
- [ ] Site check: price + trial + "no subscription" visible above the fold; add "launch week $5.99" banner.

## The posts (Days 1–7, one channel per ~48h — don't carpet-bomb)

**Day 1 — r/ClaudeCode** (or r/ClaudeAI with Built-with-Claude flair). Build-story format, dev-disclosed:
> Title: "I got tired of screenshot → cmd-tab → paste → type, so I built a hotkey that fires a screen region straight into my running Claude Code session"
> Body: the pain, the 15s GIF, the technical bit people will ask about (iTerm2 WebSocket/protobuf injection, ~22ms round-trip; why there's no supported way to inject into a live `claude` and how the terminal API is the escape hatch), honest limitations (macOS 14+, iTerm2/Terminal only), trial + launch price. Answer every comment.

**Day 3 — r/macapps.** Same story, angle shifted to "native mac utility, one-time $5.99 launch price, no subscription" (that phrase is a selling point in this sub). Note: this burns the one-post-per-30-days allowance — make it count.

**Day 5 — Show HN.** The big one. Title ≈ "Show HN: SnipAI – screenshot a region straight into your running Claude Code session (macOS)". First comment = origin story + the injection engineering + why native + why paid ($8.99 one-time, 7-day trial, no subscription) — pre-empting the two standard HN gripes (closed-source, paid). Comparables: Claude usage-monitor tools clear 50–245 pts; Scriber Pro ($3.99, 137 pts) hit top-10 paid Mac utilities within a week. Post 8–10am ET Tue–Thu. Clear calendar to answer comments for 6 hours.

**Continuous — X reply-guy.** 15s GIF replies under @bcherny / @AnthropicAI / Claude Code tips threads (the accounts that drive tool discovery). 5 min/day. DM 3–5 visible Claude Code power-users a promo code — warm 1:1 produced Splitbee's first customer.

**Passive (Day 1, 30 min)** — submit to awesome-claude-code (50.7k stars; web-UI issue form ONLY, PRs rejected; one-line factual description; acceptance uncertain for closed-source paid — submit anyway) + jqueryscript/awesome-claude-code + rohitg00/awesome-claude-code-toolkit ("companion apps" section) + awesomeclaude.ai.

**Skip for now:** Product Hunt (below top-10 = <500 visitors; list it lazily later), lobste.rs (invite-gated), Setapp (weeks-long pipeline — revisit after sale #10), Raycast/Chrome/VS Code stores (no payment rails).

## Success/diagnostics
- **Goal: 1 sale by Day 7.** Plausible range per evidence: good niche-sub post = 1–10 sales; front-page Show HN = tens.
- Watch trial starts vs sales: many trials + no sales after 7 days = price/trust issue (consider trial-end email w/ coupon); no trials at all = the post/GIF isn't landing — rewrite the hook, not the app.
- Every "does it support Warp/Ghostty/kitty?" comment = roadmap signal + a future re-launch post ("SnipAI now supports Warp").

## After sale #1 (the scale question, deferred deliberately)
Sale #1 proves the loop. Then: Setapp application, VS Code/terminal-support expansions as re-launch events, awesome-list SEO compounding, maybe PH. Do NOT think about this until the first receipt exists.
