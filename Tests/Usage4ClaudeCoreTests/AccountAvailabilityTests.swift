import XCTest
@testable import Usage4ClaudeCore

/// Tests for `AccountAvailabilityClassifier` / `AccountAvailability` — the
/// pure "can I use this account right now" core for the next-usable-account
/// feature (feat/next-access-multi-provider).
final class AccountAvailabilityTests: XCTestCase {

    // MARK: - Helpers

    private func limit(_ percentage: Double, resetsAt: Date? = nil) -> AccountLimitSummary {
        AccountLimitSummary(usedPercentage: percentage, resetsAt: resetsAt)
    }

    private func codexLimit(_ percentage: Double, resetsAt: Date? = nil) -> CodexUsageData.LimitData {
        CodexUsageData.LimitData(percentage: percentage, resetsAt: resetsAt)
    }

    private func codexData(
        primary: CodexUsageData.LimitData? = nil,
        secondary: CodexUsageData.LimitData? = nil,
        extraUsage: CodexExtraUsageData? = nil,
        allowed: Bool? = nil,
        limitReached: Bool? = nil
    ) -> CodexUsageData {
        CodexUsageData(
            primary: primary,
            secondary: secondary,
            extraUsage: extraUsage,
            allowed: allowed,
            limitReached: limitReached
        )
    }

    // MARK: - Claude: available now

    func testClaudeAvailableNowWhenHealthActive() {
        let availability = AccountAvailabilityClassifier.claudeAvailability(
            health: .active,
            fiveHour: limit(30),
            sevenDay: limit(70)
        )
        XCTAssertEqual(availability, .availableNow)
    }

    // MARK: - Claude: blocked, both windows exhausted -> latest reset wins

    func testClaudeBlockedUsesLatestResetWhenBothWindowsExhausted() {
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        let availability = AccountAvailabilityClassifier.claudeAvailability(
            health: .exhausted,
            fiveHour: limit(100, resetsAt: earlier),
            sevenDay: limit(120, resetsAt: later)
        )
        XCTAssertEqual(availability, .blocked(until: later))
    }

    // MARK: - Claude: blocked, only one window exhausted -> that window's reset

    func testClaudeBlockedUsesExhaustedWindowResetWhenOnlyOneWindowExhausted() {
        let resetDate = Date(timeIntervalSince1970: 5_000)
        let availability = AccountAvailabilityClassifier.claudeAvailability(
            health: .exhausted,
            fiveHour: limit(100, resetsAt: resetDate),
            sevenDay: limit(10, resetsAt: Date(timeIntervalSince1970: 99_999))
        )
        XCTAssertEqual(availability, .blocked(until: resetDate), "only the blocking window's reset should count, not the healthy window's")
    }

    // MARK: - Claude: blocked, nil reset on a blocking window -> blocked(nil)

    func testClaudeBlockedWithNilResetWhenExhaustedWindowHasNoKnownReset() {
        let availability = AccountAvailabilityClassifier.claudeAvailability(
            health: .exhausted,
            fiveHour: limit(100, resetsAt: nil),
            sevenDay: limit(10)
        )
        XCTAssertEqual(availability, .blocked(until: nil))
    }

    func testClaudeBlockedWithNilResetWhenOneOfTwoExhaustedWindowsHasNoKnownReset() {
        // Both windows exhausted, one has a known reset, the other doesn't —
        // the account-level reset must still be nil (never fabricate it).
        let availability = AccountAvailabilityClassifier.claudeAvailability(
            health: .exhausted,
            fiveHour: limit(100, resetsAt: Date(timeIntervalSince1970: 1_000)),
            sevenDay: limit(150, resetsAt: nil)
        )
        XCTAssertEqual(availability, .blocked(until: nil))
    }

    // MARK: - Claude: unknown for stale/error/missing

    func testClaudeUnknownForInvalidCredentials() {
        XCTAssertEqual(
            AccountAvailabilityClassifier.claudeAvailability(health: .invalidCredentials, fiveHour: nil, sevenDay: nil),
            .unknown
        )
    }

    func testClaudeUnknownForTemporaryFailure() {
        XCTAssertEqual(
            AccountAvailabilityClassifier.claudeAvailability(health: .temporaryFailure, fiveHour: nil, sevenDay: nil),
            .unknown
        )
    }

