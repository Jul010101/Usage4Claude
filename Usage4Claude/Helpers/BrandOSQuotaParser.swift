//
//  BrandOSQuotaParser.swift
//  Usage4Claude
//
//  Pure, total parsing/classification core for the Brand OS quota feature
//  (feat/brandos-quota). Zero dependency on SwiftUI/AppKit/Logger/`L.*`
//  localization so it can live in the SwiftPM `Usage4ClaudeCore` test target
//  alongside `AccountAvailability.swift`/`AccountUsageStatus.swift`.
//
//  This is the read-only ingestion core for three local files a daemon
//  writes: a queue file (pending Figma/Brand-OS gate scripts), a rolling log
//  (periodic "seat" probes every 900s), and per-run result files (one gate
//  script's stdout/exit code). Everything here is a pure function of its
//  inputs — no file I/O, no `Date()` calls, no throwing, no force-unwraps.
//  Callers (a future `@MainActor` service, Phase B) own all I/O and inject
//  `now` for deterministic, testable liveness classification.
//

import Foundation

// MARK: - Seat status

/// The Figma/Brand-OS seat's state as last reported by a probe line in the
/// rolling log.
enum SeatStatus: Equatable, Sendable {
    case live
    case blocked
    case unknown
}

// MARK: - Gate verdict

/// The outcome of a single gate script run, derived from its exit code (and,
/// for exit codes 0/1, a corroborating `VERDICT:` token in the result body).
enum GateVerdict: Equatable, Sendable {
    case green
    case red
    case held
    case unknown
}

// MARK: - Queue

/// A single parsed line from the pending-gate-scripts queue file.
struct QueueItem: Equatable, Sendable {
    /// The original, unmodified queue line (never empty/whitespace-only —
    /// those lines are skipped before a `QueueItem` is ever created).
    let raw: String
    /// The gate script's basename with the `.py` extension stripped (e.g.
    /// `bookgate`), or `nil` if the line doesn't reference a `.py` file.
    let script: String?
    /// The last whitespace-separated token on the line — the file key the
    /// gate script operates on.
    let fileKey: String?
}

/// Parses a queue file's text into an ordered list of `QueueItem`s. Lines
/// that are empty, whitespace-only, or start with `#` (comments) are
/// skipped entirely. Never throws; missing/empty input yields `[]`.
func parseQueue(_ text: String) -> [QueueItem] {
    var items: [QueueItem] = []
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let fileKey = tokens.last
        let script = tokens
            .first(where: { $0.hasSuffix(".py") })
            .map { token -> String in
                let base = (token as NSString).lastPathComponent
                if base.hasSuffix(".py") {
                    return String(base.dropLast(3))
                }
                return base
            }

        items.append(QueueItem(raw: trimmed, script: script, fileKey: fileKey))
    }
    return items
}

// MARK: - Log facts

/// Facts extracted from the rolling probe log by a single linear scan.
struct QuotaLogFacts: Equatable, Sendable {
    /// The latest (max) timestamp parsed from any line in the log, or `nil`
    /// if no line carried a parseable leading ISO-8601 timestamp.
    let lastLineAt: Date?
    /// The timestamp of the newest `probe:` line, or `nil` if the log
    /// contains no probe line yet.
    let lastProbeAt: Date?
    /// The seat status reported by the newest `probe:` line, or `.unknown`
    /// if there is no probe line yet.
    let lastProbeSeat: SeatStatus
}

private let brandOSLogTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

/// Parses a leading `<ISO-8601 UTC timestamp> ...` from a single log line.
/// Returns `nil` for lines with no parseable leading timestamp — never
/// throws, never crashes on garbage.
private func leadingTimestamp(in line: String) -> Date? {
    guard let firstSpace = line.firstIndex(of: " ") else {
        return brandOSLogTimestampFormatter.date(from: line)
    }
    let candidate = String(line[line.startIndex..<firstSpace])
    return brandOSLogTimestampFormatter.date(from: candidate)
}

