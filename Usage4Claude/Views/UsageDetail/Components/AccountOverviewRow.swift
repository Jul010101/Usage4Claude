//
//  AccountOverviewRow.swift
//  Usage4Claude
//
//  Single compact row in the multi-account overview (feat/multi-account-overview,
//  simplified for feat/overview-ux-polish). Purely a read-only status display —
//  never switches accounts on tap, never logs/exposes credentials. Status color
//  is always paired with an SF Symbol and a text label so color alone never
//  carries the meaning.
//
//  Deliberately just two lines per row: a name/status line, and one short
//  explanatory line answering "how much room is left" (active) or "when can I
//  use it again" (inactive) — the exact mental model requested over the
//  earlier dual 5h/7d bar-column layout, which read as too dense/messy. Full
//  5h/7d window detail remains one tap away in the single-account detail view
//  (reachable via the header's person-icon toggle); this row is intentionally
//  a coarser at-a-glance summary, not a replacement for that detail.
//

import SwiftUI

struct AccountOverviewRow: View {
    let row: MultiAccountOverviewModel.Row
    let isCurrent: Bool

    /// Live fetch status is independent from the cached quota summary. A
    /// transient failure can retain the last known percentages while still
    /// showing that the account is currently unavailable.
    private var health: AccountHealth? { row.health }

    /// active = green (usable now), exhausted = orange ("Inactive" — out of
    /// quota, not "dead"), invalidCredentials = red (sign-in truly needed),
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

    /// The right-aligned status word on the primary line. "Active"/"Inactive"
    /// for the two health states the user actually cares about tracking at a
    /// glance; the three attention states keep their existing specific
    /// reason text (never a generic word) so a real problem is never
    /// under-described.
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

    /// The window (five-hour or seven-day) driving "how much room is left":
    /// whichever non-nil window has the SMALLER remaining percentage — that's
    /// the one that actually constrains usage first, so the number and its
    /// renewal time (below) always describe the same window instead of a
    /// mismatched pairing. Ties prefer the five-hour window, mirroring
    /// `AccountUsageSummary.primary`'s existing five-hour-first convention.
    private var bindingWindow: AccountLimitSummary? {
        switch (row.summary?.fiveHour, row.summary?.sevenDay) {
        case let (fiveHour?, sevenDay?):
            return fiveHour.remainingPercentage <= sevenDay.remainingPercentage ? fiveHour : sevenDay
        case let (fiveHour?, nil):
            return fiveHour
        case let (nil, sevenDay?):
            return sevenDay
        case (nil, nil):
            return nil
        }
    }

    /// "<N>% left", or "<N>% left · renews <reset>" when the binding window's
    /// reset time is known. Never calls `formattedCompactResetTime` on a nil
    /// `resetsAt` — that helper falls back to a bare "-" for nil, which is
    /// exactly the dangling-placeholder look this row avoids elsewhere, so
    /// the reset clause is only appended once a real date is confirmed.
    private var percentLeftText: String? {
        guard let window = bindingWindow else { return nil }
        let percent = "\(Int(window.remainingPercentage.rounded()))%"
        guard window.resetsAt != nil else {
            return L.Accounts.percentLeft(percent)
        }
        return L.Accounts.percentLeftRenews(percent, window.formattedCompactResetTime)
    }

    /// "When can I use it again" — reuses `row.availability`'s authoritative
    /// `blocked(until:)` date (the same value the Next Available card and the
    /// app-wide next-account selector already rely on) instead of
    /// recomputing anything from `summary`, so this row can never disagree
    /// with the rest of the app about when an account frees up. Never
    /// fabricates a time: an unknown reset reads as an honest, explicit
    /// "unknown" message instead of guessing.
    private var usableAgainText: String {
        if case .blocked(let until) = row.availability, let until {
            return L.Accounts.usableAgain(until.formattedCompactResetTime)
        }
        return L.Accounts.resetTimeUnknown
    }

    /// One short line under the name that matches the user's actual
    /// question for each state: how much is left (active), when it resets
    /// (inactive/exhausted), or why it needs attention (the three failure
    /// states, reusing their own status label as the reason).
    private var secondaryText: String {
        switch health {
        case .active:
            return percentLeftText ?? ""
        case .exhausted:
            return usableAgainText
        case .invalidCredentials:
            return L.Accounts.statusInvalid
        case .temporaryFailure:
            return L.Accounts.statusUnavailable
        case .noCredentials:
            return L.Accounts.statusNotConfigured
        case .none:
            return ""
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

                    ProviderBadge(provider: row.provider)

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
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(statusColor)
                            .lineLimit(1)
                    }
                }

                if !secondaryText.isEmpty {
                    Text(secondaryText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(isCurrent ? 6 : 0)
        .overlay(
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 1),
            alignment: .bottom
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts: [String] = [row.account.displayName, row.provider.localizedLabel]
        if isCurrent {
            parts.append(L.Accounts.currentBadge)
        }
        parts.append(statusLabel)
        if !secondaryText.isEmpty {
            parts.append(secondaryText)
        }
        return parts.joined(separator: ", ")
    }
}
