//
//  ProviderType+Display.swift
//  Usage4Claude
//
//  UI-only display helpers for `ProviderType` (feat/next-access-multi-provider).
//  Lives outside `Models/ProviderType.swift` for the same reason
//  `AccountUsageStatus+Formatting.swift` is split from `AccountUsageStatus.swift`:
//  `ProviderType.swift` is part of the SwiftPM `Usage4ClaudeCore` test target
//  (see Package.swift) and must stay free of SwiftUI/`L.*` dependencies, while
//  the accessors below need both.
//

import SwiftUI

extension ProviderType {
    /// Localized, user-facing provider label for badges/accessibility text.
    /// Deliberately routed through `L.Accounts` (never a hardcoded literal) even
    /// though these brand names read the same across every supported locale.
    var localizedLabel: String {
        switch self {
        case .claude: return L.Accounts.providerClaude
        case .codex: return L.Accounts.providerCodex
        }
    }

    /// Accent color used to visually distinguish provider badges, matching the
    /// color already established for account selection in
    /// `AuthSettingsView.accountRow` (Claude = system blue, Codex = teal).
    var accentColor: Color {
        switch self {
        case .claude: return .blue
        case .codex: return Color(red: 45 / 255.0, green: 212 / 255.0, blue: 191 / 255.0)
        }
    }
}
