//
//  MultiAccountOverviewModel.swift
//  Usage4Claude
//
//  @MainActor observable state layer for the simultaneous multi-account usage
//  overview (feat/multi-account-overview). Exposes per-account rows to
//  SwiftUI without ever mutating AccountStore.currentAccountId — the current
//  account's row reuses DataRefreshManager's already-fetched state, while
//  every other account is polled via ClaudeAccountUsageFetcher with bounded
//  concurrency. No visual/SwiftUI layout lives here; that's a separate task.
//

import Foundation
import Combine

@MainActor
final class MultiAccountOverviewModel: ObservableObject {

    /// One row per Claude account, in the same order as `AccountStore.accounts`.
    struct Row: Identifiable, Equatable {
        let account: Account
        /// Cached quota numbers (five-hour/seven-day used/remaining + reset
        /// times). May be STALE relative to `health` — e.g. retained from the
        /// last successful fetch while a transient failure is in progress, or
        /// deliberately cleared to `nil` on invalid/no credentials so a dead
        /// account never shows old quota data as current truth.
        var summary: AccountUsageSummary?
        /// Authoritative live status for this row, independent of `summary`.
        /// `nil` means unknown/loading — no successful fetch and no typed error
        /// have been observed yet. The UI should read this, not `summary.health`,
        /// to decide what's true right now.
        var health: AccountHealth?
        var isLoading: Bool
        var lastUpdated: Date?
        var errorMessage: String?

        var id: UUID { account.id }
    }

    @Published private(set) var rows: [Row] = []

    /// The current account's id, exposed read-only so the overview UI can mark
    /// which row is "current" without ever mutating it (and without needing to
    /// hold its own `AccountStore` reference).
    var currentAccountId: UUID? { accountStore.currentAccountId }

    private let accountStore: AccountStore
    private let dataRefreshManager: DataRefreshManager
    private let fetcher: ClaudeAccountUsageFetcher

    private var refreshTask: Task<Void, Never>?
    private var lastRefreshStarted: Date?
    private var dataRefreshCancellable: AnyCancellable?

    /// Skip a refresh request if the previous one started less than this long ago,
    /// unless `force: true` is passed.
    private let freshnessWindow: TimeInterval = 30
    /// Upper bound on simultaneous in-flight account fetches.
    private let maxConcurrency = 3

