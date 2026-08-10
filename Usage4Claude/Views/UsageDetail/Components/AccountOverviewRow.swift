//
//  AccountOverviewRow.swift
//  Usage4Claude
//
//  Single compact row in the multi-account overview (feat/multi-account-overview).
//  Purely a read-only status display — never switches accounts on tap, never
//  logs/exposes credentials. Status color is always paired with an SF Symbol
//  and a text label so color alone never carries the meaning.
//

import SwiftUI

struct AccountOverviewRow: View {
    let row: MultiAccountOverviewModel.Row
    let isCurrent: Bool

    /// Live fetch status is independent from the cached quota summary. A
    /// transient failure can retain the last known percentages while still
    /// showing that the account is currently unavailable.
    private var health: AccountHealth? { row.health }

    /// active = green (available), exhausted = orange (out of quota, not
    /// "dead"), invalidCredentials = red (sign-in truly needed),
    /// temporaryFailure = orange (transient, not the account's fault),
    /// noCredentials = gray (not configured).
    private var statusColor: Color {
        switch health {
        case .active: return .green
        case .exhausted: return .orange
        case .invalidCredentials: return .red
        case .temporaryFailure: return .orange
        case .noCredentials: return .gray
        case .none: return .secondary
        }
    }

    private var statusIcon: String {
        switch health {
        case .active: return "checkmark.circle.fill"
        case .exhausted: return "exclamationmark.circle.fill"
        case .invalidCredentials: return "person.crop.circle.badge.exclamationmark"
        case .temporaryFailure: return "wifi.exclamationmark"
        case .noCredentials: return "circle.dashed"
        case .none: return "hourglass"
        }
    }

    private var statusLabel: String {
        switch health {
        case .active: return L.Accounts.statusActive
        case .exhausted: return L.Accounts.statusExhausted
        case .invalidCredentials: return L.Accounts.statusInvalid
        case .temporaryFailure: return L.Accounts.statusUnavailable
        case .noCredentials: return L.Accounts.statusNotConfigured
        case .none: return L.Usage.loading
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(statusColor.opacity(0.15))
                Image(systemName: statusIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(statusColor)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.account.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if isCurrent {
                        Text(L.Accounts.currentBadge)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }

                    Spacer(minLength: 4)

                    if row.isLoading && row.summary == nil {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                    } else {
                        Text(statusLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(statusColor)
                            .lineLimit(1)
                    }
                }

                if let summary = row.summary {
                    HStack(spacing: 14) {
                        limitCell(label: L.Usage.fiveHourLimitShort, limit: summary.fiveHour)
                        limitCell(label: L.Usage.sevenDayLimitShort, limit: summary.sevenDay)
                    }
                } else if !row.isLoading, let errorMessage = row.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func limitCell(label: String, limit: AccountLimitSummary?) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            if let limit {
                Text(limit.formattedRemainingPercentage)
                    .font(.system(size: 11, weight: .medium))
                Text(limit.formattedCompactResetTime)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var accessibilityText: String {
        var parts: [String] = [row.account.displayName]
        if isCurrent {
            parts.append(L.Accounts.currentBadge)
        }
        parts.append(statusLabel)
        if let fiveHour = row.summary?.fiveHour {
            parts.append("\(L.Usage.fiveHourLimit) \(fiveHour.formattedRemainingPercentage) \(L.Usage.remaining)")
        }
        if let sevenDay = row.summary?.sevenDay {
            parts.append("\(L.Usage.sevenDayLimit) \(sevenDay.formattedRemainingPercentage) \(L.Usage.remaining)")
        }
        return parts.joined(separator: ", ")
    }
}
