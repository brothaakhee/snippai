import SwiftUI
import AppKit

/// A search field that drives a list below it Spotlight-style: typing filters,
/// while ↑/↓ move the list selection, Return opens it, and Esc clears (then backs
/// out). The field keeps keyboard focus throughout — the arrow/return/escape keys
/// are intercepted via the field editor's command selectors rather than stolen
/// for cursor movement.
struct SessionSearchField: NSViewRepresentable {
    @Binding var text: String
    /// Bumped each time the picker is presented; drives a focus re-grab even when
    /// SwiftUI reuses the view (panel reuse) and never re-runs makeNSView.
    var focusToken: Int = 0
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onSubmit: () -> Void = {}
    /// Called when Esc is pressed on an already-empty field.
    var onCancelEmpty: () -> Void = {}

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search sessions…"
        field.delegate = context.coordinator
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        (field.cell as? NSSearchFieldCell)?.searchButtonCell?.isEnabled = false
        context.coordinator.grabFocus(field)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        // Re-focus exactly once per presentation (token change).
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            context.coordinator.grabFocus(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SessionSearchField
        var lastFocusToken: Int
        init(_ parent: SessionSearchField) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
        }

        /// Makes the field first responder on the next runloop tick (the window may
        /// not be attached yet when this is called from makeNSView/updateNSView).
        func grabFocus(_ field: NSSearchField) {
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                if window.firstResponder !== field && window.firstResponder !== field.currentEditor() {
                    window.makeFirstResponder(field)
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp(); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown(); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.text.isEmpty {
                    parent.onCancelEmpty()
                } else {
                    parent.text = ""
                    control.stringValue = ""
                }
                return true
            default:
                return false
            }
        }
    }
}
