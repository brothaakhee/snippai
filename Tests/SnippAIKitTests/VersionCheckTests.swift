import XCTest
@testable import SnippAIKit

final class VersionCheckTests: XCTestCase {
    func testNewerPatchMajorMinor() {
        XCTAssertTrue(SemVer.isNewer("1.2.1", than: "1.2.0"))
        XCTAssertTrue(SemVer.isNewer("1.3.0", than: "1.2.9"))
        XCTAssertTrue(SemVer.isNewer("2.0.0", than: "1.9.9"))
    }

    func testNotNewerWhenEqualOrOlder() {
        XCTAssertFalse(SemVer.isNewer("1.2.0", than: "1.2.0"))
        XCTAssertFalse(SemVer.isNewer("1.2.0", than: "1.2.1"))
        XCTAssertFalse(SemVer.isNewer("0.9.0", than: "1.0.0"))
    }

    func testMissingComponentsTreatedAsZero() {
        XCTAssertFalse(SemVer.isNewer("1.2", than: "1.2.0"))
        XCTAssertTrue(SemVer.isNewer("1.2.1", than: "1.2"))
        XCTAssertTrue(SemVer.isNewer("1.3", than: "1.2.5"))
    }

    func testNonNumericSuffixIgnoredPerComponent() {
        XCTAssertFalse(SemVer.isNewer("1.2.0-beta", than: "1.2.0"))
        XCTAssertTrue(SemVer.isNewer("1.2.1-rc1", than: "1.2.0"))
    }

    func testFeedDecodes() throws {
        let feed = try JSONDecoder().decode(
            VersionChecker.Feed.self,
            from: Data(#"{"version":"1.4.0","url":"https://example.com/x.dmg","notes":"Fixes"}"#.utf8))
        XCTAssertEqual(feed.version, "1.4.0")
        XCTAssertEqual(feed.url, "https://example.com/x.dmg")
        XCTAssertEqual(feed.notes, "Fixes")
    }
}
