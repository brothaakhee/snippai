import SwiftUI
import AppKit
import SnippAIKit

/// Renders a `TerminalScreen` as a faithful, read-only mirror. Backed by an
/// `NSTextView` rather than SwiftUI `Text`: SwiftUI's Text trims whitespace on
/// runs that carry a `.font` attribute (so bold text loses its spaces), whereas
/// NSTextView renders per-range fonts + spaces + colors correctly — essential for
/// a monospaced terminal mirror.
struct TerminalMirrorView: NSViewRepresentable {
    let screen: TerminalScreen
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 12

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = TerminalPalette.defaultBackgroundNS
        textView.textContainerInset = NSSize(width: 12, height: 8)
        // Terminal lines must NOT wrap (wrapping breaks the monospaced grid) — let
        // long lines extend and clip on the right.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        let huge = CGFloat.greatestFiniteMagnitude
        textView.textContainer?.size = NSSize(width: huge, height: huge)
        textView.maxSize = NSSize(width: huge, height: huge)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = true
        scroll.backgroundColor = TerminalPalette.defaultBackgroundNS
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false   // clip long lines instead of scrolling
        scroll.scrollerStyle = .overlay
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        let attr = Self.attributed(screen, fontSize: fontSize)
        let wasAtBottom = isScrolledToBottom(scroll)
        textView.textStorage?.setAttributedString(attr)
        // Follow the tail (like a live terminal) unless the user scrolled up.
        if wasAtBottom { textView.scrollToEndOfDocument(nil) }
    }

    private func isScrolledToBottom(_ scroll: NSScrollView) -> Bool {
        let visible = scroll.contentView.documentVisibleRect
        let height = scroll.documentView?.bounds.height ?? 0
        return visible.maxY >= height - 24 || height <= visible.height
    }

    // MARK: - Build the styled string

    static func attributed(_ screen: TerminalScreen, fontSize: CGFloat) -> NSAttributedString {
        let base = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let result = NSMutableAttributedString()

        if screen.lines.isEmpty {
            return NSAttributedString(string: "Connecting to session…", attributes: [
                .font: base, .foregroundColor: NSColor.secondaryLabelColor])
        }

        for (row, line) in screen.lines.enumerated() {
            for run in line.runs() where !run.text.isEmpty {
                var attrs: [NSAttributedString.Key: Any] = [:]
                let style = run.style
                var font = style.bold ? bold : base
                if style.italic, let italic = applyItalic(font) { font = italic }
                attrs[.font] = font

                var fg = TerminalPalette.nsColor(style.fg)
                var bg = TerminalPalette.nsColor(style.bg)
                if style.inverse { swap(&fg, &bg) }
                if style.faint { fg = fg.withAlphaComponent(0.6) }
                attrs[.foregroundColor] = fg
                if style.inverse || style.bg != .defaultBackground {
                    attrs[.backgroundColor] = bg
                }
                if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if style.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                result.append(NSAttributedString(string: run.text, attributes: attrs))
            }
            if row < screen.lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: base]))
            }
        }

        // Block cursor: invert the cell at the cursor position.
        if let cursor = screen.cursor {
            let offset = lineStartOffset(screen, row: cursor.y) + cursor.x
            if offset >= 0, offset < result.length {
                result.addAttribute(.backgroundColor, value: TerminalPalette.nsColor(.defaultForeground),
                                    range: NSRange(location: offset, length: 1))
                result.addAttribute(.foregroundColor, value: TerminalPalette.nsColor(.defaultBackground),
                                    range: NSRange(location: offset, length: 1))
            }
        }
        return result
    }

    /// Character offset of the start of `row` (accounting for the \n joiners).
    private static func lineStartOffset(_ screen: TerminalScreen, row: Int) -> Int {
        guard row > 0 else { return 0 }
        var offset = 0
        for i in 0..<min(row, screen.lines.count) {
            offset += screen.lines[i].plainText.count + 1   // +1 for the joining \n
        }
        return offset
    }

    private static func applyItalic(_ font: NSFont) -> NSFont? {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: font.pointSize)
    }
}
