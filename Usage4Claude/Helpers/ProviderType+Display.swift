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

    /// Accent color used to visually distinguish provider badges. Claude =
    /// system blue. Codex/ChatGPT was previously a teal that read low-
    /// contrast on the dark popover and sat too close to the green "Active"
    /// status color, so it's a distinct indigo/purple instead — deliberately
    /// outside the green/teal/orange/red palette reserved for account
    /// health/status, so provider identity and account status are never
    /// confusable at a glance (feat/overview-ux-polish).
    var accentColor: Color {
        switch self {
        case .claude: return .blue
        case .codex: return Color(red: 88 / 255.0, green: 86 / 255.0, blue: 214 / 255.0)
        }
    }
}