    func testClaudeUnknownForNoCredentials() {
        XCTAssertEqual(
            AccountAvailabilityClassifier.claudeAvailability(health: .noCredentials, fiveHour: nil, sevenDay: nil),
            .unknown
        )
    }

    // MARK: - Codex: server flags authoritative — blocked

    func testCodexBlockedWhenLimitReachedTrueRegardlessOfPercentage() {
        let resetDate = Date(timeIntervalSince1970: 3_000)
        let data = codexData(primary: codexLimit(10, resetsAt: resetDate), limitReached: true)
        XCTAssertEqual(AccountAvailabilityClassifier.codexAvailability(data), .blocked(until: nil), "no window is >=100 so there's no known blocking-window reset even though the server confirms a block")
    }

    func testCodexBlockedUsesExhaustedWindowResetWhenLimitReachedTrue() {
        let resetDate = Date(timeIntervalSince1970: 3_000)
        let data = codexData(primary: codexLimit(100, resetsAt: resetDate), limitReached: true)
        XCTAssertEqual(AccountAvailabilityClassifier.codexAvailability(data), .blocked(until: resetDate))
    }

    func testCodexBlockedWhenAllowedFalseRegardlessOfPercentage() {
        let data = codexData(primary: codexLimit(0), allowed: false)
        XCTAssertEqual(AccountAvailabilityClassifier.codexAvailability(data), .blocked(until: nil))
    }

    // MARK: - Codex: server flags authoritative — allowed, even at 100%

    func testCodexAvailableWhenLimitReachedFalseEvenAt100Percent() {
        let data = codexData(primary: codexLimit(100), limitReached: false)
        XCTAssertEqual(AccountAvailabilityClassifier.codexAvailability(data), .availableNow)
    }

    func testCodexAvailableWhenAllowedTrueEvenAt100Percent() {
        let data = codexData(primary: codexLimit(100), secondary: codexLimit(100), allowed: true)
        XCTAssertEqual(AccountAvailabilityClassifier.codexAvailability(data), .availableNow)
    }

    // MARK: - Codex: both flags nil -> fallback to windows / credit signals

    func testCodexFallsBackToWindowPercentageWhenFlagsNil() {
        let resetDate = Date(timeIntervalSince1970: 8_000)
        let data = codexData(primary: codexLimit(100, resetsAt: resetDate))
        XCTAssertEqual(AccountAvailabilityClassifier.codexAvailability(data), .blocked(until: resetDate))
    }

    func testCodexFallsBackToAvailableWhenFlagsNilAndWindowsBelow100() {
        let data = codexData(primary: codexLimit(40), secondary: codexLimit(70))
        XCTAssertEqual(AccountAvailabilityClassifier.codexAvailability(data), .availableNow)
    }

    func testCodexFallsBackToCreditBlockSignalWhenFlagsNilAndNoWindowExhausted() {
        let extra = CodexExtraUsageData(
            hasCredits: false,
            unlimited: false,
            overageLimitReached: true,
            spendControlReached: false,
            balance: nil,
            approxLocalMessages: nil,
            approxCloudMessages: nil
        )
        let data = codexData(primary: codexLimit(20), extraUsage: extra)
        XCTAssertEqual(AccountAvailabilityClassifier.codexAvailability(data), .blocked(until: nil), "overage/spend-control block signals have no window reset, so the block is confirmed but the time is unknown")
    }

    func testCodexFallsBackToSpendControlBlockSignalWhenFlagsNilAndNoWindowExhausted() {
        let extra = CodexExtraUsageData(
            hasCredits: true,
            unlimited: false,
            overageLimitReached: false,
            spendControlReached: true,
            balance: 50,
            approxLocalMessages: nil,
            approxCloudMessages: nil
        )
        let data = codexData(primary: codexLimit(20), extraUsage: extra)
        XCTAssertEqual(AccountAvailabilityClassifier.codexAvailability(data), .blocked(until: nil))
    }

    // MARK: - Codex: positive credits must never override a confirmed block

