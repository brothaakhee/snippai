import AppKit
import Observation
import SnippAIKit

/// Drives the lightweight update check: on launch (and on demand) it fetches the feed
/// and, if a newer version exists, publishes `available` so the menu bar and Settings can
/// offer a download. Opening it just sends the user to the download page.
@MainActor
@Observable
final class UpdateController {
    struct Update: Equatable {
        let version: String
        let url: URL
        let notes: String?
    }

    private(set) var available: Update?
    private(set) var lastCheckFailed = false

    let currentVersion: String
    private let checker = VersionChecker()

    /// Called when `available` changes so AppKit can refresh the menu item.
    var onChange: (() -> Void)?

    init(currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") {
        self.currentVersion = currentVersion
    }

    func checkInBackground() {
        Task { await check() }
    }

    func check() async {
        do {
            let feed = try await checker.fetchLatest()
            lastCheckFailed = false
            if SemVer.isNewer(feed.version, than: currentVersion) {
                let url = feed.url.flatMap(URL.init(string:)) ?? VersionConfig.downloadPageURL
                let update = Update(version: feed.version, url: url, notes: feed.notes)
                if update != available { available = update; onChange?() }
            } else if available != nil {
                available = nil; onChange?()
            }
        } catch {
            lastCheckFailed = true
        }
    }

    func openDownload() {
        NSWorkspace.shared.open(available?.url ?? VersionConfig.downloadPageURL)
    }
}
