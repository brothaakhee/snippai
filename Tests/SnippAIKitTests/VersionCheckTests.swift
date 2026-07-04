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

    // MARK: - Download URL vetting

    func testVettedURLAcceptsAllowedHostsOverHTTPS() {
        let github = "https://github.com/brothaakhee/snippai-releases/releases/latest/download/SnippAI.dmg"
        XCTAssertEqual(VersionConfig.vettedDownloadURL(github).absoluteString, github)
        XCTAssertEqual(VersionConfig.vettedDownloadURL("https://snippai.dev/download"),
                       URL(string: "https://snippai.dev/download"))
        // Host matching is case-insensitive.
        XCTAssertEqual(VersionConfig.vettedDownloadURL("https://GitHub.com/x"), URL(string: "https://GitHub.com/x"))
    }

    func testVettedURLRejectsWrongSchemeOrHost() {
        // Non-HTTPS schemes must not be opened, even on an allowed-looking host.
        XCTAssertEqual(VersionConfig.vettedDownloadURL("http://github.com/x"), VersionConfig.downloadPageURL)
        XCTAssertEqual(VersionConfig.vettedDownloadURL("file:///etc/passwd"), VersionConfig.downloadPageURL)
        XCTAssertEqual(VersionConfig.vettedDownloadURL("x-custom-scheme://payload"), VersionConfig.downloadPageURL)
        // Unlisted hosts fall back — including lookalikes and subdomains.
        XCTAssertEqual(VersionConfig.vettedDownloadURL("https://evil.example.com/SnippAI.dmg"), VersionConfig.downloadPageURL)
        XCTAssertEqual(VersionConfig.vettedDownloadURL("https://github.com.evil.example/x"), VersionConfig.downloadPageURL)
        XCTAssertEqual(VersionConfig.vettedDownloadURL("https://sub.github.com/x"), VersionConfig.downloadPageURL)
    }

    func testVettedURLFallsBackOnMissingOrUnparseable() {
        XCTAssertEqual(VersionConfig.vettedDownloadURL(nil), VersionConfig.downloadPageURL)
        XCTAssertEqual(VersionConfig.vettedDownloadURL(""), VersionConfig.downloadPageURL)
        XCTAssertEqual(VersionConfig.vettedDownloadURL("not a url at all"), VersionConfig.downloadPageURL)
    }
}
