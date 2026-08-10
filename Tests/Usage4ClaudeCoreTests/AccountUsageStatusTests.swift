import XCTest
@testable import Usage4ClaudeCore

/// Tests for `AccountHealthClassifier` — the pure health/summary classification
/// used by the multi-account overview (feat/multi-account-overview).
final class AccountUsageStatusTests: XCTestCase {

    // MARK: - Helpers

    private func limit(_ percentage: Double, resetsAt: Date? = nil) -> UsageData.LimitData {
        UsageData.LimitData(percentage: percentage, resetsAt: resetsAt)
    }

    // MARK: - Per-window remaining + reset timestamps

    func testFiveHourAndSevenDayAreIndependentWithOwnResetTimes() {
        let fiveHourReset = Date(timeIntervalSince1970: 1_000)
        let sevenDayReset = Date(timeIntervalSince1970: 2_000)
        let summary = AccountHealthClassifier.summary(
            fiveHour: limit(30, resetsAt: fiveHourReset),
            sevenDay: limit(70, resetsAt: sevenDayReset)
        )

        XCTAssertEqual(summary.fiveHour?.usedPercentage, 30)
        XCTAssertEqual(summary.fiveHour?.remainingPercentage, 70)
        XCTAssertEqual(summary.fiveHour?.resetsAt, fiveHourReset)

        XCTAssertEqual(summary.sevenDay?.usedPercentage, 70)
        XCTAssertEqual(summary.sevenDay?.remainingPercentage, 30)
        XCTAssertEqual(summary.sevenDay?.resetsAt, sevenDayReset)
    }

    func testPrimaryConvenienceAccessorPrefersFiveHour() {
        let summary = AccountHealthClassifier.summary(fiveHour: limit(20), sevenDay: limit(80))
        XCTAssertEqual(summary.usedPercentage, 20)
        XCTAssertEqual(summary.remainingPercentage, 80)
    }

    func testPrimaryConvenienceAccessorFallsBackToSevenDayWhenFiveHourMissing() {
        let summary = AccountHealthClassifier.summary(fiveHour: nil, sevenDay: limit(45))
        XCTAssertEqual(summary.usedPercentage, 45)
        XCTAssertEqual(summary.remainingPercentage, 55)
    }

    func testActiveWhenBothWindowsBelow100() {
        let summary = AccountHealthClassifier.summary(fiveHour: limit(30), sevenDay: limit(70))
        XCTAssertEqual(summary.health, .active)
    }

    // MARK: - Active vs exhausted: one exhausted, one available (either window blocks usage)

    func testExhaustedWhenFiveHourExhaustedEvenIfSevenDayHasCapacity() {
        let summary = AccountHealthClassifier.summary(fiveHour: limit(100), sevenDay: limit(10))
        XCTAssertEqual(summary.health, .exhausted, "a fully-used five-hour window blocks usage until it resets, regardless of seven-day capacity")
    }

    func testExhaustedWhenSevenDayExhaustedEvenIfFiveHourHasCapacity() {
        let summary = AccountHealthClassifier.summary(fiveHour: limit(5), sevenDay: limit(137))
        XCTAssertEqual(summary.health, .exhausted, "a fully-used seven-day window blocks usage until it resets, regardless of five-hour capacity")
    }

    // MARK: - Active vs exhausted: both exhausted

    func testExhaustedWhenBothWindowsAtExactly100() {
        let summary = AccountHealthClassifier.summary(fiveHour: limit(100), sevenDay: limit(100))
        XCTAssertEqual(summary.health, .exhausted)
    }

    func testExhaustedWhenBothWindowsAbove100DoesNotGoNegative() {
        let summary = AccountHealthClassifier.summary(fiveHour: limit(150), sevenDay: limit(200))
        XCTAssertEqual(summary.health, .exhausted)
        XCTAssertEqual(summary.fiveHour?.remainingPercentage, 0)
        XCTAssertEqual(summary.sevenDay?.remainingPercentage, 0)
    }

    // MARK: - Missing windows

    func testActiveWhenNoWindowsAvailableAtAll() {
        let summary = AccountHealthClassifier.summary(fiveHour: nil, sevenDay: nil)
        XCTAssertEqual(summary.health, .active, "no evidence of exhaustion must not be reported as exhausted")
        XCTAssertNotEqual(summary.health, .invalidCredentials, "missing windows on a successful response must never read as invalid credentials")
        XCTAssertNil(summary.fiveHour)
        XCTAssertNil(summary.sevenDay)
        XCTAssertNil(summary.usedPercentage)
    }

    func testExhaustedWithOnlyFiveHourAvailableAndExhausted() {
        let summary = AccountHealthClassifier.summary(fiveHour: limit(100), sevenDay: nil)
        XCTAssertEqual(summary.health, .exhausted)
        XCTAssertNil(summary.sevenDay)
    }

    func testActiveWithOnlySevenDayAvailableAndNotExhausted() {
        let summary = AccountHealthClassifier.summary(fiveHour: nil, sevenDay: limit(50))
        XCTAssertEqual(summary.health, .active)
        XCTAssertNil(summary.fiveHour)
    }

    // MARK: - UsageData convenience overload

    func testSummaryFromUsageDataUsesFiveHourAndSevenDay() {
        let usageData = UsageData(
            fiveHour: limit(60),
            sevenDay: limit(40),
            weeklyModels: [],
            extraUsage: nil
        )
        let summary = AccountHealthClassifier.summary(usageData: usageData)
        XCTAssertEqual(summary.fiveHour?.usedPercentage, 60)
        XCTAssertEqual(summary.sevenDay?.usedPercentage, 40)
        XCTAssertEqual(summary.health, .active)
    }

