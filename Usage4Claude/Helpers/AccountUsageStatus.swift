//
//  AccountUsageStatus.swift
//  Usage4Claude
//
//  Pure, network-agnostic health/summary classification for the multi-account
//  overview (feat/multi-account-overview). Deliberately has zero dependency on
//  `UsageError` (Services/ClaudeAPIService.swift) so this file can live in the
//  SwiftPM `Usage4ClaudeCore` test target without dragging in Logger/UserSettings/
//  `L.*` localization. `AccountUsageFailureReason` mirrors `UsageError`'s cases;
//  the 1:1 mapping from the real `UsageError` lives in
//  `Services/ClaudeAccountUsageFetcher.swift` (Xcode-target only), where an
//  exhaustive switch guarantees the mirror stays in sync if `UsageError` ever
//  gains/loses a case.
//
//  `UsageData` / `UsageData.LimitData` (Models/ClaudeAPIResponseModels.swift)
//  are already part of this SwiftPM target's source allowlist and are
//  themselves UI/network-free, so the classifier below can build summaries
//  directly from them without pulling in anything new.
//

import Foundation

// MARK: - Failure Reason (mirrors UsageError)

/// Network-agnostic mirror of `UsageError`'s cases, used so this file can be
/// compiled and unit-tested by SwiftPM without importing the real `UsageError`
/// (which lives in a Logger/UserSettings/L-dependent file outside the test
/// target's source allowlist).
enum AccountUsageFailureReason: Equatable, Sendable {
    case noCredentials
    case unauthorized
    case sessionExpired
    case rateLimited
    case networkError
    case cloudflareBlocked
    case httpError(statusCode: Int)
    case noData
    case decodingError
    case invalidURL
}

// MARK: - Account Health

/// Coarse-grained health classification for a single account row in the
/// multi-account overview.
///
/// - `exhausted` means at least one core quota window (five-hour or
///   seven-day) has reached/exceeded 100% used. Either window alone blocks
///   further usage until it resets, so the account is effectively
///   unavailable — this is quota exhaustion, NOT invalid/dead credentials.
///   `active` only applies when every available window still has capacity
///   (or when a successful response carries no core windows at all — there's
///   no evidence of exhaustion in that case).
/// - `invalidCredentials` is reserved for unauthorized/sessionExpired —
///   rate limits, Cloudflare blocks, network errors, decoding errors, and a
///   blocked quota window must never be classified here.
enum AccountHealth: Equatable, Sendable {
    /// Credentials valid, usage fetched successfully, every available core
    /// window (or none at all) still has capacity.
    case active
    /// Credentials valid, usage fetched successfully, at least one core
    /// window (five-hour or seven-day) is used >= 100% — that window blocks
    /// usage until it resets.
    case exhausted
    /// Credentials are invalid or dead (401 unauthorized / session expired).
    case invalidCredentials
    /// A transient failure (rate limit, network, Cloudflare, HTTP, no data, decoding).
    /// Does NOT imply the credentials themselves are bad.
    case temporaryFailure
    /// No credentials configured for this account at all.
    case noCredentials
}

// MARK: - Per-window limit summary

/// Usage summary for a single quota window (five-hour or seven-day).
///
/// Percentage semantics: the Claude API reports USED percentage (0-100+).
/// `remainingPercentage` is derived defensively as `max(0, 100 - used)` so a
/// window that's over 100% (exhausted, possibly overdrawn) never reports a
/// negative remaining value.
struct AccountLimitSummary: Equatable, Sendable {
    let usedPercentage: Double
    /// When this window resets, if known.
    let resetsAt: Date?

    /// Remaining percentage, clamped to never go negative even if
    /// `usedPercentage` is >= 100 (exhausted / overdrawn window).
    var remainingPercentage: Double {
        max(0, 100 - usedPercentage)
    }

    init(usedPercentage: Double, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    init(_ limit: UsageData.LimitData) {
        self.usedPercentage = limit.percentage
        self.resetsAt = limit.resetsAt
    }
}

// MARK: - Account Usage Summary

/// Per-account usage summary exposed to SwiftUI by the multi-account overview.
/// Retains the five-hour and seven-day windows independently (each with its
/// own used/remaining percentage and reset time) so the UI can show both,
/// rather than collapsing them into a single headline number.
struct AccountUsageSummary: Equatable, Sendable {
    let health: AccountHealth
    /// Five-hour window summary, `nil` when unavailable (failed fetch, or a
    /// successful response that didn't include this window).
    let fiveHour: AccountLimitSummary?
    /// Seven-day window summary, `nil` when unavailable.
    let sevenDay: AccountLimitSummary?

