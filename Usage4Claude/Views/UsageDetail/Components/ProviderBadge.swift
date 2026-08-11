//
//  ProviderBadge.swift
//  Usage4Claude
//
//  Small pill badge identifying an account row's provider (Claude vs Codex),
//  shared between `AccountOverviewRow` and the next-available card in
//  `AccountsOverviewView` (feat/next-access-multi-provider). Text-only —
//  deliberately avoids guessing at brand SF Symbols/logos (see
//  `AuthSettingsView.providerIcon` for the app's actual bundled-icon
//  convention, which isn't a fit at this badge's compact scale) — and mirrors
//  the visual language `AccountOverviewRow`'s existing "Current" pill already
//  established: label text on a tinted rounded background, color paired with
//  text so meaning never rests on color alone.
//

import SwiftUI

struct ProviderBadge: View {
    let provider: ProviderType

    var body: some View {
        Text(provider.localizedLabel)
            .font(.system(size: 9, weight: .bold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(provider.accentColor.opacity(0.22))
            .foregroundColor(provider.accentColor)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(provider.accentColor.opacity(0.5), lineWidth: 0.75)
            )
    }
}
