//
//  BrandOSQuotaService.swift
//  Usage4Claude
//
//  Created by Claude Code on 2026-09-09.
//  Copyright © 2025 f-is-h. All rights reserved.
//
//  Brand OS quota feature (feat/brandos-quota), Phase B service layer. Reads
//  the daemon's three watchdog artifacts (quota-log, quota-queue,
//  quota-results/) off the main thread, feeds them through the pure parsing
//  core in `Helpers/BrandOSQuotaParser.swift`, and delivers a
//  `BrandOSQuotaData?` back on the main thread — mirroring this codebase's
//  "service completions always call back on main" convention (see
//  `CLAUDE.md`). Also owns the "notify exactly once per newly-finished gate
//  result" contract via a UserDefaults-persisted marker.
//

import Foundation
import OSLog

@MainActor
final class BrandOSQuotaService {
    private static let watchdogRelativePath = "/.config/opencode/skills/brand-os-figma/.watchdog"
    private static let lastProcessedResultDefaultsKey = "brandOSLastProcessedResult"
    /// Only the tail of quota-log is ever needed (latest probe line); this
    /// caps the read regardless of how large the daemon's log has grown.
    private static let logTailReadSize = 32 * 1024
    /// More than this many new fireable results in one refresh get
    /// coalesced into a single summary notification instead of one each.
    private static let summaryCoalesceThreshold = 5

    private let defaults = UserDefaults.standard
    private var isScanning = false

    // MARK: - Public API

