import SwiftUI
import SnippAIKit

/// Renders a `TerminalScreen` as a faithful, read-only mirror — monospaced cells,
/// ANSI colors, bold/italic/underline, and a block cursor.
struct TerminalMirrorView: View {
    let screen: TerminalScreen
    var fontSize: CGFloat = 12
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

    private func attributedLine(_ line: TermLine, cursorX: Int?) -> AttributedString {
        var result = AttributedString()
        var column = 0
        for run in line.runs() {
            // Split the run if the cursor falls inside it, so we can invert one cell.
            if let cursorX, cursorX >= column, cursorX < column + run.text.count {
                let chars = Array(run.text)
                let before = String(chars[0..<(cursorX - column)])
                let at = String(chars[cursorX - column])
                let after = String(chars[(cursorX - column + 1)...])
                if !before.isEmpty { result += segment(before, style: run.style) }
                result += segment(at.isEmpty ? " " : at, style: run.style, cursor: true)
                if !after.isEmpty { result += segment(after, style: run.style) }
            } else {
                result += segment(run.text, style: run.style)
            }
            column += run.text.count
        }
        // Cursor past the end of the line content.
        if let cursorX, cursorX >= column {
            let pad = String(repeating: " ", count: cursorX - column)
            if !pad.isEmpty { result += segment(pad, style: .default) }
            result += segment(" ", style: .default, cursor: true)
        }
        return result
    }

    private func segment(_ text: String, style: TermStyle, cursor: Bool = false) -> AttributedString {
        var seg = AttributedString(text)
        let inverse = style.inverse != cursor   // cursor inverts on top of any existing inverse
        var fg = TerminalPalette.color(style.fg, isForeground: true)
        var bg = TerminalPalette.color(style.bg, isForeground: false)
        if inverse { swap(&fg, &bg) }
        if style.faint { fg = fg.opacity(0.6) }
        seg.foregroundColor = fg
        if inverse || style.bg != .defaultBackground {
            seg.backgroundColor = bg
        }
        var font = Font.system(size: fontSize, weight: style.bold ? .bold : .regular, design: .monospaced)
        if style.italic { font = font.italic() }
        seg.font = font
        if style.underline { seg.underlineStyle = .single }
        if style.strikethrough { seg.strikethroughStyle = .single }
        return seg
    }
}
