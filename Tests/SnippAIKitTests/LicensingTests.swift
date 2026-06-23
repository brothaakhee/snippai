import XCTest
@testable import SnippAIKit

final class LicensingTests: XCTestCase {
    private func decode(_ json: String) throws -> LemonSqueezyClient.LicenseResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LemonSqueezyClient.LicenseResponse.self, from: Data(json.utf8))
    }

    // MARK: - Trial clock

    func testTrialDaysRemainingRoundsUp() {
        let start = Date(timeIntervalSince1970: 0)
        // 2.1 days elapsed of a 7-day trial → ~4.9 left → rounds up to 5.
        let now = start.addingTimeInterval(2.1 * 86_400)
        XCTAssertEqual(TrialClock.daysRemaining(firstLaunch: start, now: now, trialDays: 7), 5)
    }

    func testTrialNotExpiredOnLastDay() {
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(6.5 * 86_400)
        XCTAssertFalse(TrialClock.isExpired(firstLaunch: start, now: now, trialDays: 7))
        XCTAssertEqual(TrialClock.daysRemaining(firstLaunch: start, now: now, trialDays: 7), 1)
    }

    func testTrialExpiredAtAndAfterBoundary() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(TrialClock.isExpired(firstLaunch: start, now: start.addingTimeInterval(7 * 86_400), trialDays: 7))
        XCTAssertEqual(TrialClock.daysRemaining(firstLaunch: start, now: start.addingTimeInterval(9 * 86_400), trialDays: 7), 0)
    }

    // MARK: - License evaluation

    func testActiveLicenseWithMatchingProductIsValid() throws {
        let r = try decode("""
        {"activated":true,"error":null,
         "license_key":{"status":"active","key":"K","activation_limit":1,"activation_usage":1},
         "instance":{"id":"i1","name":"Mac"},
         "meta":{"store_id":123,"product_id":456,"variant_id":789}}
        """)
        XCTAssertEqual(LemonSqueezyClient.evaluate(r, storeId: 123, variantId: 789), .valid)
    }

    func testValidateResponseUsesValidFlag() throws {
        let r = try decode("""
        {"valid":true,"error":null,"license_key":{"status":"active"},"meta":{"store_id":123,"variant_id":789}}
        """)
        XCTAssertEqual(LemonSqueezyClient.evaluate(r, storeId: 123, variantId: 789), .valid)
    }

    func testWrongStoreIsRejected() throws {
        let r = try decode("""
        {"activated":true,"license_key":{"status":"active"},"meta":{"store_id":999,"variant_id":789}}
        """)
        XCTAssertEqual(LemonSqueezyClient.evaluate(r, storeId: 123, variantId: 789),
                       .invalid(reason: "This license is for a different product."))
    }

    func testWrongVariantIsRejected() throws {
        let r = try decode("""
        {"activated":true,"license_key":{"status":"active"},"meta":{"store_id":123,"variant_id":111}}
        """)
        XCTAssertEqual(LemonSqueezyClient.evaluate(r, storeId: 123, variantId: 789),
                       .invalid(reason: "This license is for a different product."))
    }

    func testUnconfiguredProductSkipsMatch() throws {
        // storeId/variantId == 0 means "don't enforce" — used before the real IDs exist.
        let r = try decode("""
        {"activated":true,"license_key":{"status":"active"},"meta":{"store_id":999,"variant_id":111}}
        """)
        XCTAssertEqual(LemonSqueezyClient.evaluate(r, storeId: 0, variantId: 0), .valid)
    }

    func testExpiredStatusIsRejected() throws {
        let r = try decode("""
        {"valid":false,"license_key":{"status":"expired"}}
        """)
        XCTAssertEqual(LemonSqueezyClient.evaluate(r, storeId: 0, variantId: 0),
                       .invalid(reason: "This license has expired."))
    }

    func testServerErrorMessageSurfaces() throws {
        let r = try decode("""
        {"activated":false,"error":"license_key not found.","license_key":null}
        """)
        XCTAssertEqual(LemonSqueezyClient.evaluate(r, storeId: 0, variantId: 0),
                       .invalid(reason: "license_key not found."))
    }

    func testNotActivatedWithoutErrorIsRejected() throws {
        let r = try decode("""
        {"activated":false,"license_key":{"status":"active"}}
        """)
        XCTAssertEqual(LemonSqueezyClient.evaluate(r, storeId: 0, variantId: 0),
                       .invalid(reason: "This license key isn’t valid."))
    }
}
