import Foundation
import Observation
import SnippAIKit

/// Source of truth for trial + license state. Persists the trial start, the activated
/// license, and the paywall-deferral count; computes the live `Entitlement`; and gates
/// capture. Trial timing is resistant to a naive clock rollback via a monotonic
/// high-water mark, and the first-launch date is mirrored to Application Support so
/// clearing UserDefaults doesn't silently reset the trial.
@MainActor
@Observable
final class LicenseStore {
    // Persisted, observable state.
    private(set) var licenseKey: String?
    private(set) var instanceId: String?
    private(set) var cachedValid: Bool
    private(set) var lastValidated: Date?
    private(set) var dismissalsUsed: Int

    private var firstLaunch: Date
    private var highWaterMark: Date   // max date ever observed — defeats clock rollback

    private let client = LemonSqueezyClient()
    private let defaults: UserDefaults

    private enum Key {
        static let firstLaunch = "license.firstLaunch"
        static let highWater = "license.highWaterMark"
        static let key = "license.key"
        static let instance = "license.instanceId"
        static let cachedValid = "license.cachedValid"
        static let lastValidated = "license.lastValidated"
        static let dismissals = "license.dismissalsUsed"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let now = Date()

        // First-launch date: earliest of the UserDefaults value and the Application
        // Support mirror; if neither exists this is a genuine first run.
        let stored = defaults.object(forKey: Key.firstLaunch) as? Date
        let mirrored = Self.readMirroredFirstLaunch()
        let resolved = [stored, mirrored].compactMap { $0 }.min() ?? now
        self.firstLaunch = resolved

        self.highWaterMark = max(defaults.object(forKey: Key.highWater) as? Date ?? now, now)
        self.licenseKey = defaults.string(forKey: Key.key)
        self.instanceId = defaults.string(forKey: Key.instance)
        self.cachedValid = defaults.bool(forKey: Key.cachedValid)
        self.lastValidated = defaults.object(forKey: Key.lastValidated) as? Date
        self.dismissalsUsed = defaults.integer(forKey: Key.dismissals)

        // Persist the resolved values so both stores agree going forward.
        defaults.set(resolved, forKey: Key.firstLaunch)
        defaults.set(highWaterMark, forKey: Key.highWater)
        Self.writeMirroredFirstLaunch(resolved)
    }

    // MARK: - Effective time (rollback-resistant)

    /// `now`, but never earlier than any time we've previously observed — so setting the
    /// system clock backwards can't lengthen the trial.
    private var effectiveNow: Date {
        let now = Date()
        if now > highWaterMark {
            highWaterMark = now
            defaults.set(now, forKey: Key.highWater)
        }
        return highWaterMark
    }

    // MARK: - Entitlement

    /// Whether the stored license should currently be honored. A license stays valid
    /// offline, but only within the offline grace window since its last successful check.
    private var isLicensedNow: Bool {
        guard cachedValid, licenseKey != nil else { return false }
        guard let last = lastValidated else { return false }
        let grace = Double(LicenseConfig.offlineRevalidationGraceDays) * 86_400
        return effectiveNow.timeIntervalSince(last) < grace
    }

    var entitlement: Entitlement {
        // Debug: force a state so the trial/paywall UI can be exercised without waiting
        // out a real trial. SNIPPAI_FAKE_ENTITLEMENT = expired | licensed | trial.
        switch ProcessInfo.processInfo.environment["SNIPPAI_FAKE_ENTITLEMENT"] {
        case "expired":  return .expired
        case "licensed": return .licensed
        case "trial":    return .trial(daysRemaining: 3)
        default: break
        }
        if isLicensedNow { return .licensed }
        let days = TrialClock.daysRemaining(firstLaunch: firstLaunch, now: effectiveNow)
        return days > 0 ? .trial(daysRemaining: days) : .expired
    }

    var isLicensed: Bool { if case .licensed = entitlement { return true } else { return false } }

    /// One-line status for the Settings card.
    var statusSummary: String {
        switch entitlement {
        case .licensed:
            return "Licensed — thank you for supporting SnippAI."
        case .trial(let days):
            return days == 1 ? "Free trial — 1 day left." : "Free trial — \(days) days left."
        case .expired:
            return "Your free trial has ended. Enter a license to keep capturing."
        }
    }

    // MARK: - Capture gate

    enum CaptureGate: Equatable {
        case allowed
        case paywall(canDefer: Bool)
    }

