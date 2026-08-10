//
//  AccountUsageStatus+Formatting.swift
//  Usage4Claude
//
//  Locale-aware display formatting for `AccountLimitSummary`, used by the
//  multi-account overview UI (feat/multi-account-overview). Lives outside
//  `Helpers/AccountUsageStatus.swift` for the same reason
//  `UsageData+Formatting.swift` is split from `Models/ClaudeAPIResponseModels.swift`:
//  it depends on `L.*` (main-app-only), while AccountUsageStatus.swift must stay
//  dependency-free to remain compilable in the SwiftPM `Usage4ClaudeCore` test target.
//
//  Reuses `UsageData.LimitData`'s existing formatting (UsageData+Formatting.swift)
//  by bridging through a throwaway `UsageData.LimitData` value instead of
//  duplicating reset-time formatting logic.
//

import Foundation

extension AccountLimitSummary {
    /// Bridges to `UsageData.LimitData` purely to reuse its existing
    /// locale-aware formatting helpers — never persisted, never sent anywhere.
    private var asLimitData: UsageData.LimitData {
        UsageData.LimitData(percentage: usedPercentage, resetsAt: resetsAt)
    }

    /// Compact reset-time text ("Today 14:30" / "Tomorrow 09:00" / "Nov 29"),
    /// reusing `UsageData.LimitData.formattedCompactResetTime`. This is the
    /// quota window's reset time, never a subscription/billing renewal date.
    var formattedCompactResetTime: String {
        asLimitData.formattedCompactResetTime
    }

    /// e.g. "62%" — REMAINING (not used) percentage, already clamped to
    /// [0, 100] by `AccountLimitSummary.remainingPercentage`.
    var formattedRemainingPercentage: String {
        "\(Int(remainingPercentage.rounded()))%"
    }
}
