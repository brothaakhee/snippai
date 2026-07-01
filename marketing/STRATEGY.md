# Strategy

## Positioning

**One-liner:** *Screenshot straight into your Claude Code terminal session — no alt-tab.*

This mirrors the site headline ("Screenshot, straight into Claude"). Don't reinvent it across
channels — consistency is the point. SnippAI is a **productivity extension for Claude Code
users**, not a generic screenshot utility. The whole value prop assumes the reader already runs
Claude Code in a terminal and hits the alt-tab tax when they need to show it something visual.

## ICP — who, and where they already gather

**Who:** intermediate+ developers on macOS (14+) using Claude Code as a real pair-programmer in
iTerm2 or Terminal.app, usually with a browser open for testing. Comfortable in the terminal.

**Where to reach them (watering holes):**
- **r/ClaudeAI** and adjacent subreddits (r/macapps, r/commandline).
- **Claude Code / Anthropic Discord** communities.
- **X/Twitter** — the AI-coding scene, "Claude Code" threads, people posting terminal workflows.
- **Hacker News** — Show HN + comment threads about AI coding tools.
- **The `awesome-claude-code` GitHub list ecosystem** — where people curate Claude Code tooling.

This list is short on purpose. A tiny, well-defined ICP means presence in a handful of places
beats spray-and-pray reach.

## Messaging pillars

1. **Kills the alt-tab tax.** Spot a bug → `⌥⇧4` → select → type → it's in Claude Code. One
   screen, one motion, versus screenshot-file-alt-tab-paste-type.
2. **Native, not an Electron bolt-on.** Owns the capture pipeline (ScreenCaptureKit), talks to
   iTerm2 over its native socket, and shows a **live mirror** of the session in the panel.
3. **$8.99 once, no subscription.** Impulse-priced, 7-day trial, you own it.
4. **Built *for* Claude Code.** Not a general tool with a Claude mode — this is the Claude Code
   screenshot workflow, done properly.

## Guardrails (repeat from README — they matter)

- **Terminal-first.** Lead with iTerm2 / Terminal.app. Claude Desktop is aspirational; never the
  headline.
- **Honest onboarding.** Mention the one-time iTerm2 Python API enable ("10-second setup"). It
  builds trust and pre-empts the one predictable friction point.

## Channel priority (effort-aware)

| Tier | Channels | Why |
|------|----------|-----|
| **1 — do first** | Social listening (running), Homebrew cask, awesome-list PRs | Highest leverage, durable, near-zero cost, exactly-targeted |
| **2 — launch spikes** | Show HN, Product Hunt, subreddit launches | One-day traffic bursts; recycle the same demo + copy |
| **3 — amplify** | Demo clips/content, creator seeding, one newsletter test | Compounds the above; the paid test is measured before repeating |

Rationale: Tier 1 is where a niche Mac dev tool actually gets found (developers *search*
Homebrew and awesome-lists; the listening job meets people at the moment of pain). Launch
spikes are worth it but one-shot. Content + seeding amplify whatever's already working.

## Success metrics (keep it dead simple)

The numbers are small enough to eyeball — no analytics stack needed:
- **DMG downloads** — GitHub release asset download counts (`gh release view`).
- **Trial starts** — in-app trial activations (proxy: downloads).
- **Purchases** — Lemon Squeezy dashboard.
- **Referral source** — jot where a spike came from (HN? a creator's video? a subreddit?) so we
  learn which channels convert and double down.

Target framing: this is a low-price, high-fit tool. A few hundred of the *right* developers
seeing it converts better than tens of thousands of the wrong ones.
