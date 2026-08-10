//
//  MultiAccountOverviewModel.swift
//  Usage4Claude
//
//  @MainActor observable state layer for the simultaneous multi-account usage
//  overview (feat/multi-account-overview, extended for Claude+Codex in
//  feat/next-access-multi-provider). Exposes one ordered row per account —
//  Claude accounts in `AccountStore.accounts` order followed by Codex
//  accounts in `AccountStore.codexAccounts` order (AccountStore keeps the two
//  providers as separate published lists with independent "current account"
//  pointers, so this concatenation is the closest thing to a single
//  deterministic "store order" across both) — to SwiftUI without ever
//  mutating `AccountStore.currentAccountId` / `.currentCodexAccountId`. Each
//  provider's current-account row reuses `DataRefreshManager`'s already-
//  fetched state, while every other account (of either provider) is polled
//  via the matching explicit-account fetcher with bounded concurrency. No
//  visual/SwiftUI layout lives here; that's a separate task.
//

import Foundation
import Combine

@MainActor
final class MultiAccountOverviewModel: ObservableObject {

    /// One row per Claude/Codex account, in `AccountStore` order (see file
    /// header). `Row.availability` is the authoritative "can I use this
    /// account right now" signal (`AccountAvailabilityClassifier`); `health`
    /// remains the coarser display classification the existing UI already
    /// reads.
    struct Row: Identifiable, Equatable {
        let account: Account
        /// Cached quota numbers (five-hour/seven-day used/remaining + reset
        /// times). May be STALE relative to `health` — e.g. retained from the
        /// last successful fetch while a transient failure is in progress, or
        /// deliberately cleared to `nil` on invalid/no credentials so a dead
        /// account never shows old quota data as current truth.
        var summary: AccountUsageSummary?
        /// Coarse-grained display status for this row, independent of
        /// `summary`. `nil` means unknown/loading — no successful fetch and
        /// no typed error have been observed yet. The UI reads this (not
        /// `summary.health`) to decide what's true right now.
        var health: AccountHealth?
        /// Authoritative "does this account have capacity right now" signal
        /// (`AccountAvailabilityClassifier`), independent of the coarser
        /// `health` label above. Defaults to `.unknown` until a successful
        /// fetch (or a fully-classified failure) says otherwise.
        var availability: AccountAvailability
        var isLoading: Bool
        var lastUpdated: Date?
        var errorMessage: String?

        var id: UUID { account.id }
        /// Provider this row belongs to, mirrored from `account.provider` for
        /// convenience at call sites that build `AccountAvailabilityCandidate`.
        var provider: ProviderType { account.provider }
    }

    @Published private(set) var rows: [Row] = []

    /// The current Claude account's id, exposed read-only so the overview UI
    /// can mark which row is "current" without ever mutating it (and without
    /// needing to hold its own `AccountStore` reference).
    var currentAccountId: UUID? { accountStore.currentAccountId }

    /// The current Codex account's id, exposed for the same read-only reason
    /// as `currentAccountId` above — Codex has its own independent "current
    /// account" pointer in `AccountStore`.
    var currentCodexAccountId: UUID? { accountStore.currentCodexAccountId }

    /// Deterministic "which account should the app route to next" pick
    /// across every row (any provider mix), using `rows`' order — i.e.
    /// `AccountStore` order — as the tie-breaker. See
    /// `AccountAvailabilityClassifier.selectNextAvailable`.
    var nextAvailableRow: Row? {
        let candidates = rows.map {
            AccountAvailabilityCandidate(id: $0.id, provider: $0.provider, availability: $0.availability)
        }
        guard let selected = AccountAvailabilityClassifier.selectNextAvailable(from: candidates) else {
            return nil
        }
        return rows.first { $0.id == selected.id }
    }

    private let accountStore: AccountStore
    private let dataRefreshManager: DataRefreshManager
    private let claudeFetcher: ClaudeAccountUsageFetcher
    private let codexFetcher: CodexAccountUsageFetcher

    private var refreshTask: Task<Void, Never>?
    private var lastRefreshStarted: Date?
    private var dataRefreshCancellable: AnyCancellable?

    /// Skip a refresh request if the previous one started less than this long ago,
    /// unless `force: true` is passed.
    private let freshnessWindow: TimeInterval = 30
    /// Upper bound on simultaneous in-flight account fetches, across both providers.
    private let maxConcurrency = 3