    /// Convenience: the primary window is five-hour, falling back to
    /// seven-day — matches `UsageData.percentage`'s existing semantics, for
    /// callers that only need a single headline number.
    var primary: AccountLimitSummary? { fiveHour ?? sevenDay }
    var usedPercentage: Double? { primary?.usedPercentage }
    var remainingPercentage: Double? { primary?.remainingPercentage }
}

// MARK: - Classifier

/// Pure classification logic — no I/O, no singletons, fully unit-testable.
enum AccountHealthClassifier {
    /// Threshold at which a window's used-percentage counts as exhausted.
    static let exhaustedThreshold: Double = 100

    /// Classifies the account's health from whichever core quota windows are
    /// available. Matches real blocking-quota semantics: a single fully-used
    /// window (five-hour OR seven-day) already blocks further usage until it
    /// resets, so the account is `exhausted` if ANY available window is
    /// at/over 100% used — even if the other window still has capacity. Only
    /// when every available window has capacity is the account `active`. A
    /// successful response with no windows at all is `active` — there's no
    /// evidence of exhaustion, and it must never be reported as invalid
    /// credentials.
    static func health(fiveHour: AccountLimitSummary?, sevenDay: AccountLimitSummary?) -> AccountHealth {
        let available = [fiveHour, sevenDay].compactMap { $0 }
        guard !available.isEmpty else { return .active }
        return available.contains { $0.usedPercentage >= exhaustedThreshold } ? .exhausted : .active
    }

    /// Classifies a failed usage fetch's reason into a health state.
    /// Rate limits, Cloudflare blocks, network errors, decoding errors, no-data,
    /// and invalid URLs are all `temporaryFailure` — none of them imply the
    /// account's credentials are actually invalid.
    static func health(for reason: AccountUsageFailureReason) -> AccountHealth {
        switch reason {
        case .noCredentials:
            return .noCredentials
        case .unauthorized, .sessionExpired:
            return .invalidCredentials
        case .rateLimited, .networkError, .cloudflareBlocked, .httpError, .noData, .decodingError, .invalidURL:
            return .temporaryFailure
        }
    }

    /// Builds the summary for a successful fetch from raw five-hour/seven-day
    /// limit data (as decoded onto `UsageData`).
    static func summary(fiveHour: UsageData.LimitData?, sevenDay: UsageData.LimitData?) -> AccountUsageSummary {
        let fiveHourSummary: AccountLimitSummary?
        if let fiveHour {
            fiveHourSummary = AccountLimitSummary(fiveHour)
        } else {
            fiveHourSummary = nil
        }
        let sevenDaySummary: AccountLimitSummary?
        if let sevenDay {
            sevenDaySummary = AccountLimitSummary(sevenDay)
        } else {
            sevenDaySummary = nil
        }
        return AccountUsageSummary(
            health: health(fiveHour: fiveHourSummary, sevenDay: sevenDaySummary),
            fiveHour: fiveHourSummary,
            sevenDay: sevenDaySummary
        )
    }

    /// Convenience overload taking a full `UsageData` (as returned by a
    /// successful fetch).
    static func summary(usageData: UsageData) -> AccountUsageSummary {
        summary(fiveHour: usageData.fiveHour, sevenDay: usageData.sevenDay)
    }

    /// Builds the summary for a failed fetch (no usage windows available).
    static func summary(failure reason: AccountUsageFailureReason) -> AccountUsageSummary {
        AccountUsageSummary(health: health(for: reason), fiveHour: nil, sevenDay: nil)
    }

    /// Maps an authoritative `AccountAvailability` (as produced by
    /// `AccountAvailabilityClassifier`) to a display `AccountHealth` for the
    /// overview UI. A live (non-stale) fetch's availability is always
    /// `.availableNow` or `.blocked` — see `AccountAvailabilityClassifier`'s
    /// Claude/Codex classifiers, which only ever return `.unknown` for a stale,
    /// failed, or credential-less classification, never for a fresh successful
    /// one — so `.unknown` here only arises defensively and reads as a
    /// transient failure rather than silently defaulting to `.active`.
    static func health(for availability: AccountAvailability) -> AccountHealth {
        switch availability {
        case .availableNow:
            return .active
        case .blocked:
            return .exhausted
        case .unknown:
            return .temporaryFailure
        }
    }

    /// Adapts a successful Codex fetch into the same provider-neutral
    /// `AccountUsageSummary` shape Claude rows use, without altering any window
    /// percentage or reset date — `CodexUsageData.LimitData.asUsageLimitData()`
    /// is a pure field copy. `health` is derived from `availability`, which the
    /// caller must have already computed via
    /// `AccountAvailabilityClassifier.codexAvailability` (server
    /// `allowed`/`limitReached` authoritative), so display health and
    /// authoritative availability never disagree for the same fetch.
    static func summary(codexData: CodexUsageData, availability: AccountAvailability) -> AccountUsageSummary {
        AccountUsageSummary(
            health: health(for: availability),
            fiveHour: codexData.primary.map { AccountLimitSummary($0.asUsageLimitData()) },
            sevenDay: codexData.secondary.map { AccountLimitSummary($0.asUsageLimitData()) }
        )
    }
}
