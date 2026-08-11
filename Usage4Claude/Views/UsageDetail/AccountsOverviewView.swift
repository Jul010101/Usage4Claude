//
//  AccountsOverviewView.swift
//  Usage4Claude
//
//  Compact, scan-friendly simultaneous multi-account usage overview
//  (feat/multi-account-overview). Shown by UsageDetailView in place of the
//  normal single/dual-provider body when there are 2+ Claude accounts and the
//  user hasn't toggled back to the detailed current-account view.
//
//  Purely presentational: all data comes from the `MultiAccountOverviewModel`
//  owned by MenuBarManager. Never switches accounts, never mutates
//  currentAccountId, and never starts its own polling — refresh is driven
//  entirely by the header's refresh button (routed through the existing
//  `.refresh` menu action) and by MenuBarManager on popover open/close.
//
//  Uses a plain VStack (not List) so it sizes exactly to its content — SwiftUI
//  List insets/backgrounds don't match this app's compact popover chrome. The
//  account rows themselves live in a bounded `ScrollView` (see `rowsList`) so
//  a large account count scrolls instead of growing the popover unbounded,
//  while the header/next-access card/summary row above it always stay put.
//

import SwiftUI

struct AccountsOverviewView: View {
    @ObservedObject var model: MultiAccountOverviewModel
    @ObservedObject var refreshState: RefreshState
    var onToggleDetail: () -> Void
    var onRefresh: () -> Void

    /// Row height/spacing/visible-row cap shared with `UsageDetailView.accountsOverviewHeight`
    /// so the popover's outer `.frame(height:)` always matches this view's actual
    /// capped layout exactly — no clipping, no dead space below a short account list.
    /// `rowHeight` fits the row's 2 visual lines (name+badges+status word, then
    /// one short secondary line: percent-left / usable-again date / attention
    /// reason). `maxVisibleRows` is 12 so a realistic account count (the user's
    /// current 4 active + 2 inactive, and headroom well beyond that) renders
    /// scroll-free — the `ScrollView` below only kicks in past that cap.
    static let rowHeight: CGFloat = 48
    static let rowSpacing: CGFloat = 4
    static let maxVisibleRows: Int = 12
    /// Matches `nextAccessCard`'s fixed layout (title + name/badge line + status
    /// line, each capped to one line) so the card's height never varies across
    /// its three presentations (available now / blocked / unknown).
    static let nextAccessCardHeight: CGFloat = 68

    private var availableCount: Int {
        model.rows.filter { $0.health == .active }.count
    }

    private var exhaustedCount: Int {
        model.rows.filter { $0.health == .exhausted }.count
    }

    /// Invalid credentials, transient failures, and unconfigured accounts all
    /// need the user's attention (in different ways), so they're grouped
    /// together in this at-a-glance summary count.
    private var attentionCount: Int {
        model.rows.filter {
            switch $0.health {
            case .invalidCredentials, .temporaryFailure, .noCredentials:
                return true
            default:
                return false
            }
        }.count
    }

    /// Display presentation for `model.nextAvailableRow`, mirrored 1:1 from its
    /// `AccountAvailability` so this view never recomputes selection — it only
    /// decides how to present what the model already selected via
    /// `AccountAvailabilityClassifier.selectNextAvailable`. That selector only
    /// ever returns a row that's `.availableNow` or `.blocked(until: <known
    /// date>)`, but `.unknown` / `.blocked(until: nil)` are still handled
    /// defensively below so an honest "unknown" message shows rather than ever
    /// fabricating a date.
    private enum NextAccessPresentation {
        case availableNow(row: MultiAccountOverviewModel.Row)
        case blocked(row: MultiAccountOverviewModel.Row, until: Date)
        case unknown
    }

    private var nextAccessPresentation: NextAccessPresentation {
        guard let row = model.nextAvailableRow else { return .unknown }
        switch row.availability {
        case .availableNow:
            return .availableNow(row: row)
        case .blocked(let until):
            guard let until else { return .unknown }
            return .blocked(row: row, until: until)
        case .unknown:
            return .unknown
        }
    }

