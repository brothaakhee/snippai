import AppKit
import Carbon.HIToolbox

/// A single global hotkey registered via Carbon's `RegisterEventHotKey`.
///
/// Carbon hotkeys are the standard mechanism for menu-bar apps: they work
/// system-wide without requiring Accessibility permission (unlike global
/// `NSEvent` monitors).
@MainActor
final class HotKey {
    struct KeyCombo: Equatable, Hashable, Codable {
        var keyCode: UInt32
        var modifiers: UInt32   // Carbon modifier mask (cmdKey, optionKey, …)

        /// ⌥⇧4 — mnemonic for "screenshot" without colliding with the system's ⌘⇧4.
        static let defaultCombo = KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(optionKey | shiftKey))

        var displayString: String {
            modifierString + HotKey.keyName(for: keyCode)
        }

        /// Just the modifier glyphs (⌃⌥⇧⌘), in the canonical macOS order.
        var modifierString: String {
            var s = ""
            if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
            return s
        }

        /// A shortcut needs ⌘, ⌃, or ⌥ — a bare key (or shift-only) would fire while
        /// the user is just typing.
        var hasRequiredModifier: Bool {
            modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
        }

        /// Non-nil when this combo matches a well-known macOS system shortcut that the
        /// OS will intercept before SnippAI ever sees it (so registering it is futile
        /// unless the user disables the system binding first).
        var systemShortcutConflict: String? {
            knownSystemShortcuts[self]
        }

        /// Builds a combo from a recorded key event. Returns nil for modifier-only
        /// presses (no actual key) so the recorder keeps waiting.
        static func from(event: NSEvent) -> KeyCombo? {
            let flags = event.modifierFlags
            var carbon: UInt32 = 0
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            return KeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbon)
        }
    }

    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private let id: UInt32
    let combo: KeyCombo
    /// Whether `RegisterEventHotKey` accepted the combo. False means another app
    /// already owns it (the OS rejects duplicate registrations).
    let isRegistered: Bool

    init(combo: KeyCombo, id: UInt32 = 1, action: @escaping () -> Void) {
        self.combo = combo
        self.id = id
        HotKeyCenter.shared.install()
        HotKeyCenter.shared.register(id: id, action: action)

        let hotKeyID = EventHotKeyID(signature: OSType(0x534E5049 /* 'SNPI' */), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers,
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            self.hotKeyRef = ref
            self.isRegistered = true
        } else {
            self.isRegistered = false
        }
    }

    deinit {
        // The hotkey lives for the app's lifetime; only release the Carbon ref.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }

    // MARK: - Key naming

    /// A human-readable label for a virtual key code. Handles the special keys with
    /// their canonical glyphs and resolves every printable key through the current
    /// keyboard layout, so it's correct on non-US layouts too.
    nonisolated static func keyName(for keyCode: UInt32) -> String {
        if let special = snippaiSpecialKeyNames[Int(keyCode)] { return special }
        if let ch = character(for: keyCode), !ch.isEmpty { return ch }
        return "Key \(keyCode)"
    }

    /// Resolves the printable character a key produces on the active layout.
    private nonisolated static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

// File-scope (non-isolated) lookup tables — pure immutable data shared by the
// non-isolated `KeyCombo` helpers above.

private let snippaiSpecialKeyNames: [Int: String] = [
    kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌅", kVK_Tab: "⇥", kVK_Space: "Space",
    kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Help: "?⃝",
    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
]

/// Known macOS system shortcuts SnippAI can't reliably claim (the OS eats them).
/// Keyed by combo so lookups are O(1); values are user-facing explanations.
private let knownSystemShortcuts: [HotKey.KeyCombo: String] = {
    let cmdShift = UInt32(cmdKey | shiftKey)
    return [
        HotKey.KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: cmdShift): "macOS uses ⌘⇧3 for a full-screen screenshot.",
        HotKey.KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: cmdShift): "macOS uses ⌘⇧4 for its own region screenshot.",
        HotKey.KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: cmdShift): "macOS uses ⌘⇧5 for the screenshot toolbar.",
        HotKey.KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)): "macOS uses ⌘Space for Spotlight.",
    ]
}()

/// Routes Carbon hotkey-pressed events to the registered Swift closures.
@MainActor
private final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, eventRef, _ in
            guard let eventRef else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            // Carbon hotkey events are delivered on the main run loop.
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id: hkID.id) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handlerRef)
    }

    func register(id: UInt32, action: @escaping () -> Void) { actions[id] = action }
    func unregister(id: UInt32) { actions[id] = nil }

    func fire(id: UInt32) {
        actions[id]?()
    }
}
