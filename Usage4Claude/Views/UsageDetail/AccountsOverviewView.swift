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
//  List insets/backgrounds don't match this app's compact popover chrome.
//

import SwiftUI

struct AccountsOverviewView: View {
    @ObservedObject var model: MultiAccountOverviewModel
    @ObservedObject var refreshState: RefreshState
    var onToggleDetail: () -> Void
    var onRefresh: () -> Void

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            summaryRow
            VStack(spacing: 6) {
                ForEach(model.rows) { row in
                    AccountOverviewRow(row: row, isCurrent: row.account.id == model.currentAccountId)
                }
            }
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

    private func summaryBadge(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
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