    init(
        accountStore: AccountStore,
        dataRefreshManager: DataRefreshManager,
        claudeFetcher: ClaudeAccountUsageFetcher? = nil,
        codexFetcher: CodexAccountUsageFetcher? = nil
    ) {
        self.accountStore = accountStore
        self.dataRefreshManager = dataRefreshManager
        self.claudeFetcher = claudeFetcher ?? .shared
        self.codexFetcher = codexFetcher ?? .shared
        rebuildRows()

        // Keep both providers' current-account rows in sync whenever
        // DataRefreshManager's own published usage/error/loading state
        // changes, without a new network fetch of our own.
        dataRefreshCancellable = dataRefreshManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshCurrentAccountRows() }
            }
    }

    // MARK: - Public API

    /// Kicks off (or skips, if within the freshness window) a bounded-concurrency
    /// fetch of every account except each provider's current one. The current
    /// Claude/Codex accounts' rows are refreshed for free from
    /// `dataRefreshManager`'s existing state.
    func refresh(force: Bool = false) {
        rebuildRows()

        if !force, let last = lastRefreshStarted, Date().timeIntervalSince(last) < freshnessWindow {
            return
        }

        refreshTask?.cancel()
        lastRefreshStarted = Date()

        let currentClaudeId = accountStore.currentAccountId
        let currentCodexId = accountStore.currentCodexAccountId
        let claudeToPoll = accountStore.accounts.filter { $0.id != currentClaudeId }
        let codexToPoll = accountStore.codexAccounts.filter { $0.id != currentCodexId }
        let accountsToPoll = claudeToPoll + codexToPoll
        guard !accountsToPoll.isEmpty else { return }

        refreshTask = Task { [weak self] in
            await self?.fetchAll(accountsToPoll)
        }
    }

    /// Cancels any in-flight polling. Safe to call multiple times.
    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Row construction

    /// Rebuilds `rows` in `AccountStore` order (Claude accounts then Codex
    /// accounts — see file header), preserving each account's last-known-good
    /// summary/health/availability/timestamp/error across rebuilds (e.g. when
    /// the account list changes) instead of flashing back to a blank/loading
    /// state.
    private func rebuildRows() {
        let previousById = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        rows = allAccounts().map { account in
            if isCurrentAccount(account) {
                return currentAccountRow(for: account, previous: previousById[account.id])
            }
            if let previous = previousById[account.id] {
                return Row(
                    account: account,
                    summary: previous.summary,
                    health: previous.health,
                    availability: previous.availability,
                    isLoading: false,
                    lastUpdated: previous.lastUpdated,
                    errorMessage: previous.errorMessage
                )
            }
            return Row(account: account, summary: nil, health: nil, availability: .unknown, isLoading: false, lastUpdated: nil, errorMessage: nil)
        }
    }

    /// Claude accounts (`AccountStore.accounts` order) followed by Codex
    /// accounts (`AccountStore.codexAccounts` order). See file header for why
    /// this concatenation, rather than a single published list, is the
    /// deterministic "store order" for the combined overview.
    private func allAccounts() -> [Account] {
        accountStore.accounts + accountStore.codexAccounts
    }

    private func isCurrentAccount(_ account: Account) -> Bool {
        switch account.provider {
        case .claude:
            return account.id == accountStore.currentAccountId
        case .codex:
            return account.id == accountStore.currentCodexAccountId
        }
    }

    private func refreshCurrentAccountRows() {
        if let currentId = accountStore.currentAccountId,
           let index = rows.firstIndex(where: { $0.id == currentId }) {
            rows[index] = currentAccountRow(for: rows[index].account, previous: rows[index])
        }
        if let currentCodexId = accountStore.currentCodexAccountId,
           let index = rows.firstIndex(where: { $0.id == currentCodexId }) {
            rows[index] = currentAccountRow(for: rows[index].account, previous: rows[index])
        }
    }

    /// Builds a current account's row by reusing DataRefreshManager's
    /// already-fetched usage/error/loading state — never a new network call.
    /// Dispatches to the Claude or Codex variant based on `account.provider`.
    private func currentAccountRow(for account: Account, previous: Row?) -> Row {
        switch account.provider {
        case .claude:
            return currentClaudeAccountRow(for: account, previous: previous)
        case .codex:
            return currentCodexAccountRow(for: account, previous: previous)
        }
    }

    /// `DataRefreshManager.claudeUsageError` is the authoritative live signal:
    /// a prior successful fetch can leave `usageData` populated even while a
    /// later fetch fails (existing DataRefreshManager behavior, preserved here),
    /// so the typed error — not merely the presence of `usageData` — decides
    /// `health`. Invalid/no-credentials never present stale quota data as
    /// current truth; a transient failure retains it (marked `temporaryFailure`);
    /// a clean success (no typed error) reports the fresh summary and its health,
    /// with `availability` derived via `AccountAvailabilityClassifier.claudeAvailability`.
    private func currentClaudeAccountRow(for account: Account, previous: Row?) -> Row {
        let isLoading = dataRefreshManager.isLoading
        let usageData = dataRefreshManager.usageData
        let typedError = dataRefreshManager.claudeUsageError

        let retainedSummary = usageData.map(AccountHealthClassifier.summary(usageData:)) ?? previous?.summary

        guard let typedError else {
            if let usageData {
                let summary = AccountHealthClassifier.summary(usageData: usageData)
                let availability = AccountAvailabilityClassifier.claudeAvailability(
                    health: summary.health,
                    fiveHour: summary.fiveHour,
                    sevenDay: summary.sevenDay
                )
                return Row(account: account, summary: summary, health: summary.health, availability: availability, isLoading: isLoading, lastUpdated: Date(), errorMessage: nil)
            }
            // No usage yet and no typed error: unknown/loading state.
            return Row(account: account, summary: retainedSummary, health: nil, availability: .unknown, isLoading: isLoading, lastUpdated: previous?.lastUpdated, errorMessage: nil)
        }

        let reason = AccountUsageFailureReason(typedError)
        let health = AccountHealthClassifier.health(for: reason)
        let errorMessage = dataRefreshManager.errorMessage

        switch health {
        case .invalidCredentials, .noCredentials:
            // Dead/missing credentials must never present stale quota data as current truth.
            return Row(account: account, summary: nil, health: health, availability: .unknown, isLoading: isLoading, lastUpdated: previous?.lastUpdated, errorMessage: errorMessage)
        case .temporaryFailure, .active, .exhausted:
            // `health(for:)` only ever returns invalidCredentials/noCredentials/temporaryFailure
            // for a failure reason, but switch exhaustively to avoid silently mis-handling
            // a future case; treat anything else as transient and retain last-known-good.
            return Row(account: account, summary: retainedSummary, health: .temporaryFailure, availability: .unknown, isLoading: isLoading, lastUpdated: previous?.lastUpdated, errorMessage: errorMessage)
        }
    }

    /// Mirrors `currentClaudeAccountRow`'s stale/error semantics, reading
    /// `DataRefreshManager.codexUsageData` / `.codexUsageError` /
    /// `.codexErrorMessage` instead. `availability` is derived via
    /// `AccountAvailabilityClassifier.codexAvailability`, which treats the
    /// server's `allowed`/`limitReached` flags as authoritative over raw
    /// window percentages; `summary`'s window percentages/reset dates are
    /// copied unchanged from the Codex payload by `AccountHealthClassifier.summary(codexData:availability:)`.
    private func currentCodexAccountRow(for account: Account, previous: Row?) -> Row {
        let isLoading = dataRefreshManager.isLoading
        let codexData = dataRefreshManager.codexUsageData
        let typedError = dataRefreshManager.codexUsageError

        let retainedSummary = codexData.map {
            AccountHealthClassifier.summary(codexData: $0, availability: AccountAvailabilityClassifier.codexAvailability($0))
        } ?? previous?.summary

        guard let typedError else {
            if let codexData {
                let availability = AccountAvailabilityClassifier.codexAvailability(codexData)
                let summary = AccountHealthClassifier.summary(codexData: codexData, availability: availability)
                return Row(account: account, summary: summary, health: summary.health, availability: availability, isLoading: isLoading, lastUpdated: Date(), errorMessage: nil)
            }
            // No usage yet and no typed error: unknown/loading state.
            return Row(account: account, summary: retainedSummary, health: nil, availability: .unknown, isLoading: isLoading, lastUpdated: previous?.lastUpdated, errorMessage: nil)
        }

        let reason = AccountUsageFailureReason(typedError)
        let health = AccountHealthClassifier.health(for: reason)
        let errorMessage = dataRefreshManager.codexErrorMessage

        switch health {
        case .invalidCredentials, .noCredentials:
            // Dead/missing credentials must never present stale quota data as current truth.
            return Row(account: account, summary: nil, health: health, availability: .unknown, isLoading: isLoading, lastUpdated: previous?.lastUpdated, errorMessage: errorMessage)
        case .temporaryFailure, .active, .exhausted:
            return Row(account: account, summary: retainedSummary, health: .temporaryFailure, availability: .unknown, isLoading: isLoading, lastUpdated: previous?.lastUpdated, errorMessage: errorMessage)
        }
    }

    // MARK: - Bounded-concurrency polling

    private func fetchAll(_ accounts: [Account]) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = accounts[...]

            func launchNext() {
                guard let account = pending.first else { return }
                pending = pending.dropFirst()
                group.addTask { [weak self] in
                    await self?.fetchOne(account)
                }
            }

            for _ in 0..<min(maxConcurrency, accounts.count) {
                launchNext()
            }
            while await group.next() != nil {
                launchNext()
            }
        }
    }

    /// Fetches one account's usage via the fetcher matching its provider,
    /// then applies the result to the matching row.
    private func fetchOne(_ account: Account) async {
        guard !Task.isCancelled else { return }
        setLoading(true, accountId: account.id)

        switch account.provider {
        case .claude:
            let result = await claudeFetcher.fetchUsage(for: account)
            guard !Task.isCancelled else { return }
            applyClaudeResult(result, accountId: account.id)
        case .codex:
            let result = await codexFetcher.fetchUsage(for: account)
            guard !Task.isCancelled else { return }
            applyCodexResult(result, accountId: account.id)
        }
    }

    private func setLoading(_ loading: Bool, accountId: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == accountId }) else { return }
        rows[index].isLoading = loading
    }

    /// Applies a Claude fetch result to the matching row. `health` and
    /// `availability` always reflect the live outcome. Transient failures
    /// retain the last-known-good `summary` so a single rate-limit/network
    /// blip doesn't blank out a previously healthy row's quota numbers;
    /// invalid/no-credentials clear the summary so stale quota data is never
    /// shown as current truth. Any typed or unknown fetch failure sets
    /// `availability` to `.unknown` — only a successful fetch can establish
    /// `.availableNow`/`.blocked`.
    private func applyClaudeResult(_ result: Result<UsageData, Error>, accountId: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == accountId }) else { return }
        rows[index].isLoading = false

        switch result {
        case .success(let usageData):
            let summary = AccountHealthClassifier.summary(usageData: usageData)
            let availability = AccountAvailabilityClassifier.claudeAvailability(
                health: summary.health,
                fiveHour: summary.fiveHour,
                sevenDay: summary.sevenDay
            )
            rows[index].summary = summary
            rows[index].health = summary.health
            rows[index].availability = availability
            rows[index].errorMessage = nil
            rows[index].lastUpdated = Date()

        case .failure(let error):
            let reason = (error as? UsageError).map(AccountUsageFailureReason.init) ?? .networkError
            let health = AccountHealthClassifier.health(for: reason)
            rows[index].errorMessage = error.localizedDescription
            rows[index].health = health
            rows[index].availability = .unknown

            switch health {
            case .temporaryFailure:
                break // retain rows[index].summary as last-known-good
            case .invalidCredentials, .noCredentials, .active, .exhausted:
                rows[index].summary = nil
            }
        }
    }

    /// Mirrors `applyClaudeResult`'s stale/error retention semantics for a
    /// Codex fetch result. On success, `summary` and `availability` are built
    /// via `AccountAvailabilityClassifier.codexAvailability` /
    /// `AccountHealthClassifier.summary(codexData:availability:)`, which keep
    /// the server's `allowed`/`limitReached` flags authoritative.
    private func applyCodexResult(_ result: Result<CodexUsageData, Error>, accountId: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == accountId }) else { return }
        rows[index].isLoading = false

        switch result {
        case .success(let codexData):
            let availability = AccountAvailabilityClassifier.codexAvailability(codexData)
            let summary = AccountHealthClassifier.summary(codexData: codexData, availability: availability)
            rows[index].summary = summary
            rows[index].health = summary.health
            rows[index].availability = availability
            rows[index].errorMessage = nil
            rows[index].lastUpdated = Date()

        case .failure(let error):
            let reason = (error as? UsageError).map(AccountUsageFailureReason.init) ?? .networkError
            let health = AccountHealthClassifier.health(for: reason)
            rows[index].errorMessage = error.localizedDescription
            rows[index].health = health
            rows[index].availability = .unknown

            switch health {
            case .temporaryFailure:
                break // retain rows[index].summary as last-known-good
            case .invalidCredentials, .noCredentials, .active, .exhausted:
                rows[index].summary = nil
            }
        }
    }
}