    // MARK: - Invalid credentials (unauthorized / sessionExpired only)

    func testUnauthorizedIsInvalidCredentials() {
        XCTAssertEqual(AccountHealthClassifier.summary(failure: .unauthorized).health, .invalidCredentials)
    }

    func testSessionExpiredIsInvalidCredentials() {
        XCTAssertEqual(AccountHealthClassifier.summary(failure: .sessionExpired).health, .invalidCredentials)
    }

    // MARK: - Temporary failures must NOT be classified as invalid credentials

    func testTemporaryFailureReasonsAreNeverInvalidCredentials() {
        let reasons: [AccountUsageFailureReason] = [
            .rateLimited,
            .networkError,
            .cloudflareBlocked,
            .httpError(statusCode: 500),
            .noData,
            .decodingError,
            .invalidURL
        ]
        for reason in reasons {
            let summary = AccountHealthClassifier.summary(failure: reason)
            XCTAssertEqual(summary.health, .temporaryFailure, "\(reason) must classify as temporaryFailure, not invalidCredentials")
            XCTAssertNotEqual(summary.health, .invalidCredentials)
            XCTAssertNotEqual(summary.health, .exhausted, "a fetch failure must never be reported as quota exhaustion")
        }
    }

    // MARK: - No credentials

    func testNoCredentials() {
        XCTAssertEqual(AccountHealthClassifier.summary(failure: .noCredentials).health, .noCredentials)
    }

    // MARK: - Failure summaries carry no usage windows

    func testFailureSummaryHasNilWindowsAndPercentages() {
        let summary = AccountHealthClassifier.summary(failure: .networkError)
        XCTAssertNil(summary.fiveHour)
        XCTAssertNil(summary.sevenDay)
        XCTAssertNil(summary.usedPercentage)
        XCTAssertNil(summary.remainingPercentage)
    }

    // MARK: - AccountUsageFailureReason Equatable sanity

    func testHttpErrorReasonCarriesStatusCode() {
        let a = AccountUsageFailureReason.httpError(statusCode: 500)
        let b = AccountUsageFailureReason.httpError(statusCode: 500)
        let c = AccountUsageFailureReason.httpError(statusCode: 503)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
    // MARK: - health(for: AccountAvailability) mapping

    func testHealthForAvailableNowIsActive() {
        XCTAssertEqual(AccountHealthClassifier.health(for: .availableNow), .active)
    }

    func testHealthForBlockedIsExhausted() {
        XCTAssertEqual(AccountHealthClassifier.health(for: .blocked(until: nil)), .exhausted)
        XCTAssertEqual(AccountHealthClassifier.health(for: .blocked(until: Date(timeIntervalSince1970: 1_000))), .exhausted)
    }

    func testHealthForUnknownIsTemporaryFailure() {
        XCTAssertEqual(AccountHealthClassifier.health(for: .unknown), .temporaryFailure)
    }

    // MARK: - Codex row adaptation: summary(codexData:availability:)

    private func codexLimit(_ percentage: Double, resetsAt: Date? = nil) -> CodexUsageData.LimitData {
        CodexUsageData.LimitData(percentage: percentage, resetsAt: resetsAt)
    }

    func testCodexSummaryPreservesWindowPercentagesAndResetDates() {
        let fiveHourReset = Date(timeIntervalSince1970: 1_000)
        let sevenDayReset = Date(timeIntervalSince1970: 2_000)
        let data = CodexUsageData(
            primary: codexLimit(35, resetsAt: fiveHourReset),
            secondary: codexLimit(65, resetsAt: sevenDayReset),
            extraUsage: nil,
            allowed: true,
            limitReached: false
        )
        let availability = AccountAvailabilityClassifier.codexAvailability(data)
        let summary = AccountHealthClassifier.summary(codexData: data, availability: availability)

        XCTAssertEqual(summary.fiveHour?.usedPercentage, 35)
        XCTAssertEqual(summary.fiveHour?.resetsAt, fiveHourReset)
        XCTAssertEqual(summary.sevenDay?.usedPercentage, 65)
        XCTAssertEqual(summary.sevenDay?.resetsAt, sevenDayReset)
    }

    func testCodexSummaryHealthMatchesAuthoritativeAvailabilityWhenAllowedTrueEvenAt100Percent() {
        // Server says allowed even though the window reads 100% — health must
        // follow the authoritative availability (active), not the raw percentage.
        let data = CodexUsageData(
            primary: codexLimit(100),
            secondary: nil,
            extraUsage: nil,
            allowed: true,
            limitReached: nil
        )
        let availability = AccountAvailabilityClassifier.codexAvailability(data)
        let summary = AccountHealthClassifier.summary(codexData: data, availability: availability)
        XCTAssertEqual(availability, .availableNow)
        XCTAssertEqual(summary.health, .active)
    }

    func testCodexSummaryHealthMatchesAuthoritativeAvailabilityWhenLimitReachedTrue() {
        let data = CodexUsageData(
            primary: codexLimit(10),
            secondary: nil,
            extraUsage: nil,
            allowed: nil,
            limitReached: true
        )
        let availability = AccountAvailabilityClassifier.codexAvailability(data)
        let summary = AccountHealthClassifier.summary(codexData: data, availability: availability)
        XCTAssertEqual(availability, .blocked(until: nil))
        XCTAssertEqual(summary.health, .exhausted)
    }

}
