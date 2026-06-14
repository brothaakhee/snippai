import SwiftUI
import SnippAIKit

/// Renders a `TerminalScreen` as a faithful, read-only mirror — monospaced cells,
/// ANSI colors, bold/italic/underline, and a block cursor.
struct TerminalMirrorView: View {
    let screen: TerminalScreen
    // Scales with Dynamic Type so low-vision users can read the mirror too.
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var font: Font { .system(size: fontSize, weight: .regular, design: .monospaced) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if screen.lines.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Connecting to session…").font(font)
                        }
                        .foregroundStyle(.secondary)
                        .padding(12)
                    } else {
                        ForEach(Array(screen.lines.enumerated()), id: \.offset) { index, line in
                            lineView(line, row: index)
                                .id(index)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .textSelection(.enabled)
            }
            .background(TerminalPalette.defaultBackground)
            // Re-pin on ANY content change (TUIs redraw in place without adding
            // lines), anchoring to the cursor row when present.
            .onChange(of: screen) { scrollToActive(proxy) }
            .onAppear { scrollToActive(proxy) }
        }
        // Expose the mirror as one labeled, value-bearing element for VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live terminal mirror")
        .accessibilityValue(screen.lastNonEmptyLine ?? "Connecting")
    }

    private func scrollToActive(_ proxy: ScrollViewProxy) {
        let target = screen.cursor?.y ?? screen.lines.indices.last
        guard let target else { return }
        if reduceMotion {
            proxy.scrollTo(target, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(target, anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func lineView(_ line: TermLine, row: Int) -> some View {
        let cursorX = (screen.cursor?.y == row) ? screen.cursor?.x : nil
        Text(attributedLine(line, cursorX: cursorX))
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Builds ONE AttributedString from the full line text and applies styles to
    /// character ranges. Building from a single string (rather than concatenating
    /// many per-run segments, each carrying a `.font`) keeps every space intact —
    /// SwiftUI's Text trims whitespace across attribute-run boundaries otherwise.
    private func attributedLine(_ line: TermLine, cursorX: Int?) -> AttributedString {
        var attr = AttributedString(line.plainText)
        var index = attr.startIndex
        for run in line.runs() where !run.text.isEmpty {
            let end = attr.index(index, offsetByCharacters: run.text.count)
            apply(run.style, to: &attr, in: index..<end)
            index = end
        }
        // Block cursor: invert the cell at cursorX (append a block if past EOL).
        if let cursorX {
            let total = attr.characters.count
            if cursorX < total {
                let start = attr.index(attr.startIndex, offsetByCharacters: cursorX)
                let stop = attr.index(start, offsetByCharacters: 1)
                attr[start..<stop].backgroundColor = TerminalPalette.defaultForeground
                attr[start..<stop].foregroundColor = TerminalPalette.defaultBackground
            } else {
                var block = AttributedString(" ")
                block.backgroundColor = TerminalPalette.defaultForeground
                block.foregroundColor = TerminalPalette.defaultBackground
                attr += block
            }
        }
        return attr
    }

    /// Applies a cell style to a range. Only sets `.font` for bold/italic (the base
    /// monospaced font comes from the view's `.font(font)`), minimizing font runs.
    private func apply(_ style: TermStyle, to attr: inout AttributedString,
                       in range: Range<AttributedString.Index>) {
        var fg = TerminalPalette.color(style.fg, isForeground: true)
        var bg = TerminalPalette.color(style.bg, isForeground: false)
        if style.inverse { swap(&fg, &bg) }
        if style.faint { fg = fg.opacity(0.6) }
        attr[range].foregroundColor = fg
        if style.inverse || style.bg != .defaultBackground {
            attr[range].backgroundColor = bg
        }
        if style.bold || style.italic {
            var f = Font.system(size: fontSize, weight: style.bold ? .bold : .regular, design: .monospaced)
            if style.italic { f = f.italic() }
            attr[range].font = f
        }
        if style.underline { attr[range].underlineStyle = .single }
        if style.strikethrough { attr[range].strikethroughStyle = .single }
    }
}
