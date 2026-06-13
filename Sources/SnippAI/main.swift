import AppKit

// SnippAI — a menu-bar app (no dock icon). Capture a screenshot region and fire
// it, with a message, straight into a live iTerm2 session.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
