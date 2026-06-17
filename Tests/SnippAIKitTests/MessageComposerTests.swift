import XCTest
import Foundation
@testable import SnippAIKit

final class MessageComposerTests: XCTestCase {
    private func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    func testTextOnly() {
        XCTAssertEqual(composeMessage(text: "fix this", screenshots: []), "fix this")
    }

    func testTextIsTrimmedAndNewlinesFlattened() {
        XCTAssertEqual(composeMessage(text: "  line1\nline2  ", screenshots: []), "line1 line2")
    }

    func testSingleScreenshotWithText_preservesLegacyWording() {
        let out = composeMessage(text: "fix this", screenshots: [url("/tmp/a.png")])
        XCTAssertEqual(out, "fix this  (screenshot: /tmp/a.png)")
    }

    func testSingleScreenshotNoText_preservesLegacyWording() {
        let out = composeMessage(text: "   ", screenshots: [url("/tmp/a.png")])
        XCTAssertEqual(out, "Look at this screenshot: /tmp/a.png")
    }

    func testMultipleScreenshotsWithText() {
        let out = composeMessage(text: "compare these", screenshots: [url("/tmp/a.png"), url("/tmp/b.png")])
        XCTAssertEqual(out, "compare these  (screenshots: /tmp/a.png, /tmp/b.png)")
    }

    func testMultipleScreenshotsNoText() {
        let out = composeMessage(text: "", screenshots: [url("/tmp/a.png"), url("/tmp/b.png"), url("/tmp/c.png")])
        XCTAssertEqual(out, "Look at these screenshots: /tmp/a.png, /tmp/b.png, /tmp/c.png")
    }

    func testOutputIsSingleLine() {
        let out = composeMessage(text: "a\nb", screenshots: [url("/tmp/a.png"), url("/tmp/b.png")])
        XCTAssertFalse(out.contains("\n"), "composed message must stay on one line")
    }
}
