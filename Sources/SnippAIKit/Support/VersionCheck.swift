import Foundation

/// Lightweight update check: the app fetches a small JSON feed (hosted alongside the
/// GitHub Release) and, if it advertises a newer version than the running build, surfaces
/// a prompt that opens the download page. No in-app installer — deliberately simple.

public enum VersionConfig {
    // The update feed + download page. The feed is a tiny JSON file published as a
    // GitHub Release asset (stable "latest" URL); the download page is the site.
    public static let feedURL = URL(string: "https://github.com/brothaakhee/snippai-releases/releases/latest/download/appcast.json")!
    public static let downloadPageURL = URL(string: "https://snippai.dev")!

    /// Only these hosts may be opened from the feed's download URL. The feed is fetched
    /// over HTTPS from GitHub, but if it were ever substituted, opening an arbitrary URL
    /// with `NSWorkspace.open` could launch a custom scheme handler — validate, don't trust.
    static let allowedDownloadHosts: Set<String> = ["github.com", "www.github.com", "snippai.dev", "www.snippai.dev"]

    /// The feed's download URL, but only if it's HTTPS to a host we ship from;
    /// anything else falls back to the pinned download page.
    public static func vettedDownloadURL(_ raw: String?) -> URL {
        guard let raw, let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), allowedDownloadHosts.contains(host)
        else { return downloadPageURL }
        return url
    }
}

/// Semantic-version comparison over dot-separated numeric components. Non-numeric
/// suffixes (e.g. "1.2.0-beta") are ignored per component, and missing trailing
/// components are treated as zero ("1.2" == "1.2.0").
public enum SemVer {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parse(candidate), b = parse(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func parse(_ version: String) -> [Int] {
        version.split(separator: ".").map { component in
            Int(component.prefix { $0.isNumber }) ?? 0
        }
    }
}

/// Fetches and decodes the update feed.
public struct VersionChecker: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public struct Feed: Decodable, Sendable {
        public let version: String
        public let url: String?
        public let notes: String?
    }

    public func fetchLatest(from url: URL = VersionConfig.feedURL) async throws -> Feed {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(Feed.self, from: data)
    }
}
