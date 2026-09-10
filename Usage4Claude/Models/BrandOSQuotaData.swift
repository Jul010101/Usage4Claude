//
//  BrandOSQuotaData.swift
//  Usage4Claude
//
//  Created by Claude Code on 2026-09-09.
//  Copyright © 2025 f-is-h. All rights reserved.
//
//  Foundation-only, Equatable snapshot of the Brand OS quota feature's
//  current on-disk state (feat/brandos-quota), assembled by
//  `BrandOSQuotaService` from the pure parsing/classification core in
//  `Helpers/BrandOSQuotaParser.swift`. This is a plain data holder — no
//  SwiftUI/AppKit dependency — published by `DataRefreshManager` and
//  threaded through to `UsageDetailView` (Phase C renders it; this phase
//  only plumbs it through, unused in the view for now).
//

import Foundation

/// A complete snapshot of the Brand OS quota daemon's on-disk state, as
/// last read by `BrandOSQuotaService.refresh`. `nil` upstream (rather than
/// an instance of this type) means the feature is disabled in settings.
struct BrandOSQuotaData: Equatable, Sendable {
    /// Whether the watchdog directory could be read at all, distinct from
    /// the *contents* being present/valid — lets a future UI distinguish
    /// "daemon never installed" from "sandbox denied read access" instead
    /// of showing a generic error for both.
    enum Access: Equatable, Sendable {
        /// The watchdog directory was read successfully (individual files
        /// may still be missing/empty — that's reflected in the other
        /// fields, not here).
        case ok
        /// The directory exists but reading it failed with a permission
        /// error (sandbox denied) — the read-only entitlement may be
        /// missing or misconfigured.
        case denied
        /// The directory does not exist — the daemon has likely never run
        /// on this machine.
        case absent
    }

    /// The most recent finished (`isComplete == true`) gate-script result
    /// found in `quota-results/`, or `nil` if no complete result exists
    /// yet.
    struct LastResult: Equatable, Sendable {
        let verdict: GateVerdict
        let script: String?
        let fileKey: String?
        let at: Date?
    }

    let access: Access
    let liveness: DaemonLiveness
    let seat: DisplaySeat
    let queue: [QueueItem]
    let lastResult: LastResult?
    /// When this snapshot was assembled (wall-clock `Date()` at read time,
    /// not derived from any file's contents) — lets a future UI show
    /// "as of ...".
    let lastUpdated: Date
}