    /// Reads the watchdog directory (off-main) and delivers a snapshot on
    /// the main thread. `enabled == false` short-circuits to `nil` with no
    /// I/O at all. Overlapping calls while a scan is already in flight are
    /// dropped (the in-flight scan's own completion still fires normally).
    func refresh(enabled: Bool, notificationsEnabled: Bool, completion: @escaping (BrandOSQuotaData?) -> Void) {
        guard enabled else {
            completion(nil)
            return
        }
        guard !isScanning else {
            Logger.brandOS.debug("Brand OS refresh 已在进行中，跳过本次重叠调用")
            return
        }
        isScanning = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = Self.readSnapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                completion(self.buildData(from: snapshot, notificationsEnabled: notificationsEnabled))
            }
        }
    }

    // MARK: - Off-main I/O

    /// Everything a `RawSnapshot` needs, gathered by pure file I/O with no
    /// `@MainActor` isolation and no UserDefaults access — the notify-walk
    /// marker read/write happens back on the main actor in
    /// `processNotifyWalk`.
    private struct RawSnapshot {
        let access: BrandOSQuotaData.Access
        let facts: QuotaLogFacts
        let queue: [QueueItem]
        /// All validly-named result files, ascending, each with its parsed
        /// header (which may be incomplete — the daemon could still be
        /// writing the newest one).
        let results: [(filename: String, info: ResultInfo)]
    }

    /// Resolves the *real* home directory via the same `getpwuid()` route
    /// the daemon uses to write these files — never `NSHomeDirectory()`/
    /// `FileManager.homeDirectoryForCurrentUser`, both of which return the
    /// app's sandbox container path instead.
    private nonisolated static func realHomeDirectory() -> String? {
        guard let passwd = getpwuid(getuid()) else { return nil }
        return String(cString: passwd.pointee.pw_dir)
    }

    private nonisolated static func watchdogDirectoryURL() -> URL? {
        guard let home = realHomeDirectory() else { return nil }
        return URL(fileURLWithPath: home + watchdogRelativePath, isDirectory: true)
    }

    /// Distinguishes "directory missing" from "sandbox denied" using the
    /// syscall's own `errno` immediately after the call, rather than
    /// re-interpreting a translated `NSError` (whose domain/code mapping
    /// for sandbox denials is not reliably documented).
    private nonisolated static func checkDirectoryAccess(path: String) -> BrandOSQuotaData.Access {
        if let dir = opendir(path) {
            closedir(dir)
            return .ok
        }
        switch errno {
        case ENOENT:
            return .absent
        case EACCES, EPERM:
            return .denied
        default:
            return .denied
        }
    }

    private nonisolated static func readSnapshot() -> RawSnapshot {
        let emptyFacts = QuotaLogFacts(lastLineAt: nil, lastProbeAt: nil, lastProbeSeat: .unknown)

        guard let dirURL = watchdogDirectoryURL() else {
            return RawSnapshot(access: .denied, facts: emptyFacts, queue: [], results: [])
        }

        let access = checkDirectoryAccess(path: dirURL.path)
        guard access == .ok else {
            Logger.brandOS.info("watchdog 目录不可读: \(String(describing: access), privacy: .public)")
            return RawSnapshot(access: access, facts: emptyFacts, queue: [], results: [])
        }

        let facts = parseLog(tailReadUTF8(fileURL: dirURL.appendingPathComponent("quota-log"), maxBytes: logTailReadSize))
        let queue = readQueue(dirURL: dirURL)
        let results = readResults(dirURL: dirURL)

        return RawSnapshot(access: .ok, facts: facts, queue: queue, results: results)
    }

    /// Reads at most the last `maxBytes` of `fileURL` as UTF-8, dropping a
    /// possibly-partial first line when the read didn't start at byte 0.
    /// Never throws: any I/O or decode failure yields `""`.
    private nonisolated static func tailReadUTF8(fileURL: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return "" }
        defer { try? handle.close() }
        guard let endOffset = try? handle.seekToEnd() else { return "" }

        let readSize = min(UInt64(maxBytes), endOffset)
        let startOffset = endOffset - readSize
        guard (try? handle.seek(toOffset: startOffset)) != nil else { return "" }
        guard let data = try? handle.read(upToCount: Int(readSize)) else { return "" }

        var text = String(decoding: data, as: UTF8.self)
        if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text
    }

    private nonisolated static func readQueue(dirURL: URL) -> [QueueItem] {
        let queueURL = dirURL.appendingPathComponent("quota-queue")
        guard let text = try? String(contentsOf: queueURL, encoding: .utf8) else { return [] }
        return parseQueue(text)
    }

    private nonisolated static func readResults(dirURL: URL) -> [(filename: String, info: ResultInfo)] {
        let resultsDirURL = dirURL.appendingPathComponent("quota-results", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: resultsDirURL.path) else {
            return []
        }
        return names
            .filter { isValidResultFilename($0) }
            .sorted()
            .compactMap { name -> (filename: String, info: ResultInfo)? in
                let fileURL = resultsDirURL.appendingPathComponent(name)
                guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
                return (filename: name, info: parseResultHeader(text))
            }
    }

    /// Result filenames are fixed-width `yyyy-MM-ddTHHmmssZ-<slug>.txt`
    /// (see `BrandOSQuotaParser.isValidResultFilename`); the leading 19
    /// characters are always the timestamp. Never throws.
    private nonisolated static func timestamp(fromResultFilename name: String) -> Date? {
        guard name.count >= 19 else { return nil }
        return resultFilenameTimestampFormatter.date(from: String(name.prefix(19)))
    }

    private nonisolated static let resultFilenameTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Main-actor assembly

    private func buildData(from snapshot: RawSnapshot, notificationsEnabled: Bool) -> BrandOSQuotaData {
        let now = Date()

        guard snapshot.access == .ok else {
            return BrandOSQuotaData(access: snapshot.access, liveness: .unknown, seat: .unknown, queue: [], lastResult: nil, lastUpdated: now)
        }

        let liveness = classifyLiveness(snapshot.facts, now: now)
        let seat = displaySeat(facts: snapshot.facts, liveness: liveness)

        processNotifyWalk(results: snapshot.results, notificationsEnabled: notificationsEnabled)

        let lastResult = snapshot.results.last(where: { $0.info.isComplete }).map { entry -> BrandOSQuotaData.LastResult in
            let parsed = Self.scriptAndFileKey(fromCommand: entry.info.command)
            return BrandOSQuotaData.LastResult(
                verdict: entry.info.verdict,
                script: parsed.script,
                fileKey: parsed.fileKey,
                at: Self.timestamp(fromResultFilename: entry.filename)
            )
        }

        return BrandOSQuotaData(access: .ok, liveness: liveness, seat: seat, queue: snapshot.queue, lastResult: lastResult, lastUpdated: now)
    }

    /// A result's parsed `command` (e.g. `python3 bookgate.py <fileKey>`)
    /// has the exact same shape as a queue line, so this reuses
    /// `parseQueue`'s existing tokenization instead of duplicating it.
    private nonisolated static func scriptAndFileKey(fromCommand command: String?) -> (script: String?, fileKey: String?) {
        guard let item = parseQueue(command ?? "").first else { return (nil, nil) }
        return (item.script, item.fileKey)
    }

    /// Implements the "notify exactly once per newly-finished gate result"
    /// contract. On first run (`marker == nil`) it seeds the marker to the
    /// newest complete result and fires nothing, so a fresh install never
    /// floods historic results as new notifications. Otherwise it walks
    /// ascending through results newer than the marker, firing for
    /// green/red verdicts (coalesced into one summary above the threshold)
    /// and advancing silently past held/unknown ones, but always halts at
    /// the first *incomplete* file without advancing past it — the daemon
    /// may still be writing it.
    private func processNotifyWalk(results: [(filename: String, info: ResultInfo)], notificationsEnabled: Bool) {
        guard let marker = defaults.string(forKey: Self.lastProcessedResultDefaultsKey) else {
            if let newest = results.last(where: { $0.info.isComplete }) {
                defaults.set(newest.filename, forKey: Self.lastProcessedResultDefaultsKey)
                Logger.brandOS.info("Brand OS: 首次启用，标记初始化为最新结果（不发送通知）")
            }
            return
        }

        var processedComplete: [(filename: String, info: ResultInfo)] = []
        for entry in results where entry.filename > marker {
            guard entry.info.isComplete else { break }
            processedComplete.append(entry)
        }
        guard let newest = processedComplete.last else { return }

        let fireable = processedComplete.filter { $0.info.verdict == .green || $0.info.verdict == .red }

        if notificationsEnabled {
            if fireable.count > Self.summaryCoalesceThreshold {
                NotificationManager.shared.sendBrandOSSummaryNotification(count: fireable.count, resultFilename: newest.filename)
            } else {
                for entry in fireable {
                    let script = Self.scriptAndFileKey(fromCommand: entry.info.command).script
                    NotificationManager.shared.sendBrandOSGateFinishedNotification(script: script, verdict: entry.info.verdict, resultFilename: entry.filename)
                }
            }
        }

        defaults.set(newest.filename, forKey: Self.lastProcessedResultDefaultsKey)
    }
}
