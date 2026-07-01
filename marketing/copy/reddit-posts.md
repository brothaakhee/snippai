# Reddit posts

Three variants tuned to each subreddit's culture. **Lead every post with the demo GIF** — Reddit
scrolls fast and the visual does the work. Read each sub's self-promo rules before posting; some
require a flair, some limit links to the comments. Disclose you're the maker.

---

## r/ClaudeAI — workflow-framed

**Title:**
```
I made a Mac app that fires a screenshot straight into your Claude Code terminal session (⌥⇧4)
```

**Body:**
```
[demo GIF]

If you run Claude Code in a terminal with a browser open for testing, you know the loop:
screenshot a bug → save it → switch to the terminal → drag it in → type what's wrong. I
got tired of it, so I built SnippAI.

Hit ⌥⇧4, drag a region, type your message in the little panel that pops up, hit enter —
the screenshot + text go straight into the Claude Code session you already have running,
and the response streams back in the panel. It shows a live mirror of your sessions so if
you've got a few open you pick the right one.

Native macOS app. The tight integration is with iTerm2 (over its socket API) and
Terminal.app. One-time ~10-sec setup to enable iTerm2's Python API and that's it.

7-day trial, then $8.99 once, no subscription. macOS 14+. Feedback very welcome —
especially on the capture flow.

snippai.dev
```

---

## r/macapps — native-app-framed

**Title:**
```
SnippAI – a native menu-bar app that sends screen grabs straight into Claude Code (⌥⇧4, $8.99 once)
```

**Body:**
```
[demo GIF]

Sharing a little Mac app I built. It's a menu-bar utility (Swift, ScreenCaptureKit, no
dock icon) that lets you grab a region of the screen with ⌥⇧4 and send it — with a typed
message — directly into a Claude Code AI session running in your terminal. Reply streams
back in the same panel.

It's properly native: owns the capture pipeline and talks to iTerm2 over its socket rather
than screen-scraping. Developer ID signed + notarized. macOS 14+.

$8.99 one-time, 7-day free trial, no subscription. Happy to answer questions about how it's
built.

snippai.dev
```

---

## r/commandline — terminal-framed

**Title:**
```
Send a screenshot into your terminal AI session with one hotkey (iTerm2 / Terminal.app)
```

**Body:**
```
[demo GIF]

Built this for my own Claude Code workflow: ⌥⇧4 grabs a screen region, a panel opens where
you type a prompt, and it pushes the image + text into the terminal session you're already
in — no file juggling, no window switching.

The interesting bit for this sub: it connects to iTerm2 over its native WebSocket/protobuf
socket API (not AppleScript), so it can target a specific session and mirror it live.
Terminal.app is supported via AppleScript as a fallback.

macOS 14+, 7-day trial then $8.99 once. Would love thoughts from people who live in the
terminal.

snippai.dev
```

---

## Etiquette reminders
- One sub at a time, spaced out — don't blast identical posts simultaneously (looks like spam).
- Respond to comments quickly and candidly.
- If a sub bans links in posts, put `snippai.dev` in a top comment instead.
- Never argue about paid/macOS-only — state it once, move on.
