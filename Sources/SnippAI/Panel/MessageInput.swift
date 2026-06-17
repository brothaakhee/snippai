import SwiftUI
import AppKit
import SnippAIKit

/// A multi-line message field with chat-style submit semantics:
/// **Return = send**, **Shift+Return = newline**. SwiftUI's `TextEditor` can't do
/// this (it never fires `.onSubmit` and always inserts a newline), so we wrap an
/// `NSTextView` and intercept `insertNewline`.
struct MessageInput: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }
    /// ⌘+arrow while composing: cycle the target (+1 next, -1 previous).
    var onCycleTarget: (Int) -> Void = { _ in }
    var focusOnAppear: Bool = true
    // The text the user authors must scale with Dynamic Type too (NSTextView
    // doesn't read SwiftUI's environment), matching the placeholder above it.
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 13

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        textView.onFocusChange = onFocusChange
        textView.onCycleTarget = onCycleTarget
        textView.string = text
        textView.font = .systemFont(ofSize: fontSize)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 3, height: 7)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .allowed

        if focusOnAppear {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? SubmitTextView else { return }
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        textView.onFocusChange = onFocusChange
        textView.onCycleTarget = onCycleTarget
        if textView.font?.pointSize != fontSize { textView.font = .systemFont(ofSize: fontSize) }
        if textView.string != text { textView.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: MessageInput
        init(_ parent: MessageInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class SubmitTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }
    var onCycleTarget: (Int) -> Void = { _ in }

    // ⌘+arrow cycles the target instead of moving the caret to line/document ends.
    // NB: arrow keys also carry .function/.numericPad, so we must check the four
    // real modifiers individually — not compare the whole mask to .command.
    override func keyDown(with event: NSEvent) {
        let m = event.modifierFlags
        if let delta = targetCycleDelta(
            keyCode: Int(event.keyCode),
            command: m.contains(.command), option: m.contains(.option),
            control: m.contains(.control), shift: m.contains(.shift)) {
            onCycleTarget(delta)
            return
        }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            super.insertNewline(sender)   // Shift+Return → newline
        } else {
            onSubmit()                    // Return → send
        }
    }

    // NSTextView consumes Escape (cancelOperation) instead of letting SwiftUI's
    // onExitCommand fire, so route it explicitly to "back to picker".
    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange(false) }
        return ok
    }
}
