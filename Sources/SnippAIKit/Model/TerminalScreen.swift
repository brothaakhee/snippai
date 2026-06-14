import Foundation

/// A resolved terminal color. Kept framework-agnostic; the UI layer maps these
/// to `NSColor`/`Color`. Palette indices follow the xterm-256 convention.
public enum TermColor: Equatable, Sendable {
    case defaultForeground
    case defaultBackground
    case palette(Int)          // 0–255 xterm palette index
    case rgb(UInt8, UInt8, UInt8)
}

public struct TermStyle: Equatable, Sendable {
    public var fg: TermColor = .defaultForeground
    public var bg: TermColor = .defaultBackground
    public var bold = false
    public var faint = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var inverse = false

    public static let `default` = TermStyle()
}

/// One display cell: the glyph(s) it shows and the style applied.
public struct TermCell: Equatable, Sendable {
    public var text: String
    public var style: TermStyle
    public init(text: String, style: TermStyle) { self.text = text; self.style = style }
}

public struct TermLine: Equatable, Sendable {
    public var cells: [TermCell]
    public init(cells: [TermCell]) { self.cells = cells }

    /// Coalesces adjacent cells with identical styles into styled runs — far
    /// fewer attributed segments for the renderer than one-per-cell.
    public func runs() -> [(text: String, style: TermStyle)] {
        var out: [(String, TermStyle)] = []
        for cell in cells {
            if var last = out.last, last.1 == cell.style {
                last.0 += cell.text
                out[out.count - 1] = last
            } else {
                out.append((cell.text, cell.style))
            }
        }
        return out.map { (text: $0.0, style: $0.1) }
    }

    public var plainText: String { cells.map(\.text).joined() }
}

public struct TermCursor: Equatable, Sendable {
    public var x: Int
    public var y: Int   // row index within `lines`
}

/// A snapshot of a session's visible screen.
public struct TerminalScreen: Equatable, Sendable {
    public var lines: [TermLine]
    public var cursor: TermCursor?
    public var columns: Int
    public var rows: Int

    public static let empty = TerminalScreen(lines: [], cursor: nil, columns: 0, rows: 0)

    /// The non-blank text of the screen, bottom-most non-empty line last.
    public var lastNonEmptyLine: String? {
        for line in lines.reversed() {
            let t = line.plainText.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return nil
    }
}

extension TerminalScreen {
    /// Builds a screen from plain text (e.g. Terminal.app's AppleScript `contents`),
    /// which carries no per-cell color/style or cursor — every cell uses the default
    /// style. Trailing blank lines are trimmed so the mirror isn't mostly empty.
    public static func plain(_ text: String) -> TerminalScreen {
        var rawLines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        while let last = rawLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            rawLines.removeLast()
        }
        var columns = 0
        let lines = rawLines.map { line -> TermLine in
            columns = max(columns, line.count)
            return TermLine(cells: line.map { TermCell(text: String($0), style: .default) })
        }
        return TerminalScreen(lines: lines, cursor: nil, columns: columns, rows: lines.count)
    }
}

// MARK: - Parsing from the iTerm2 buffer response

public enum TerminalScreenParser {
    public static func parse(_ response: Iterm2_GetBufferResponse) -> TerminalScreen {
        var lines: [TermLine] = []
        lines.reserveCapacity(response.contents.count)
        var maxColumns = 0
        for line in response.contents {
            let cells = parseLine(line)
            maxColumns = max(maxColumns, cells.count)
            lines.append(TermLine(cells: cells))
        }

        var cursor: TermCursor?
        if response.hasCursor {
            // Cursor y is absolute (incl. scrollback); map into the returned range.
            let firstLine = response.hasRange ? Int(response.range.location) : 0
            let row = Int(response.cursor.y) - firstLine
            if row >= 0 && row < lines.count {
                cursor = TermCursor(x: Int(response.cursor.x), y: row)
            }
        }
        return TerminalScreen(lines: lines, cursor: cursor, columns: maxColumns, rows: lines.count)
    }

    private static func parseLine(_ line: Iterm2_LineContents) -> [TermCell] {
        let scalars = Array(line.text.unicodeScalars)

        // Expand the run-length cell widths (code points per cell).
        var cellWidths: [Int] = []
        if line.codePointsPerCell.isEmpty {
            cellWidths = Array(repeating: 1, count: scalars.count)
        } else {
            for run in line.codePointsPerCell {
                let n = run.hasNumCodePoints ? Int(run.numCodePoints) : 1
                let repeats = max(1, Int(run.repeats))
                cellWidths.append(contentsOf: Array(repeating: n, count: repeats))
            }
        }

        // Expand the run-length styles to one entry per cell.
        var cellStyles: [TermStyle] = []
        for run in line.style {
            let style = convert(run)
            let repeats = max(1, Int(run.repeats))
            cellStyles.append(contentsOf: Array(repeating: style, count: repeats))
        }

        var cells: [TermCell] = []
        var scalarIndex = 0
        for (cellIndex, width) in cellWidths.enumerated() {
            guard scalarIndex < scalars.count else { break }
            let end = min(scalarIndex + max(1, width), scalars.count)
            var view = String.UnicodeScalarView()
            for s in scalars[scalarIndex..<end] { view.append(s) }
            scalarIndex = end
            let glyph = String(view)
            let style = cellIndex < cellStyles.count ? cellStyles[cellIndex] : .default
            cells.append(TermCell(text: glyph.isEmpty ? " " : glyph, style: style))
        }
        // Any trailing scalars with no width info: append as single cells.
        while scalarIndex < scalars.count {
            var view = String.UnicodeScalarView(); view.append(scalars[scalarIndex])
            cells.append(TermCell(text: String(view), style: .default))
            scalarIndex += 1
        }
        return cells
    }

    private static func convert(_ s: Iterm2_CellStyle) -> TermStyle {
        var style = TermStyle()
        style.fg = convertColor(fg: s)
        style.bg = convertColor(bg: s)
        style.bold = s.bold
        style.faint = s.faint
        style.italic = s.italic
        style.underline = s.underline
        style.strikethrough = s.strikethrough
        style.inverse = s.inverse
        return style
    }

    private static func convertColor(fg s: Iterm2_CellStyle) -> TermColor {
        switch s.fgColor {
        case .fgStandard(let idx): return .palette(Int(idx))
        case .fgRgb(let c): return .rgb(UInt8(c.red & 0xFF), UInt8(c.green & 0xFF), UInt8(c.blue & 0xFF))
        case .fgAlternate(let alt): return alt == .reversedDefault ? .defaultBackground : .defaultForeground
        case .fgAlternatePlacementX, .none: return .defaultForeground
        }
    }

    private static func convertColor(bg s: Iterm2_CellStyle) -> TermColor {
        switch s.bgColor {
        case .bgStandard(let idx): return .palette(Int(idx))
        case .bgRgb(let c): return .rgb(UInt8(c.red & 0xFF), UInt8(c.green & 0xFF), UInt8(c.blue & 0xFF))
        case .bgAlternate(let alt): return alt == .reversedDefault ? .defaultForeground : .defaultBackground
        case .bgAlternatePlacementY, .none: return .defaultBackground
        }
    }
}