    func testCodexPositiveCreditsDoNotOverrideConfirmedBlock() {
        let extra = CodexExtraUsageData(
            hasCredits: true,
            unlimited: false,
            overageLimitReached: false,
            spendControlReached: false,
            balance: 500,
            approxLocalMessages: nil,
            approxCloudMessages: nil
        )
        let data = codexData(primary: codexLimit(100), extraUsage: extra, limitReached: true)
        XCTAssertEqual(AccountAvailabilityClassifier.codexAvailability(data), .blocked(until: nil), "positive credits/balance must never flip a server-confirmed block back to available")
    }

    // MARK: - Codex: stale/error -> unknown

    func testCodexStaleIsUnknown() {
        let data = codexData(primary: codexLimit(0), allowed: true)
        XCTAssertEqual(AccountAvailabilityClassifier.codexAvailability(data, isStale: true), .unknown, "even a confirmed-allowed response must read as unknown once flagged stale")
    }

    // MARK: - Global selector: availableNow precedence

    func testSelectNextAvailablePrefersAvailableNowOverAnyBlockedOrUnknown() {
        let blockedId = UUID()
        let unknownId = UUID()
        let availableId = UUID()
        let candidates = [
            AccountAvailabilityCandidate(id: blockedId, provider: .claude, availability: .blocked(until: Date(timeIntervalSince1970: 1))),
            AccountAvailabilityCandidate(id: unknownId, provider: .codex, availability: .unknown),
            AccountAvailabilityCandidate(id: availableId, provider: .claude, availability: .availableNow)
        ]
        let selected = AccountAvailabilityClassifier.selectNextAvailable(from: candidates)
        XCTAssertEqual(selected?.id, availableId)
    }

    // MARK: - Global selector: earliest known blocked date

    func testSelectNextAvailablePicksEarliestKnownBlockedDateWhenNoneAvailableNow() {
        let laterId = UUID()
        let earlierId = UUID()
        let unknownTimeId = UUID()
        let candidates = [
            AccountAvailabilityCandidate(id: laterId, provider: .claude, availability: .blocked(until: Date(timeIntervalSince1970: 2_000))),
            AccountAvailabilityCandidate(id: earlierId, provider: .codex, availability: .blocked(until: Date(timeIntervalSince1970: 1_000))),
            AccountAvailabilityCandidate(id: unknownTimeId, provider: .claude, availability: .blocked(until: nil))
        ]
        let selected = AccountAvailabilityClassifier.selectNextAvailable(from: candidates)
        XCTAssertEqual(selected?.id, earlierId)
    }

    // MARK: - Global selector: deterministic tie order (original row/store order wins)

    func testSelectNextAvailableTieOrderPreservesOriginalOrderForEqualBlockedDates() {
        let sameDate = Date(timeIntervalSince1970: 4_000)
        let firstId = UUID()
        let secondId = UUID()
        let candidates = [
            AccountAvailabilityCandidate(id: firstId, provider: .claude, availability: .blocked(until: sameDate)),
            AccountAvailabilityCandidate(id: secondId, provider: .codex, availability: .blocked(until: sameDate))
        ]
        let selected = AccountAvailabilityClassifier.selectNextAvailable(from: candidates)
        XCTAssertEqual(selected?.id, firstId, "ties must resolve to the first candidate in the original array order")
    }

    func testSelectNextAvailableTieOrderPreservesOriginalOrderForMultipleAvailableNow() {
        let firstId = UUID()
        let secondId = UUID()
        let candidates = [
            AccountAvailabilityCandidate(id: firstId, provider: .claude, availability: .availableNow),
            AccountAvailabilityCandidate(id: secondId, provider: .codex, availability: .availableNow)
        ]
        let selected = AccountAvailabilityClassifier.selectNextAvailable(from: candidates)
        XCTAssertEqual(selected?.id, firstId)
    }

    // MARK: - Global selector: nothing confidently selectable

    func testSelectNextAvailableReturnsNilWhenNoneAvailableOrKnownBlocked() {
        let candidates = [
            AccountAvailabilityCandidate(id: UUID(), provider: .claude, availability: .unknown),
            AccountAvailabilityCandidate(id: UUID(), provider: .codex, availability: .blocked(until: nil))
        ]
        XCTAssertNil(AccountAvailabilityClassifier.selectNextAvailable(from: candidates))
    }

    func testSelectNextAvailableReturnsNilForEmptyCandidates() {
        XCTAssertNil(AccountAvailabilityClassifier.selectNextAvailable(from: []))
    }
}
