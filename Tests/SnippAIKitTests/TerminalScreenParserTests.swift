import XCTest
@testable import SnippAIKit

final class TerminalScreenParserTests: XCTestCase {
    private func line(_ text: String, styles: [Iterm2_CellStyle] = []) -> Iterm2_LineContents {
        var l = Iterm2_LineContents()
        l.text = text
        l.style = styles
        return l
    }

    func testPlainLines() {
        var resp = Iterm2_GetBufferResponse()
        resp.contents = [line("hello"), line("world")]
        let screen = TerminalScreenParser.parse(resp)
        XCTAssertEqual(screen.lines.count, 2)
        XCTAssertEqual(screen.lines[0].plainText, "hello")
        XCTAssertEqual(screen.lines[1].plainText, "world")
        XCTAssertEqual(screen.columns, 5)
    }

    func testLastNonEmptyLine() {
        var resp = Iterm2_GetBufferResponse()
        resp.contents = [line("real content"), line("   "), line("")]
        let screen = TerminalScreenParser.parse(resp)
        XCTAssertEqual(screen.lastNonEmptyLine, "real content")
    }

    func testCursorMappedIntoReturnedRange() {
        var resp = Iterm2_GetBufferResponse()
        resp.contents = [line("ab"), line("cd")]
        var cursor = Iterm2_Coord(); cursor.x = 1; cursor.y = 11
        resp.cursor = cursor
        var range = Iterm2_Range(); range.location = 10; range.length = 2
        resp.range = range
        let screen = TerminalScreenParser.parse(resp)
        XCTAssertEqual(screen.cursor?.y, 1)   // 11 - 10
        XCTAssertEqual(screen.cursor?.x, 1)
    }

    func testCursorOutOfRangeIsDropped() {
        var resp = Iterm2_GetBufferResponse()
        resp.contents = [line("ab")]
        var cursor = Iterm2_Coord(); cursor.x = 0; cursor.y = 99
        resp.cursor = cursor
        let screen = TerminalScreenParser.parse(resp)
        XCTAssertNil(screen.cursor)   // 99 maps outside the single returned line
    }

    func testRunLengthStylesAndColors() {
        var red = Iterm2_CellStyle()
        red.fgStandard = 1           // palette index 1
        red.repeats = 2
        red.bold = true
        let screen = TerminalScreenParser.parse({
            var r = Iterm2_GetBufferResponse(); r.contents = [line("AB", styles: [red])]; return r
        }())
        let runs = screen.lines[0].runs()
        // Both cells share style -> one coalesced run.
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "AB")
        XCTAssertEqual(runs[0].style.fg, .palette(1))
        XCTAssertTrue(runs[0].style.bold)
    }

    func testNulAndNonBreakingSpacesFoldToPlainSpace() {
        // iTerm reports empty / column-positioned cells as NUL (U+0000); Ink-based
        // TUIs emit NBSP (U+00A0) and friends for padding. Both render zero/odd-width
        // in a text view and jam words together, so the parser folds them to U+0020.
        var resp = Iterm2_GetBufferResponse()
        resp.contents = [line("auto\u{00}mode\u{00}\u{00}on"),
                         line("PR\u{A0}#7\u{202F}open")]
        let screen = TerminalScreenParser.parse(resp)
        XCTAssertEqual(screen.lines[0].plainText, "auto mode  on")
        XCTAssertEqual(screen.lines[1].plainText, "PR #7 open")
        // Column count (and thus alignment) is preserved exactly.
        XCTAssertEqual(screen.lines[0].plainText.count, 13)
    }

    func testWideIdeographicSpaceIsPreserved() {
        // U+3000 occupies two columns; folding it to one space would break alignment.
        var resp = Iterm2_GetBufferResponse()
        resp.contents = [line("a\u{3000}b")]
        let screen = TerminalScreenParser.parse(resp)
        XCTAssertEqual(screen.lines[0].plainText, "a\u{3000}b")
    }

    func testPlainScreenFoldsNul() {
        // The Terminal.app text path runs through the same normalization.
        let screen = TerminalScreen.plain("new\u{00}task")
        XCTAssertEqual(screen.lines[0].plainText, "new task")
    }

    func testRGBColorParsing() {
        var rgb = Iterm2_RGBColor(); rgb.red = 10; rgb.green = 20; rgb.blue = 30
        var style = Iterm2_CellStyle(); style.fgRgb = rgb; style.repeats = 1
        let screen = TerminalScreenParser.parse({
            var r = Iterm2_GetBufferResponse(); r.contents = [line("X", styles: [style])]; return r
        }())
        XCTAssertEqual(screen.lines[0].cells.first?.style.fg, .rgb(10, 20, 30))
    }
}
