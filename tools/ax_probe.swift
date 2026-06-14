// SnippAI Accessibility probe for the Claude desktop app.
//
// Answers the README's open question: is the Claude desktop app a viable target
// adapter via the macOS Accessibility (AX) API — are conversations/sessions
// individually addressable, and is there a settable text input we could inject a
// message + screenshot path into?
//
// Run:  swift tools/ax_probe.swift
// Needs: Accessibility permission for the controlling process (terminal / Claude Code).
import Cocoa
import ApplicationServices

let bundleID = "com.anthropic.claudefordesktop"

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}
func str(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
func children(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
func settable(_ el: AXUIElement, _ name: String) -> Bool {
    var b = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(el, name as CFString, &b) == .success && b.boolValue
}

// Stats accumulated during the walk.
var totalNodes = 0
var roleCounts: [String: Int] = [:]
var textInputs: [(path: String, role: String, settable: Bool, valueLen: Int)] = []
var webAreas = 0

func valueString(_ el: AXUIElement) -> String {
    if let s = str(el, kAXValueAttribute as String) { return s }
    if let n = attr(el, kAXValueAttribute as String) as? NSNumber { return n.stringValue }
    return ""
}

func walk(_ el: AXUIElement, depth: Int, path: String, maxDepth: Int) {
    guard depth <= maxDepth, totalNodes < 6000 else { return }
    totalNodes += 1
    let role = str(el, kAXRoleAttribute as String) ?? "?"
    let subrole = str(el, kAXSubroleAttribute as String) ?? ""
    roleCounts[role, default: 0] += 1
    if role == "AXWebArea" { webAreas += 1 }

    let title = str(el, kAXTitleAttribute as String) ?? ""
    let desc = str(el, kAXDescriptionAttribute as String) ?? ""
    let kids = children(el)

    // Print a compact tree for the top levels so we can see window/session structure.
    if depth <= 4 {
        let label = [title, desc].filter { !$0.isEmpty }.joined(separator: " / ")
        let indent = String(repeating: "  ", count: depth)
        print("\(indent)[\(role)\(subrole.isEmpty ? "" : ":\(subrole)")] \(label.prefix(70))  (\(kids.count) kids)")
    }

    // Record text-entry candidates.
    if role == "AXTextArea" || role == "AXTextField" || subrole == "AXSearchField" {
        let canSet = settable(el, kAXValueAttribute as String)
        textInputs.append((path, role, canSet, valueString(el).count))
    }

    for (i, child) in kids.enumerated() {
        walk(child, depth: depth + 1, path: "\(path)/\(role)[\(i)]", maxDepth: maxDepth)
    }
}

// ---- main ----
print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
guard AXIsProcessTrusted() else {
    print("==> NOT trusted. Grant Accessibility to the controlling app (System Settings → Privacy & Security → Accessibility), then re-run.")
    // Trigger the prompt for next time.
    let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    exit(2)
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    print("Claude desktop app not running."); exit(1)
}
print("Claude pid=\(app.processIdentifier), activating to ensure windows are live…")
app.activate()
Thread.sleep(forTimeInterval: 0.8)

let axApp = AXUIElementCreateApplication(app.processIdentifier)

// Coax Chromium into exposing its web-content a11y tree (off by default until an
// assistive client asks). Both attributes are used by Electron/Chromium builds.
for key in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
    let err = AXUIElementSetAttributeValue(axApp, key as CFString, kCFBooleanTrue)
    print("set \(key): \(err == .success ? "ok" : "err(\(err.rawValue))")")
}
Thread.sleep(forTimeInterval: 1.2) // give the renderer time to build the tree

let windows = attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
print("\n=== windows: \(windows.count) ===")
for (i, w) in windows.enumerated() {
    print("\nWINDOW \(i): title=\(str(w, kAXTitleAttribute as String) ?? "?")")
    walk(w, depth: 0, path: "w\(i)", maxDepth: 60)
}

print("\n==================== AX PROBE SUMMARY ====================")
print("total nodes walked: \(totalNodes)   AXWebArea count: \(webAreas)")
print("role histogram (top 15):")
for (role, n) in roleCounts.sorted(by: { $0.value > $1.value }).prefix(15) {
    print(String(format: "  %5d  %@", n, role))
}
print("text-entry candidates: \(textInputs.count)")
for t in textInputs.prefix(12) {
    print("  - \(t.role)  settable=\(t.settable)  valueLen=\(t.valueLen)  at \(t.path)")
}
let verdict: String
if textInputs.contains(where: { $0.settable }) {
    verdict = "VIABLE-ish: a settable text input is exposed via AX."
} else if totalNodes < 50 || webAreas == 0 {
    verdict = "BLOCKED: Chromium web content not exposed to AX (opaque web area / empty tree)."
} else {
    verdict = "PARTIAL: tree exposed but no settable text input found."
}
print("VERDICT: \(verdict)")
print("=========================================================")
