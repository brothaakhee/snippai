import SwiftUI
import AppKit
import CoreText
import SnippAIKit

/// Renders a `TerminalScreen` as a faithful, read-only mirror. Backed by an
/// `NSTextView` rather than SwiftUI `Text`: SwiftUI's Text trims whitespace on
/// runs that carry a `.font` attribute (so bold text loses its spaces), whereas
/// NSTextView renders per-range fonts + spaces + colors correctly — essential for
/// a monospaced terminal mirror.
struct TerminalMirrorView: NSViewRepresentable {
    let screen: TerminalScreen
    /// Changes when the user does something that should snap the mirror to the
    /// bottom regardless of prior scroll position — switching target sessions, or
    /// sending a message. Plain live updates keep "follow only if already at bottom".
    var scrollKey: String = ""
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 12

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastScrollKey: String?
    }

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
        // Force a snap to the bottom when the session changed or a message was just
        // sent; otherwise follow the tail only if the user was already at the bottom
        // (so reading scrollback isn't yanked away by live updates).
        let forced = context.coordinator.lastScrollKey != scrollKey
        context.coordinator.lastScrollKey = scrollKey
        let shouldStick = forced || isScrolledToBottom(scroll)
        textView.textStorage?.setAttributedString(attr)
        guard shouldStick else { return }
        // NSTextView lays out lazily, so the document height is stale right after
        // replacing the text — force layout before scrolling, then scroll again on
        // the next runloop in case layout finalized afterwards (else the scroll
        // lands short of the real bottom, the bug being fixed here).
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
        }
        textView.scrollToEndOfDocument(nil)
        DispatchQueue.main.async { [weak textView] in textView?.scrollToEndOfDocument(nil) }
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
                result.append(NSAttributedString(string: sanitized(run.text, font: base), attributes: attrs))
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

    /// Coverage cache (main-thread only — the mirror renders on the main actor).
    private static var glyphCoverage: [UInt32: Bool] = [:]

    /// Whether the mirror font can actually draw a scalar. ASCII is always covered;
    /// other scalars are probed once via CoreText and cached.
    private static func isRenderable(_ scalar: Unicode.Scalar, font: NSFont) -> Bool {
        if scalar.value < 0x80 { return true }
        if let hit = glyphCoverage[scalar.value] { return hit }
        let units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        let ok = units.withUnsafeBufferPointer {
            CTFontGetGlyphsForCharacters(font as CTFont, $0.baseAddress!, &glyphs, units.count)
        }
        let covered = ok && glyphs.allSatisfy { $0 != 0 }
        glyphCoverage[scalar.value] = covered
        return covered
    }

    /// Replaces glyphs the mirror font can't draw — e.g. the Nerd Font Private-Use
    /// icons in Claude Code's TUI ("Read", "Edit" …) — with a space. Otherwise those
    /// codepoints go through CoreText's nondeterministic fallback, which resolves
    /// differently across the mirror's frequent re-renders and flickers (icon ↔ tofu).
    /// A blank keeps column alignment and is stable; the surrounding text is unchanged.
    private static func sanitized(_ text: String, font: NSFont) -> String {
        guard text.unicodeScalars.contains(where: { $0.value >= 0x80 }) else { return text }
        var view = String.UnicodeScalarView()
        for s in text.unicodeScalars { view.append(isRenderable(s, font: font) ? s : " ") }
        return String(view)
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
