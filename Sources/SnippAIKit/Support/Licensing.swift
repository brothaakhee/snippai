import Foundation

/// UI-agnostic licensing core: configuration, the trial clock, and the rules that
/// turn a Lemon Squeezy API response into a yes/no entitlement. Kept free of
/// AppKit/SwiftUI so it's unit-testable and reusable.

// MARK: - Configuration

public enum LicenseConfig {
    // Lemon Squeezy product identity. A variant ID is globally unique in LS, so matching
    // on it alone locks activation to *this* product — a key minted by any other product
    // is rejected. `storeId` is optional defense-in-depth; 0 means "don't enforce".
    // These are the *live* store/variant records. Lemon Squeezy keeps test-mode data in a
    // parallel set of records with their own IDs, and the dashboard hands you whichever one
    // matches the test-mode toggle — so re-copy these with test mode OFF, never with it on.
    public static let storeId = 413478
    public static let variantId = 1828338
    public static let checkoutURL = URL(string: "https://snippai.lemonsqueezy.com/checkout/buy/4f50afb5-00e4-41d5-a728-d555cf2a6fcd")!

    /// Free trial length before the paywall engages.
    public static let trialDays = 7
    /// How many times an expired user may "Maybe later" past the paywall before a
    /// license becomes mandatory to capture.
    public static let graceDismissals = 5
    /// A licensed app may run this long without a successful re-validation (e.g. fully
    /// offline) before the license is treated as lapsed until it can phone home again.
    public static let offlineRevalidationGraceDays = 14
}

// MARK: - Entitlement

public enum Entitlement: Equatable {
    case licensed
    case trial(daysRemaining: Int)
    case expired
}

// MARK: - Trial clock

/// Pure trial-window math. `firstLaunch`/`now` are passed in so tests stay deterministic
/// and the app can substitute a rollback-resistant "now".
public enum TrialClock {
    public static func daysRemaining(firstLaunch: Date, now: Date, trialDays: Int = LicenseConfig.trialDays) -> Int {
        let duration = Double(trialDays) * 86_400
        let remaining = duration - now.timeIntervalSince(firstLaunch)
        guard remaining > 0 else { return 0 }
        return Int((remaining / 86_400).rounded(.up))
    }

    public static func isExpired(firstLaunch: Date, now: Date, trialDays: Int = LicenseConfig.trialDays) -> Bool {
        now.timeIntervalSince(firstLaunch) >= Double(trialDays) * 86_400
    }
}

// MARK: - Lemon Squeezy response → entitlement

extension LemonSqueezyClient {
    public enum LicenseCheck: Equatable {
        case valid
        case invalid(reason: String)
    }

    /// Interprets an activate/validate response against our product config. A license is
    /// accepted only when the call succeeded, the key status is `active`, and (when
    /// configured) it was minted by our store + variant.
    public static func evaluate(_ response: LicenseResponse,
                                storeId: Int = LicenseConfig.storeId,
                                variantId: Int = LicenseConfig.variantId) -> LicenseCheck {
        if let error = response.error, !error.isEmpty {
            return .invalid(reason: error)
        }
        // Surface a specific reason for a known-bad status even when the success flag is
        // false (LS reports `valid:false` alongside `status:"expired"`).
        let status = response.licenseKey?.status?.lowercased()
        switch status {
        case "expired":  return .invalid(reason: "This license has expired.")
        case "disabled": return .invalid(reason: "This license has been disabled.")
        default: break
        }
        // `validate` reports `valid`; `activate` reports `activated`. Treat either truthy
        // flag as the success signal for its respective call.
        let succeeded = (response.valid ?? response.activated) ?? false
        guard succeeded else {
            return .invalid(reason: "This license key isn’t valid.")
        }
        guard status == "active" else {
            return .invalid(reason: "This license isn’t active.")
        }
        if storeId != 0, let s = response.meta?.storeId, s != storeId {
            return .invalid(reason: "This license is for a different product.")
        }
        if variantId != 0, let v = response.meta?.variantId, v != variantId {
            return .invalid(reason: "This license is for a different product.")
        }
        return .valid
    }
}