    /// Claude and Codex keep independent "current account" pointers in
    /// `AccountStore`, so a row's "current" badge must compare against the
    /// pointer matching its own provider, not always the Claude one.
    private func isCurrentRow(_ row: MultiAccountOverviewModel.Row) -> Bool {
        switch row.provider {
        case .claude: return row.id == model.currentAccountId
        case .codex: return row.id == model.currentCodexAccountId
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            nextAccessCard
            summaryRow
            rowsList
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.2.fill")
                .font(.system(size: 16))
                .foregroundColor(.blue)
            Text(L.Accounts.overviewTitle)
                .font(.headline)

            Spacer()

            Button(action: onToggleDetail) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L.Accounts.toggleToDetail)
            .accessibilityLabel(L.Accounts.toggleToDetail)

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .opacity(refreshState.canRefresh ? 1.0 : 0.3)
                    .rotationEffect(.degrees(refreshState.isRefreshing ? 360 : 0))
                    .animation(
                        refreshState.isRefreshing
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: refreshState.isRefreshing
                    )
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!refreshState.canRefresh || refreshState.isRefreshing)
            .focusable(false)
            .help(L.Usage.refresh)
            .accessibilityLabel(L.Usage.refresh)
        }
        .frame(height: 20)
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            summaryBadge(count: availableCount, label: L.Accounts.summaryAvailable, color: .green)
            summaryBadge(count: exhaustedCount, label: L.Accounts.summaryExhausted, color: .orange)
            summaryBadge(count: attentionCount, label: L.Accounts.summaryAttention, color: .red)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    /// Each badge is `.lineLimit(1).fixedSize()` so the summary row is
    /// guaranteed to render as a single line, never wrapping its count+label
    /// pair onto two lines regardless of available width.
    private func summaryBadge(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }

    // MARK: - Next Access Card

    private var nextAccessCard: some View {
        let presentation = nextAccessPresentation
        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(nextAccessColor(presentation).opacity(0.15))
                Image(systemName: nextAccessIcon(presentation))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(nextAccessColor(presentation))
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(L.Accounts.nextAccessTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)

                switch presentation {
                case .availableNow(let row):
                    HStack(spacing: 6) {
                        Text(row.account.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        ProviderBadge(provider: row.provider)
                    }
                    Text(L.Accounts.nextAccessAvailableNow)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green)
                        .lineLimit(1)

                case .blocked(let row, let until):
                    HStack(spacing: 6) {
                        Text(row.account.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        ProviderBadge(provider: row.provider)
                    }
                    Text(L.Accounts.nextAccessResumesAt(until.formattedCompactResetTime))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                case .unknown:
                    Text(L.Accounts.nextAccessUnknown)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: Self.nextAccessCardHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nextAccessAccessibilityText(presentation))
    }

    private func nextAccessIcon(_ presentation: NextAccessPresentation) -> String {
        switch presentation {
        case .availableNow: return "checkmark.circle.fill"
        case .blocked: return "clock.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private func nextAccessColor(_ presentation: NextAccessPresentation) -> Color {
        switch presentation {
        case .availableNow: return .green
        case .blocked: return .orange
        case .unknown: return .secondary
        }
    }

    private func nextAccessAccessibilityText(_ presentation: NextAccessPresentation) -> String {
        var parts: [String] = [L.Accounts.nextAccessTitle]
        switch presentation {
        case .availableNow(let row):
            parts.append(row.account.displayName)
            parts.append(row.provider.localizedLabel)
            parts.append(L.Accounts.nextAccessAvailableNow)
        case .blocked(let row, let until):
            parts.append(row.account.displayName)
            parts.append(row.provider.localizedLabel)
            parts.append(L.Accounts.nextAccessResumesAt(until.formattedCompactResetTime))
        case .unknown:
            parts.append(L.Accounts.nextAccessUnknown)
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Rows (bounded scroll)

    /// Caps the visible viewport to `maxVisibleRows` rows: for account counts at
    /// or below the cap this equals the rows' exact natural height (no dead
    /// space, no scroll indicator), and above the cap it bounds the `ScrollView`
    /// so the header/next-access card/summary row always stay visible.
    private var rowsViewportHeight: CGFloat {
        let count = max(min(model.rows.count, Self.maxVisibleRows), 1)
        return CGFloat(count) * Self.rowHeight + CGFloat(max(0, count - 1)) * Self.rowSpacing
    }

    /// Display-only grouping for scannability: available (active) rows
    /// first, then exhausted, then everything needing attention (invalid
    /// credentials / temporary failure / no credentials / still loading).
    /// Stable within each group — ties break on the row's original index in
    /// `model.rows`, so this never reorders relative to the store beyond the
    /// group boundaries. Purely a computed view-local copy: never mutates
    /// `model.rows`, `currentAccountId`, or `nextAvailableRow` selection.
    private var displayRows: [MultiAccountOverviewModel.Row] {
        model.rows.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = displaySortRank(for: lhs.element.health)
                let rhsRank = displaySortRank(for: rhs.element.health)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func displaySortRank(for health: AccountHealth?) -> Int {
        switch health {
        case .active: return 0
        case .exhausted: return 1
        case .invalidCredentials, .temporaryFailure, .noCredentials, .none: return 2
        }
    }
    private var rowsList: some View {
        ScrollView {
            LazyVStack(spacing: Self.rowSpacing) {
                ForEach(displayRows) { row in
                    AccountOverviewRow(row: row, isCurrent: isCurrentRow(row))
                }
            }
        }
        .frame(maxHeight: rowsViewportHeight)
    }
}

// 预览
struct AccountsOverviewView_Previews: PreviewProvider {
    static var previews: some View {
        let accountStore = AccountStore()
        let dataRefreshManager = DataRefreshManager()
        let model = MultiAccountOverviewModel(accountStore: accountStore, dataRefreshManager: dataRefreshManager)
        return AccountsOverviewView(
            model: model,
            refreshState: dataRefreshManager.refreshState,
            onToggleDetail: {},
            onRefresh: {}
        )
        .frame(width: 320)
    }
}
