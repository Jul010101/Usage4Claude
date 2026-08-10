//
//  AccountAvailability.swift
//  Usage4Claude
//
//  Pure, provider-neutral "which account can I use right now" core for the
//  next-usable-account feature (feat/next-access-multi-provider). Zero
//  dependency on SwiftUI/AppKit/Logger/UserSettings/`L.*` localization so it
//  can live in the SwiftPM `Usage4ClaudeCore` test target alongside
//  `AccountUsageStatus.swift` and `CodexUsageData.swift`.
//
//  This is deliberately orthogonal to `AccountHealth` (Helpers/AccountUsageStatus.swift),
//  which is a coarse health/summary label for the overview UI. Availability answers a
//  narrower, more operational question: "does this specific account have capacity to
//  send a request right now, and if not, when might it?"
//

import Foundation

// MARK: - Availability

/// Per-account availability classification.
enum AccountAvailability: Equatable, Sendable {
    /// The account has capacity right now — safe to route a request to it.
    case availableNow
    /// The account is blocked until `until`, if known. `nil` means blocking
    /// is confirmed (by a window or a provider flag) but the reset time
    /// isn't known — never fabricate a time in that case.
    case blocked(until: Date?)
    /// Availability cannot be determined: stale data, a fetch error, missing
    /// credentials, or no successful fetch at all yet.
    case unknown
}

// MARK: - Candidate identity

/// Provider-neutral identity for a single account row, used only to carry an
/// already-computed `AccountAvailability` through the global "which account
/// next" selector. Deliberately just an id + provider — no display name,
/// alias, or credentials, so this type has zero UI/localization surface.
struct AccountAvailabilityCandidate: Equatable, Sendable {
    let id: UUID
    let provider: ProviderType
    let availability: AccountAvailability

    init(id: UUID, provider: ProviderType, availability: AccountAvailability) {
        self.id = id
        self.provider = provider
        self.availability = availability
    }
}

// MARK: - Classifier

/// Pure classification logic — no I/O, no singletons, fully unit-testable.
enum AccountAvailabilityClassifier {
    /// Same 100%-used threshold `AccountHealthClassifier` uses to call a
    /// window exhausted; kept in sync by delegating here rather than
    /// duplicating the constant.
    static let exhaustedThreshold: Double = AccountHealthClassifier.exhaustedThreshold

    /// Combines the reset dates of windows already confirmed to be blocking
    /// usage into a single `blocked(until:)` value. Always returns
    /// `.blocked` — callers must only invoke this once blocking is already
    /// established.
    ///
    /// - An empty `resets` array (blocking confirmed by a source other than
    ///   a window, e.g. a provider flag or a credits/spend-control signal
    ///   with no associated window) yields `blocked(until: nil)` rather than
    ///   fabricating a time.
    /// - If any blocking window's reset is unknown, the whole account's
    ///   reset is unknown too, even if other blocking windows do have known
    ///   reset times — the account isn't usable until *every* blocking
    ///   window clears, so an unknown window's reset makes the account-level
    ///   reset unknown.
    /// - Otherwise, the account-level reset is the latest (max) reset across
    ///   every blocking window — the account only frees up once the
    ///   longest-lived block clears.
    private static func blockedUntil(resets: [Date?]) -> AccountAvailability {
        guard !resets.isEmpty else { return .blocked(until: nil) }
        if resets.contains(where: { $0 == nil }) {
            return .blocked(until: nil)
        }
        return .blocked(until: resets.compactMap { $0 }.max())
    }

    // MARK: Claude

    /// Claude account availability, built on top of `AccountHealthClassifier`'s
    /// existing exhaustion detection so the two classifications never drift
    /// out of sync. Does not infer usability from per-model weekly caps
    /// (`weeklyModels`/opus/sonnet) — only the core five-hour/seven-day
    /// windows block usage.
    static func claudeAvailability(
        health: AccountHealth,
        fiveHour: AccountLimitSummary?,
        sevenDay: AccountLimitSummary?
    ) -> AccountAvailability {
        switch health {
        case .active:
            return .availableNow
        case .exhausted:
            let blockingResets = [fiveHour, sevenDay]
                .compactMap { $0 }
                .filter { $0.usedPercentage >= exhaustedThreshold }
                .map { $0.resetsAt }
            return blockedUntil(resets: blockingResets)
        case .invalidCredentials, .temporaryFailure, .noCredentials:
            return .unknown
        }
    }

    // MARK: Codex

    /// Codex account availability. Server-reported `allowed`/`limitReached`
    /// flags (`CodexUsageData.allowed` / `.limitReached`) are authoritative
    /// over the raw window percentages:
    /// - `limitReached == true` or `allowed == false` blocks, even if no
    ///   window reads >= 100%.
    /// - `limitReached == false` or `allowed == true` allows, even if a
    ///   window reads >= 100%.
    /// - When both flags are `nil` (older/unknown response shape), this
    ///   falls back to the 5h/7d window percentages plus the
    ///   overage-limit/spend-control credit block signals.
    ///
    /// Positive credits/balance never override a confirmed block — they are
    /// only ever consulted as an *additional* blocking signal in the
    /// fallback branch, never to unblock an account the server (or an
    /// exhausted window) already confirmed as blocked.
    static func codexAvailability(_ data: CodexUsageData, isStale: Bool = false) -> AccountAvailability {
        guard !isStale else { return .unknown }

        let windows = [data.primary, data.secondary].compactMap { $0 }
        let exhaustedResets = windows
            .filter { $0.percentage >= exhaustedThreshold }
            .map { $0.resetsAt }

        if data.limitReached == true || data.allowed == false {
            return blockedUntil(resets: exhaustedResets)
        }
        if data.limitReached == false || data.allowed == true {
            return .availableNow
        }

        let creditsBlockSignal = data.extraUsage?.overageLimitReached == true
            || data.extraUsage?.spendControlReached == true
        guard !exhaustedResets.isEmpty || creditsBlockSignal else {
            return .availableNow
        }
        return blockedUntil(resets: exhaustedResets)
    }

    // MARK: Global selection

    /// Selects the single best account to route the next request to across
    /// every known candidate (any provider mix), preserving the caller's
    /// row/store order as the deterministic tie-breaker throughout.
    ///
    /// Precedence:
    /// 1. The first `availableNow` candidate, in the caller-supplied order.
    /// 2. Otherwise, the candidate with the earliest known `blocked(until:)`
    ///    date; ties keep the caller-supplied order (first one wins).
    /// 3. Otherwise `nil` — every candidate is `unknown` or
    ///    `blocked(until: nil)`, so there's nothing to confidently select.
    static func selectNextAvailable(from candidates: [AccountAvailabilityCandidate]) -> AccountAvailabilityCandidate? {
        if let firstAvailable = candidates.first(where: { $0.availability == .availableNow }) {
            return firstAvailable
        }

        let knownBlocked: [(until: Date, candidate: AccountAvailabilityCandidate)] = candidates.compactMap { candidate in
            guard case .blocked(let until) = candidate.availability, let until else { return nil }
            return (until, candidate)
        }
        guard !knownBlocked.isEmpty else { return nil }
        // `min(by:)` keeps the first-encountered element on ties (it only
        // replaces the running minimum on a strict `<`), which preserves the
        // caller's original ordering for equal blocked dates.
        return knownBlocked.min(by: { $0.until < $1.until })?.candidate
    }
}
