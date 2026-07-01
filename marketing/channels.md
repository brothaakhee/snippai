# Channels

Every way we market SnippAI, roughly in priority order. Each has: **what**, **why**, **effort**,
and **do this**. Guardrails apply throughout — terminal-first, honest about the iTerm2 setup.

---

## 1. Social listening & direct engagement — *RUNNING* · Tier 1

**What:** a Claude job scans X/Twitter, Reddit, HN, and forums for people discussing terminal +
screenshot + copy-paste pain around AI coding, and surfaces threads to engage directly.

**Why:** meets the exact ICP at the moment of pain. Highest-intent channel we have.

**Effort:** low-ongoing (the job runs; engagement is manual, a few min per thread).

**Do this:** see [social-listening.md](social-listening.md) for the full playbook, search terms,
engagement rules, reply templates, and the tracking log.

---

## 2. Homebrew cask — Tier 1

**What:** ship a cask so `brew install --cask snippai` works, pointing at the `snippai-releases`
DMG.

**Why:** developers *search and trust* Homebrew. It's the discovery layer for Mac dev tools, and
being installable via brew signals legitimacy. Durable, set-and-forget inbound.

**Effort:** medium one-time (write the cask, open the PR, pass CI). Auto-updates via the
`releases/latest` URL once merged.

**Do this:**
- Author a cask referencing `https://github.com/brothaakhee/snippai-releases/releases/latest/download/SnippAI.dmg`,
  the app bundle name, `depends_on macos: ">= :sonoma"`, and the notarized signature.
- Submit to `homebrew/homebrew-cask`. Because it's a paid app with a trial, confirm it meets
  cask notability/licensing rules; if not, ship our **own tap** (`brothaakhee/homebrew-snippai`)
  and put `brew install brothaakhee/snippai/snippai` on the site.
- Keep the cask version bump in the release checklist so brew stays current.

---

## 3. GitHub "awesome" list PRs — Tier 1

**What:** get SnippAI listed on curated GitHub lists our ICP browses.

**Why:** free, durable, perfectly-targeted. People find these lists when they go looking for
exactly this kind of tool.

**Effort:** low (one PR each, one sentence + link).

**Do this — target lists:**
- `awesome-claude-code` / `awesome-claude` (highest fit — Claude Code tooling).
- `awesome-macos` / `awesome-mac` (native Mac apps).
- `awesome-command-line` / terminal-tooling lists.
- Follow each list's format; lead the blurb with the terminal workflow, not Claude Desktop.

---

## 4. Launch moments — Tier 2

**What:** coordinated one-day launches on Show HN, Product Hunt, and Peerlist Launchpad.

**Why:** concentrated traffic + backlinks + social proof. Each is a spike, not a drip — so
sequence them (see [launch-checklist.md](launch-checklist.md)) and reuse one demo + copy set.

**Effort:** medium (copy is pre-drafted in `copy/`; the work is timing + same-day responsiveness).

**Do this:**
- **Show HN** — "Show HN: SnippAI – screenshot straight into your Claude Code terminal." Post
  early US morning (Tue–Thu). Copy in [copy/show-hn.md](copy/show-hn.md). Be present in comments.
- **Product Hunt** — schedule 12:01am PT. Copy in [copy/product-hunt.md](copy/product-hunt.md).
  Line up a few genuine users to try it that day.
- **Peerlist Launchpad** — dev-heavy audience, lower noise than PH; reuse the PH assets.

---

## 5. Community seeding — Tier 2

**What:** be a genuine, helpful presence in the communities where the ICP lives.

**Why:** compounds with social listening. When someone asks "how do you send screenshots to
Claude Code?", a real answer + demo converts better than any ad.

**Effort:** low-ongoing (participate, don't spam).

**Do this:** r/ClaudeAI, r/macapps, r/commandline, the Claude Code Discord, indie-hacker spaces.
Contribute first; mention SnippAI only where it genuinely answers the question, and disclose
you're the maker.

---

## 6. Directories — Tier 2

**What:** list SnippAI in software directories.

**Why:** low-effort, set-and-forget SEO and a trickle of qualified discovery.

**Effort:** low one-time.

**Do this:** AlternativeTo (as an alternative to "screenshot + paste" workflows), MacUpdate, and
any Claude/MCP tool directories. Reuse the app icon + demo poster + one-liner.

---

## 7. Content / demo clips — Tier 3

**What:** short visual content built from the existing demo.

**Why:** the single strongest lever for a **visual** tool — a 6-second loop sells the whole idea
faster than a paragraph. We already have `site/demo.mp4`; cut, don't re-record.

**Effort:** low-medium (edit existing footage; one short written post).

**Do this:**
- Cut `../site/demo.mp4` into (a) a looping GIF for the README + Reddit posts, and (b) a ~15-sec
  vertical clip for X / YouTube Shorts.
- Embed the GIF in the repo README and every launch post.
- One short blog / dev.to piece: **"I stopped alt-tabbing screenshots into Claude Code."**
  Problem → the fix → how the native iTerm2 hookup works → trial link.

---

## 8. Small paid experiments — Tier 3 *(user opted in — keep cheap + measured)*

**What:** two low-cost bets, each measured before repeating.

**a) Creator seeding (≈ $0).** Send **free licenses** to 3–5 creators on X/YouTube who demo
Claude Code workflows. A $8.99 license costs us nothing; one authentic mention reaches the exact
ICP. Pick creators who actually use Claude Code in a terminal — fit over follower count.

**b) One newsletter slot.** Buy a **single** test placement in an AI-dev / macOS-dev newsletter.
Use a distinct link (or watch the download spike timing) to measure lift. Only repeat if it
clearly beats the free channels.

**Effort:** low. **Rule:** if a paid bet doesn't beat organic on cost-per-download, kill it.
