import AppKit
import Carbon.HIToolbox

/// A single global hotkey registered via Carbon's `RegisterEventHotKey`.
///
/// Carbon hotkeys are the standard mechanism for menu-bar apps: they work
/// system-wide without requiring Accessibility permission (unlike global
/// `NSEvent` monitors).
@MainActor
final class HotKey {
    struct KeyCombo: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32   // Carbon modifier mask (cmdKey, optionKey, …)

        /// ⌥⌘4 — mnemonic for "screenshot" without colliding with the system's ⌘⇧4.
        static let defaultCombo = KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | optionKey))

        var displayString: String {
            var s = ""
            if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
            s += HotKey.keyName(for: keyCode)
            return s
        }
    }

    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private let id: UInt32
    private let combo: KeyCombo

    init(combo: KeyCombo, id: UInt32 = 1, action: @escaping () -> Void) {
        self.combo = combo
        self.id = id
        HotKeyCenter.shared.install()
        HotKeyCenter.shared.register(id: id, action: action)

        let hotKeyID = EventHotKeyID(signature: OSType(0x534E5049 /* 'SNPI' */), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers,
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { self.hotKeyRef = ref }
    }

    deinit {
        // The hotkey lives for the app's lifetime; only release the Carbon ref.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }

    nonisolated static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"; case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"; case kVK_Space: return "Space"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_A: return "A"
        default:
            // Fall back to the character produced by the key, uppercased.
            return "Key\(keyCode)"
        }
    }
}

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
