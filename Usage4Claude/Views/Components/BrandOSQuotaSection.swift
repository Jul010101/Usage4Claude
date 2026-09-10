//
//  BrandOSQuotaSection.swift
//  Usage4Claude
//
//  Created by Claude Code on 2026-09-09.
//  Copyright © 2025 f-is-h. All rights reserved.
//
//  Phase C (feat/brandos-quota): read-only popover section rendering the
//  Brand OS quota daemon's on-disk state. Consumes `BrandOSQuotaData` as
//  assembled by `BrandOSQuotaService` — never re-derives seat/liveness, since
//  `DisplaySeat` already folds daemon liveness into the raw seat reading (a
//  stale daemon's last-known "live" seat can never render as confidently live).
//

import SwiftUI

/// Compact, borderless section showing Brand OS pipeline state at a glance:
/// Figma seat status, pending gate-script queue depth, and the last finished
/// gate verdict. Mirrors `CodexColumnView`'s plain-stack house style — no card
/// background, `.padding(.horizontal, 14)`, system fonts, green/red/gray
/// semantics always paired with an icon so color is never the sole signal.
struct BrandOSQuotaSection: View {
    let data: BrandOSQuotaData

    /// Reserved layout constants shared with `UsageDetailView`'s fixed-height
    /// popover math (`brandOSSectionHeight`) so the reserved frame height
    /// never drifts from what this view actually renders.
    static let headerHeight: CGFloat = 22
    static let rowHeight: CGFloat = 20
    static let rowSpacing: CGFloat = 5
    /// Worst case row count: seat row + queue row + verdict row.
    static let maxRowCount = 3

    private static let queuePreviewLimit = 2
    private static let fileKeyTruncateLength = 7

    var body: some View {
        VStack(spacing: Self.rowSpacing) {
            headerRow
            seatRow
            queueRow
            if let lastResult = data.lastResult {
                verdictRow(lastResult)
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "paintpalette")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Text(L.BrandOS.title)
                .font(.headline)
            Spacer()
        }
        .frame(minHeight: Self.headerHeight, alignment: .leading)
    }

    // MARK: - Seat

    @ViewBuilder
    private var seatRow: some View {
        if data.access == .denied {
            HStack(spacing: 4) {
                statusIcon("lock.fill", color: .gray)
                Text(L.BrandOS.accessNeeded)
                    .font(.system(size: 12))
                    .fontWeight(.medium)
                    .foregroundColor(.gray)
                    .lineLimit(1)
                Spacer()
                Button(action: {}) {
                    Text(L.BrandOS.grantAccess)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }
            .frame(minHeight: Self.rowHeight, alignment: .leading)
        } else {
            // `data.access` can only be `.ok` here — `.absent` is filtered out
            // upstream in `UsageDetailView.isBrandOSVisible` before this view
            // is ever instantiated.
            switch data.seat {
            case .live:
                statusRow(icon: "checkmark.circle.fill", color: .green, text: L.BrandOS.seatLive)
            case .blocked:
                statusRow(icon: "exclamationmark.triangle.fill", color: .orange, text: L.BrandOS.seatBlocked)
            case .staleLastKnown:
                statusRow(icon: "moon.zzz.fill", color: .gray, text: L.BrandOS.daemonStopped)
            case .unknown:
                statusRow(icon: "questionmark.circle.fill", color: .gray, text: L.BrandOS.seatUnknown)
            }
        }
    }

    // MARK: - Queue

    private var queueRow: some View {
        HStack(spacing: 4) {
            statusIcon("tray.full.fill", color: .secondary)
            Text(queueText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .frame(minHeight: Self.rowHeight, alignment: .leading)
    }

    private var queueText: String {
        guard !data.queue.isEmpty else { return L.BrandOS.queueEmpty }
        let preview = data.queue.prefix(Self.queuePreviewLimit)
            .map(queueItemLabel)
            .joined(separator: ", ")
        return "\(L.BrandOS.queue(data.queue.count)) — \(preview)"
    }

    private func queueItemLabel(_ item: QueueItem) -> String {
        let script = item.script ?? "?"
        guard let fileKey = item.fileKey else { return script }
        let truncated = fileKey.count > Self.fileKeyTruncateLength
            ? "\(fileKey.prefix(Self.fileKeyTruncateLength))…"
            : fileKey
        return "\(script) · \(truncated)"
    }

    // MARK: - Verdict

    private func verdictRow(_ result: BrandOSQuotaData.LastResult) -> some View {
        HStack(spacing: 4) {
            verdictIcon(result.verdict)
            Text(verdictText(result))
                .font(.system(size: 12))
                .fontWeight(.medium)
                .foregroundColor(verdictColor(result.verdict))
                .lineLimit(1)
            Spacer()
        }
        .frame(minHeight: Self.rowHeight, alignment: .leading)
    }

    private func verdictText(_ result: BrandOSQuotaData.LastResult) -> String {
        let label: String
        switch result.verdict {
        case .green: label = L.BrandOS.verdictGreen
        case .red: label = L.BrandOS.verdictRed
        case .held: label = L.BrandOS.verdictHeld
        case .unknown: label = L.BrandOS.verdictUnknown
        }
        guard let script = result.script else { return label }
        return "\(script) — \(label)"
    }

    private func verdictColor(_ verdict: GateVerdict) -> Color {
        switch verdict {
        case .green: return .green
        case .red: return .red
        case .held, .unknown: return .gray
        }
    }

    @ViewBuilder
    private func verdictIcon(_ verdict: GateVerdict) -> some View {
        switch verdict {
        case .green:
            statusIcon("checkmark.circle.fill", color: .green)
        case .red:
            statusIcon("xmark.circle.fill", color: .red)
        case .held:
            statusIcon("clock.fill", color: .gray)
        case .unknown:
            statusIcon("questionmark.circle.fill", color: .gray)
        }
    }

    // MARK: - Shared row style

    private func statusRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            statusIcon(icon, color: color)
            Text(text)
                .font(.system(size: 12))
                .fontWeight(.medium)
                .foregroundColor(color)
                .lineLimit(1)
            Spacer()
        }
        .frame(minHeight: Self.rowHeight, alignment: .leading)
    }

    private func statusIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 11))
            .foregroundColor(color)
    }
}