/// Parses the rolling probe log's text into `QuotaLogFacts` via a single
/// linear scan. Unparseable/garbage/blank lines are ignored — this function
/// never throws and always returns a (possibly all-`nil`/`.unknown`) result.
func parseLog(_ text: String) -> QuotaLogFacts {
    var lastLineAt: Date?
    var lastProbeAt: Date?
    var lastProbeSeat: SeatStatus = .unknown

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { continue }
        guard let timestamp = leadingTimestamp(in: line) else { continue }

        if lastLineAt == nil || timestamp > lastLineAt! {
            lastLineAt = timestamp
        }

        guard let probeRange = line.range(of: "probe:") else { continue }
        // Only treat this as a "newer" probe if its timestamp is at least as
        // new as the one we already have — the log is expected append-only,
        // but this keeps the scan order-independent and defensive.
        if lastProbeAt == nil || timestamp >= lastProbeAt! {
            lastProbeAt = timestamp
            let probeBody = line[probeRange.upperBound...]
            if probeBody.range(of: "seat LIVE") != nil {
                lastProbeSeat = .live
            } else if probeBody.range(of: "seat blocked") != nil {
                lastProbeSeat = .blocked
            } else {
                lastProbeSeat = .unknown
            }
        }
    }

    return QuotaLogFacts(lastLineAt: lastLineAt, lastProbeAt: lastProbeAt, lastProbeSeat: lastProbeSeat)
}

// MARK: - Daemon liveness

/// Whether the daemon writing the rolling log appears to still be running,
/// derived purely from `QuotaLogFacts` and an injected `now`/threshold.
enum DaemonLiveness: Equatable, Sendable {
    case live(lastActivity: Date)
    case stale(lastActivity: Date)
    case unknown
}

/// Default staleness threshold: 2x the daemon's 900s probe interval.
let brandOSDefaultStaleAfter: TimeInterval = 1800

/// Classifies daemon liveness from `facts` at a given `now`, using
/// `staleAfter` as the maximum tolerated age before the daemon is considered
/// stale. Age is computed from `lastProbeAt` when present, else
/// `lastLineAt`; a future timestamp (or otherwise negative age) is clamped
/// to zero so it always reads as fresh/live rather than stale. No timestamp
/// at all yields `.unknown`.
func classifyLiveness(_ facts: QuotaLogFacts, now: Date, staleAfter: TimeInterval = brandOSDefaultStaleAfter) -> DaemonLiveness {
    guard let anchor = facts.lastProbeAt ?? facts.lastLineAt else { return .unknown }
    let age = max(0, now.timeIntervalSince(anchor))
    return age > staleAfter ? .stale(lastActivity: anchor) : .live(lastActivity: anchor)
}

// MARK: - Display seat

/// The seat status as it should be *displayed*, folding daemon liveness into
/// the raw `SeatStatus` so a stale daemon's last-known `.live`/`.blocked`
/// reading is never rendered as a confident current state. This is the
/// structural enforcement of the "no stale-green lie" rule: callers must use
/// this type (not `SeatStatus` directly) for any user-facing seat display.
enum DisplaySeat: Equatable, Sendable {
    case live
    case blocked
    /// The daemon is stale; `asOf` carries the last-known-good probe/log
    /// timestamp so the UI can show "as of <time>" rather than a live state.
    case staleLastKnown(SeatStatus, asOf: Date)
    case unknown
}

/// Derives the display-safe seat from raw log facts plus a pre-computed
/// `DaemonLiveness`. When `liveness` is `.stale`, a known `.live`/`.blocked`
/// seat is downgraded to `.staleLastKnown` — never a confident `.live`. When
/// `liveness` is `.unknown`, the result is always `.unknown`.
func displaySeat(facts: QuotaLogFacts, liveness: DaemonLiveness) -> DisplaySeat {
    switch liveness {
    case .unknown:
        return .unknown
    case .live:
        switch facts.lastProbeSeat {
        case .live: return .live
        case .blocked: return .blocked
        case .unknown: return .unknown
        }
    case .stale(let lastActivity):
        switch facts.lastProbeSeat {
        case .live: return .staleLastKnown(.live, asOf: lastActivity)
        case .blocked: return .staleLastKnown(.blocked, asOf: lastActivity)
        case .unknown: return .unknown
        }
    }
}