    init(
        accountStore: AccountStore,
        dataRefreshManager: DataRefreshManager,
        fetcher: ClaudeAccountUsageFetcher? = nil
    ) {
        self.accountStore = accountStore
        self.dataRefreshManager = dataRefreshManager
        self.fetcher = fetcher ?? .shared
        rebuildRows()

        // Keep the current-account row in sync whenever DataRefreshManager's
        // own published usage/error/loading state changes, without a new
        // network fetch of our own.
        dataRefreshCancellable = dataRefreshManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshCurrentAccountRow() }
            }
    }

    // MARK: - Public API

    /// Kicks off (or skips, if within the freshness window) a bounded-concurrency
    /// fetch of every account except the current one. The current account's row
    /// is refreshed for free from `dataRefreshManager`'s existing state.
    func refresh(force: Bool = false) {
        rebuildRows()

        if !force, let last = lastRefreshStarted, Date().timeIntervalSince(last) < freshnessWindow {
            return
        }

        refreshTask?.cancel()
        lastRefreshStarted = Date()

        let currentId = accountStore.currentAccountId
        let accountsToPoll = accountStore.accounts.filter { $0.id != currentId }
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

    /// Rebuilds `rows` in `accountStore.accounts` order, preserving each
    /// account's last-known-good summary/timestamp/error across rebuilds
    /// (e.g. when the account list changes) instead of flashing back to a
    /// blank/loading state.
    private func rebuildRows() {
        let currentId = accountStore.currentAccountId
        let previousById = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        rows = accountStore.accounts.map { account in
            if account.id == currentId {
                return currentAccountRow(for: account, previous: previousById[account.id])
            }
            if let previous = previousById[account.id] {
                return Row(
                    account: account,
                    summary: previous.summary,
                    health: previous.health,
                    isLoading: false,
                    lastUpdated: previous.lastUpdated,
                    errorMessage: previous.errorMessage
                )
            }
            return Row(account: account, summary: nil, health: nil, isLoading: false, lastUpdated: nil, errorMessage: nil)
        }
    }

    private func refreshCurrentAccountRow() {
        guard let currentId = accountStore.currentAccountId,
              let index = rows.firstIndex(where: { $0.id == currentId }) else { return }
        rows[index] = currentAccountRow(for: rows[index].account, previous: rows[index])
    }

    /// Builds the current account's row by reusing DataRefreshManager's
    /// already-fetched usage/error/loading state — never a new network call.
    ///
    /// `DataRefreshManager.claudeUsageError` is the authoritative live signal:
    /// a prior successful fetch can leave `usageData` populated even while a
    /// later fetch fails (existing DataRefreshManager behavior, preserved here),
    /// so the typed error — not merely the presence of `usageData` — decides
    /// `health`. Invalid/no-credentials never present stale quota data as
    /// current truth; a transient failure retains it (marked `temporaryFailure`);
    /// a clean success (no typed error) reports the fresh summary and its health.
    private func currentAccountRow(for account: Account, previous: Row?) -> Row {
        let isLoading = dataRefreshManager.isLoading
        let usageData = dataRefreshManager.usageData
        let typedError = dataRefreshManager.claudeUsageError

        let retainedSummary = usageData.map(AccountHealthClassifier.summary(usageData:)) ?? previous?.summary

        guard let typedError else {
            if let usageData {
                let summary = AccountHealthClassifier.summary(usageData: usageData)
                return Row(account: account, summary: summary, health: summary.health, isLoading: isLoading, lastUpdated: Date(), errorMessage: nil)
            }
            // No usage yet and no typed error: unknown/loading state.
            return Row(account: account, summary: retainedSummary, health: nil, isLoading: isLoading, lastUpdated: previous?.lastUpdated, errorMessage: nil)
        }

        let reason = AccountUsageFailureReason(typedError)
        let health = AccountHealthClassifier.health(for: reason)
        let errorMessage = dataRefreshManager.errorMessage

        switch health {
        case .invalidCredentials, .noCredentials:
            // Dead/missing credentials must never present stale quota data as current truth.
            return Row(account: account, summary: nil, health: health, isLoading: isLoading, lastUpdated: previous?.lastUpdated, errorMessage: errorMessage)
        case .temporaryFailure, .active, .exhausted:
            // `health(for:)` only ever returns invalidCredentials/noCredentials/temporaryFailure
            // for a failure reason, but switch exhaustively to avoid silently mis-handling
            // a future case; treat anything else as transient and retain last-known-good.
            return Row(account: account, summary: retainedSummary, health: .temporaryFailure, isLoading: isLoading, lastUpdated: previous?.lastUpdated, errorMessage: errorMessage)
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

    private func fetchOne(_ account: Account) async {
        guard !Task.isCancelled else { return }
        setLoading(true, accountId: account.id)

        let result = await fetcher.fetchUsage(for: account)
        guard !Task.isCancelled else { return }

        applyResult(result, accountId: account.id)
    }

    private func setLoading(_ loading: Bool, accountId: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == accountId }) else { return }
        rows[index].isLoading = loading
    }

    /// Applies a fetch result to the matching row. `health` is always set to
    /// reflect the live outcome. Transient failures retain the last-known-good
    /// `summary` so a single rate-limit/network blip doesn't blank out a
    /// previously healthy row's quota numbers; invalid/no-credentials clear
    /// the summary so stale quota data is never shown as current truth.
    private func applyResult(_ result: Result<UsageData, Error>, accountId: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == accountId }) else { return }
        rows[index].isLoading = false

        switch result {
        case .success(let usageData):
            let summary = AccountHealthClassifier.summary(usageData: usageData)
            rows[index].summary = summary
            rows[index].health = summary.health
            rows[index].errorMessage = nil
            rows[index].lastUpdated = Date()

        case .failure(let error):
            let reason = (error as? UsageError).map(AccountUsageFailureReason.init) ?? .networkError
            let health = AccountHealthClassifier.health(for: reason)
            rows[index].errorMessage = error.localizedDescription
            rows[index].health = health

            switch health {
            case .temporaryFailure:
                break // retain rows[index].summary as last-known-good
            case .invalidCredentials, .noCredentials, .active, .exhausted:
                rows[index].summary = nil
            }
        }
    }
}
