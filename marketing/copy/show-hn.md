# Show HN copy

Paste-ready. Post early US morning (Tue–Thu). Submit the **maker first-comment** immediately so
it's the top context when people arrive.

---

## Title

```
Show HN: SnippAI – Screenshot straight into your Claude Code terminal session
```

*(Alt, if you want the pain up front: "Show HN: SnippAI – Stop alt-tabbing screenshots into
Claude Code")*

## URL

```
https://snippai.dev
```

## Body (optional text — HN lets you add text or just a URL; a short text helps)

```
I use Claude Code in iTerm2 with a browser open for testing. Every time I spotted a
UI bug I'd do the same dance: screenshot → save → alt-tab to the terminal → drag the
file in → type what's wrong → enter. Five steps across two windows, dozens of times a day.

SnippAI collapses that to one motion on one screen. Hit ⌥⇧4, drag a region, a panel
pops up where you type your message, hit enter — the screenshot + your text land
directly in the Claude Code session you already have running, and the reply streams
back in the same panel.

It's a native macOS menu-bar app (Swift, ScreenCaptureKit). It talks to iTerm2 over
its native socket API (not AppleScript screen-scraping), and shows a live mirror of
the session so you can see which one you're firing into. Terminal.app works too via
AppleScript.

$8.99 one-time, 7-day trial, no subscription. macOS 14+. Happy to answer anything.
```

---

## Maker first-comment (post right after submitting)

```
Maker here. A few honest notes:

- The native integration is with iTerm2 and Terminal.app — that's where the "no
  alt-tab" magic actually works. I list Claude Desktop as compatible, but Electron
  is opaque to the OS injection I rely on, so that path isn't as seamless; the
  terminal is the real story.

- One-time setup: you enable iTerm2's Python API (a toggle + an Allow dialog). Takes
  about 10 seconds and iTerm2 remembers it. I'd rather say that up front than have it
  surprise anyone.

- Why macOS-only: it leans hard on ScreenCaptureKit + AppKit + the iTerm2 socket.
  This isn't a cross-platform Electron thing; it's a native Mac tool on purpose.

- Why paid + why so cheap: $8.99 once (no subscription) — priced to be a no-brainer if
  it saves you the alt-tab dance even a few times a day. 7-day trial, no card to start.

Genuinely want feedback on the capture flow and session picker — that's where I've
spent the most time.
```

## Notes for the day
- Reply to **every** comment, fast and non-defensively. HN rewards a present, candid maker.
- If someone asks "why not just paste?" — the answer is the step-count + never leaving the
  screen you're debugging on, plus the live session picker when you have several running.
- Don't argue about macOS-only or paid; state the reasoning once (above) and move on.