    /// Whether the next capture is allowed, must show the paywall (with a "Maybe later"
    /// escape while deferrals remain), or must show a mandatory paywall.
    func evaluateCapture() -> CaptureGate {
        switch entitlement {
        case .licensed, .trial:
            return .allowed
        case .expired:
            return .paywall(canDefer: dismissalsUsed < LicenseConfig.graceDismissals)
        }
    }

    var dismissalsRemaining: Int { max(0, LicenseConfig.graceDismissals - dismissalsUsed) }

    /// Records a "Maybe later" deferral. Returns whether the capture may proceed this time.
    @discardableResult
    func recordDeferral() -> Bool {
        guard dismissalsUsed < LicenseConfig.graceDismissals else { return false }
        dismissalsUsed += 1
        defaults.set(dismissalsUsed, forKey: Key.dismissals)
        return true
    }

    // MARK: - Activation

    enum ActivationResult: Equatable {
        case success
        case failure(String)
    }

    func activate(key rawKey: String) async -> ActivationResult {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failure("Enter your license key.") }
        let instanceName = Host.current().localizedName ?? "Mac"
        do {
            let response = try await client.activate(licenseKey: key, instanceName: instanceName)
            switch LemonSqueezyClient.evaluate(response) {
            case .valid:
                guard let instance = response.instance?.id else {
                    return .failure("Activation didn’t return a device id. Try again.")
                }
                persistLicense(key: key, instanceId: instance, valid: true)
                return .success
            case .invalid(let reason):
                // A key that's valid but already at its activation limit means it's in use
                // on another machine — guide the user instead of a generic failure.
                if let usage = response.licenseKey?.activationUsage,
                   let limit = response.licenseKey?.activationLimit, usage >= limit, limit > 0 {
                    return .failure("This license is already active on another device. Deactivate it there, then try again.")
                }
                return .failure(reason)
            }
        } catch {
            return .failure((error as? LocalizedError)?.errorDescription ?? "Couldn’t reach the licensing server. Check your connection.")
        }
    }

    /// Re-checks the stored license in the background. Stays silent on network errors
    /// (offline grace) but downgrades immediately if the server says the key is no
    /// longer valid (refund / disable / deactivated elsewhere).
    func revalidateInBackground() async {
        guard let key = licenseKey else { return }
        do {
            let response = try await client.validate(licenseKey: key, instanceId: instanceId)
            switch LemonSqueezyClient.evaluate(response) {
            case .valid:
                cachedValid = true
                lastValidated = effectiveNow
                defaults.set(true, forKey: Key.cachedValid)
                defaults.set(lastValidated, forKey: Key.lastValidated)
            case .invalid:
                cachedValid = false
                defaults.set(false, forKey: Key.cachedValid)
            }
        } catch {
            // Offline — keep the cached verdict; the grace window in `isLicensedNow` applies.
        }
    }

    func deactivate() async {
        if let key = licenseKey, let instanceId {
            _ = try? await client.deactivate(licenseKey: key, instanceId: instanceId)
        }
        licenseKey = nil
        instanceId = nil
        cachedValid = false
        lastValidated = nil
        defaults.removeObject(forKey: Key.key)
        defaults.removeObject(forKey: Key.instance)
        defaults.set(false, forKey: Key.cachedValid)
        defaults.removeObject(forKey: Key.lastValidated)
    }

    // MARK: - Persistence helpers

    private func persistLicense(key: String, instanceId: String, valid: Bool) {
        self.licenseKey = key
        self.instanceId = instanceId
        self.cachedValid = valid
        self.lastValidated = effectiveNow
        defaults.set(key, forKey: Key.key)
        defaults.set(instanceId, forKey: Key.instance)
        defaults.set(valid, forKey: Key.cachedValid)
        defaults.set(lastValidated, forKey: Key.lastValidated)
    }

    // MARK: - Application Support mirror of the trial start

    private static var mirrorURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let appDir = dir.appendingPathComponent("SnippAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("trial.json")
    }

    private static func readMirroredFirstLaunch() -> Date? {
        guard let url = mirrorURL, let data = try? Data(contentsOf: url),
              let obj = try? JSONDecoder().decode([String: Double].self, from: data),
              let ts = obj["firstLaunch"] else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private static func writeMirroredFirstLaunch(_ date: Date) {
        guard let url = mirrorURL else { return }
        let payload = ["firstLaunch": date.timeIntervalSince1970]
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
