import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SnippAIKit

/// Grabs the frontmost app's current text selection.
///
/// Preferred path is the Accessibility API (`kAXSelectedText`): instant, never
/// touches the clipboard, layout-independent, and can't fire a destructive copy
/// in a terminal/remote-desktop client. Only when AX yields nothing (Electron,
/// terminals, apps that don't expose selection) do we fall back to synthesizing
/// ⌘C — snapshotting and restoring the user's clipboard around it, with a delayed
/// sweep in case a slow app's copy lands after we've given up.
///
/// Returns nil when there's no usable selection (or no Accessibility grant, which
/// both paths require) — callers fall back to region + OCR.
@MainActor
enum SelectionGrabber {

    static func grab() async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        if let viaAX = selectedTextViaAX() { return viaAX }
        return await selectedTextViaCopy()
    }

    // MARK: - Accessibility (preferred)

    private static func selectedTextViaAX() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        // swiftlint:disable:next force_cast
        let el = element as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Synthetic ⌘C (fallback)

    private static func selectedTextViaCopy() async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.take(from: pasteboard)
        let baseline = pasteboard.changeCount

        postCopy()

        // ⌘C lands asynchronously in the frontmost app; poll for the pasteboard to
        // change AND actually carry a string (some apps declare types a beat before
        // populating them).
        var result: String?
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount != baseline,
               let s = pasteboard.string(forType: .string)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                result = s
                break
            }
        }

        // Only restore if OUR copy (or a late one) actually changed the clipboard —
        // an unconditional restore bumps changeCount and degrades promised types.
        if pasteboard.changeCount != baseline {
            snapshot.restore(to: pasteboard)
        } else {
            // No change yet: a slow app may copy after we've given up. Sweep once
            // more shortly and restore then, so the user's clipboard never ends up
            // silently replaced by the selection.
            scheduleClobberSweep(snapshot: snapshot, baseline: baseline)
        }
        return result
    }

    private static func scheduleClobberSweep(snapshot: PasteboardSnapshot, baseline: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if NSPasteboard.general.changeCount != baseline {
                snapshot.restore(to: NSPasteboard.general)
            }
        }
    }

    /// Posts ⌘C for the "c" key on the CURRENT layout (keycodes are positional —
    /// keycode 8 is "c" only on QWERTY). Falls back to the QWERTY position.
    private static func postCopy() {
        let keyCode = keyCodeForC() ?? CGKeyCode(kVK_ANSI_C)
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// The virtual keycode that produces "c" on the active keyboard layout.
    private static func keyCodeForC() -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0..<CGKeyCode(128) {
                var deadKeys: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeys, chars.count, &length, &chars)
                if status == noErr, length == 1, chars[0] == UInt16(UnicodeScalar("c").value) {
                    return code
                }
            }
            return nil
        }
    }
}
