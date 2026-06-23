import Foundation

/// Thin async client for Lemon Squeezy's License API. These endpoints are keyed by the
/// license key itself — no secret API token is embedded in the app, so nothing sensitive
/// ships to users. Activation binds a key to a named "instance" (this Mac); validation
/// re-checks that binding; deactivation frees a seat so the user can move machines.
///
/// Docs: https://docs.lemonsqueezy.com/help/licensing/license-api
public struct LemonSqueezyClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "https://api.lemonsqueezy.com/v1")!,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Decoded response

    public struct LicenseResponse: Decodable, Sendable {
        public let activated: Bool?
        public let valid: Bool?
        public let deactivated: Bool?
        public let error: String?
        public let licenseKey: LicenseKeyInfo?
        public let instance: Instance?
        public let meta: Meta?
    }

    public struct LicenseKeyInfo: Decodable, Sendable {
        public let status: String?
        public let key: String?
        public let activationLimit: Int?
        public let activationUsage: Int?
        public let expiresAt: String?
    }

    public struct Instance: Decodable, Sendable {
        public let id: String?
        public let name: String?
    }

    public struct Meta: Decodable, Sendable {
        public let storeId: Int?
        public let productId: Int?
        public let variantId: Int?
        public let customerName: String?
        public let customerEmail: String?
    }

    public enum ClientError: LocalizedError {
        case transport(String)
        case decoding

        public var errorDescription: String? {
            switch self {
            case .transport(let m): return m
            case .decoding:         return "Couldn’t read the licensing server’s response."
            }
        }
    }

    // MARK: Endpoints

    public func activate(licenseKey: String, instanceName: String) async throws -> LicenseResponse {
        try await post("licenses/activate", [
            "license_key": licenseKey,
            "instance_name": instanceName,
        ])
    }

    public func validate(licenseKey: String, instanceId: String?) async throws -> LicenseResponse {
        var fields = ["license_key": licenseKey]
        if let instanceId { fields["instance_id"] = instanceId }
        return try await post("licenses/validate", fields)
    }

    public func deactivate(licenseKey: String, instanceId: String) async throws -> LicenseResponse {
        try await post("licenses/deactivate", [
            "license_key": licenseKey,
            "instance_id": instanceId,
        ])
    }

    // MARK: Transport

    private func post(_ path: String, _ fields: [String: String]) async throws -> LicenseResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncode(fields).data(using: .utf8)
        request.timeoutInterval = 20

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
        // LS returns a JSON body with `error` set (and HTTP 400) on bad keys — that's a
        // domain result, not a transport failure, so we decode regardless of status code.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(LicenseResponse.self, from: data) else {
            throw ClientError.decoding
        }
        return response
    }

    private func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