// MARK: - Result header

/// Parsed facts from a single gate-script result file's header/body.
struct ResultInfo: Equatable, Sendable {
    /// The command line that was run, with the leading `$ ` stripped, or
    /// `nil` if the body has no recognizable `$ <cmd>` first line.
    let command: String?
    /// The exit code parsed from an `exit=<int>` line, or `nil` if none was
    /// found yet (the result file is likely still being written).
    let exitCode: Int?
    /// The gate verdict derived from `exitCode` (and, for 0/1, a `VERDICT:`
    /// token in the body).
    let verdict: GateVerdict
    /// `true` only once the result file carries enough information to be
    /// considered a finished run (see `parseResultHeader` for the exact
    /// rule) — `false` while the daemon is still writing it.
    let isComplete: Bool
}

/// Maps a gate script's exit code to a `GateVerdict`: 0 -> green, 1 -> red,
/// 2 -> held, anything else -> unknown.
private func verdict(forExitCode exitCode: Int) -> GateVerdict {
    switch exitCode {
    case 0: return .green
    case 1: return .red
    case 2: return .held
    default: return .unknown
    }
}

/// Parses a gate-script result file's body into `ResultInfo`. Never throws
/// and never crashes on malformed/partial/empty input:
/// - The first non-empty line, if it starts with `$ `, becomes `command`
///   (with the `$ ` prefix stripped).
/// - The first line matching `exit=<int>` sets `exitCode`.
/// - `isComplete` is `true` only when an `exit=` line is present AND either
///   the exit code is `2` (held; no `VERDICT:` needed) or a
///   `VERDICT: GREEN`/`VERDICT: RED` token is present in the body (for exit
///   codes 0/1). Missing `exit=` always yields `isComplete == false` and
///   `verdict == .unknown`.
func parseResultHeader(_ text: String) -> ResultInfo {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    var command: String?
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        if trimmed.hasPrefix("$ ") {
            command = String(trimmed.dropFirst(2))
        }
        break
    }

    var exitCode: Int?
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("exit=") else { continue }
        let digits = trimmed.dropFirst("exit=".count)
        if let parsed = Int(digits) {
            exitCode = parsed
        }
        break
    }

    guard let exitCode else {
        return ResultInfo(command: command, exitCode: nil, verdict: .unknown, isComplete: false)
    }

    let derivedVerdict = verdict(forExitCode: exitCode)
    let hasVerdictToken = text.range(of: "VERDICT: GREEN") != nil || text.range(of: "VERDICT: RED") != nil

    let isComplete: Bool
    switch exitCode {
    case 2:
        isComplete = true
    case 0, 1:
        isComplete = hasVerdictToken
    default:
        isComplete = false
    }

    return ResultInfo(
        command: command,
        exitCode: exitCode,
        verdict: derivedVerdict,
        isComplete: isComplete
    )
}

// MARK: - Result filenames

/// Result filenames are fixed-width ISO-8601 (`yyyy-MM-ddTHHmmssZ`) followed
/// by a `-`-joined slug and a `.txt` extension, e.g.
/// `2026-09-09T134230Z-python3-reference-bookgate-py-DtO9Vd44JB2bwMtSPPcxic.txt`.
/// Fixed width + leading timestamp means lexicographic sort == chronological
/// sort, so callers never need to actually parse the timestamp to order
/// results.
private let resultFilenamePattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z-[A-Za-z0-9._-]+\\.txt$"

/// Whether `name` matches the daemon's fixed-width `<ISO-ts>-<slug>.txt`
/// result filename shape. Never throws.
func isValidResultFilename(_ name: String) -> Bool {
    guard !name.isEmpty else { return false }
    return name.range(of: resultFilenamePattern, options: .regularExpression) != nil
}

/// Returns `name` itself as the sortable ordering key when it's a valid
/// result filename, or `nil` otherwise — callers can then sort result
/// filenames lexicographically to get chronological order.
func resultTimestampKey(fromFilename name: String) -> String? {
    isValidResultFilename(name) ? name : nil
}
