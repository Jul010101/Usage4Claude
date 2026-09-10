import XCTest
@testable import Usage4ClaudeCore

/// Tests for the pure Brand OS quota parsing/classification core
/// (feat/brandos-quota) — `BrandOSQuotaParser.swift`. Covers the three local
/// file shapes the daemon writes: the queue file, the rolling log, and
/// per-run result files, plus the derived liveness/display-seat folding that
/// enforces the "no stale-green lie" rule structurally.
final class BrandOSQuotaParserTests: XCTestCase {

    // MARK: - Fixtures

    /// Real queue sample: two `python3 reference/<script>.py <fileKey>` lines,
    /// interleaved with a comment and a blank line that must be skipped.
    private let realQueueText = """
    python3 reference/bookgate.py DtO9Vd44JB2bwMtSPPcxic
    # a comment line
    python3 reference/assetgate.py DtO9Vd44JB2bwMtSPPcxic

    """

    /// Real log sample ending in a `seat blocked` probe.
    private let realLogBlocked = """
    2026-09-09T13:41:05Z daemon start interval=900s
    2026-09-09T13:56:12Z probe: seat LIVE
    2026-09-09T14:17:47Z probe: seat blocked
    """

    /// Same shape, but the newest probe reports `seat LIVE`.
    private let realLogLive = """
    2026-09-09T13:41:05Z daemon start interval=900s
    2026-09-09T13:56:12Z probe: seat blocked
    2026-09-09T14:17:47Z probe: seat LIVE
    """

    /// Real result header for an exit=2 ("held") run — no VERDICT line needed.
    private let realResultHeld = """

    $ python3 reference/bookgate.py DtO9Vd44JB2bwMtSPPcxic
    exit=2

    ==== BOOK GATE ====
    held for manual review
    """

    // MARK: - QueueItem / parseQueue

    func testParseQueueParsesRealTwoLineSample() {
        let items = parseQueue(realQueueText)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].script, "bookgate")
        XCTAssertEqual(items[0].fileKey, "DtO9Vd44JB2bwMtSPPcxic")
        XCTAssertEqual(items[0].raw, "python3 reference/bookgate.py DtO9Vd44JB2bwMtSPPcxic")
        XCTAssertEqual(items[1].script, "assetgate")
        XCTAssertEqual(items[1].fileKey, "DtO9Vd44JB2bwMtSPPcxic")
    }

    func testParseQueueSkipsCommentAndBlankLines() {
        let items = parseQueue(realQueueText)
        // Only the two real queue lines should survive; the comment and the
        // trailing blank line must not produce QueueItems.
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items.contains { $0.raw.hasPrefix("#") })
    }

    func testParseQueueEmptyTextReturnsEmptyArray() {
        XCTAssertEqual(parseQueue(""), [])
    }

    func testParseQueueWhitespaceOnlyLinesAreSkipped() {
        let text = "   \n\t\n\n"
        XCTAssertEqual(parseQueue(text), [])
    }

    func testParseQueueLineWithoutPyFileHasNilScript() {
        let items = parseQueue("some garbage line with no python script")
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].script)
        // Last whitespace token is still captured as fileKey.
        XCTAssertEqual(items[0].fileKey, "script")
    }

    // MARK: - QuotaLogFacts / parseLog

    func testParseLogRealSampleEndingBlockedSeat() {
        let facts = parseLog(realLogBlocked)
        XCTAssertEqual(facts.lastProbeSeat, .blocked)
        XCTAssertEqual(facts.lastLineAt, isoDate("2026-09-09T14:17:47Z"))
        XCTAssertEqual(facts.lastProbeAt, isoDate("2026-09-09T14:17:47Z"))
    }

    func testParseLogVariantEndingLiveSeat() {
        let facts = parseLog(realLogLive)
        XCTAssertEqual(facts.lastProbeSeat, .live)
        XCTAssertEqual(facts.lastLineAt, isoDate("2026-09-09T14:17:47Z"))
        XCTAssertEqual(facts.lastProbeAt, isoDate("2026-09-09T14:17:47Z"))
    }

    func testParseLogEmptyTextIsUnknownWithNilTimestamps() {
        let facts = parseLog("")
        XCTAssertEqual(facts.lastProbeSeat, .unknown)
        XCTAssertNil(facts.lastLineAt)
        XCTAssertNil(facts.lastProbeAt)
    }

    func testParseLogNoProbeLineYetIsUnknownSeatButHasLastLineAt() {
        let text = "2026-09-09T13:41:05Z daemon start interval=900s"
        let facts = parseLog(text)
        XCTAssertEqual(facts.lastProbeSeat, .unknown)
        XCTAssertNil(facts.lastProbeAt)
        XCTAssertEqual(facts.lastLineAt, isoDate("2026-09-09T13:41:05Z"))
    }

    func testParseLogIgnoresGarbageAndBlankLinesStaysTotal() {
        let text = """
        not a timestamp at all

        2026-09-09T14:17:47Z probe: seat LIVE
        another garbage line !!! weird bytes \u{0000}
        """
        let facts = parseLog(text)
        XCTAssertEqual(facts.lastProbeSeat, .live)
        XCTAssertEqual(facts.lastLineAt, isoDate("2026-09-09T14:17:47Z"))
    }

    // MARK: - DaemonLiveness / classifyLiveness

    func testClassifyLivenessStaleWhenNowIsFarPastLastProbe() {
        let facts = parseLog(realLogBlocked)
        let now = isoDate("2026-09-09T14:17:47Z")!.addingTimeInterval(40 * 60)
        let liveness = classifyLiveness(facts, now: now, staleAfter: 1800)
        guard case .stale(let lastActivity) = liveness else {
            return XCTFail("expected .stale, got \(liveness)")
        }
        XCTAssertEqual(lastActivity, isoDate("2026-09-09T14:17:47Z"))
    }

    func testClassifyLivenessFreshWhenNowIsShortlyAfterLastProbe() {
        let facts = parseLog(realLogBlocked)
        let now = isoDate("2026-09-09T14:17:47Z")!.addingTimeInterval(5 * 60)
        let liveness = classifyLiveness(facts, now: now, staleAfter: 1800)
        guard case .live(let lastActivity) = liveness else {
            return XCTFail("expected .live, got \(liveness)")
        }
        XCTAssertEqual(lastActivity, isoDate("2026-09-09T14:17:47Z"))
    }

    func testClassifyLivenessUnknownWhenNoTimestampAtAll() {
        let facts = parseLog("")
        XCTAssertEqual(classifyLiveness(facts, now: Date(), staleAfter: 1800), .unknown)
    }

    func testClassifyLivenessFallsBackToLastLineAtWhenNoProbeYet() {
        let text = "2026-09-09T13:41:05Z daemon start interval=900s"
        let facts = parseLog(text)
        let now = isoDate("2026-09-09T13:41:05Z")!.addingTimeInterval(60)
        let liveness = classifyLiveness(facts, now: now, staleAfter: 1800)
        guard case .live = liveness else {
            return XCTFail("expected .live, got \(liveness)")
        }
    }

    func testClassifyLivenessClampsFutureTimestampToLive() {
        let facts = parseLog(realLogBlocked)
        // `now` is BEFORE the last probe timestamp (clock skew / future log
        // entry) — age would be negative; must clamp to fresh/live, not stale.
        let now = isoDate("2026-09-09T14:17:47Z")!.addingTimeInterval(-3600)
        let liveness = classifyLiveness(facts, now: now, staleAfter: 1800)
        guard case .live = liveness else {
            return XCTFail("expected .live for a future/negative age, got \(liveness)")
        }
    }

    // MARK: - DisplaySeat folding (no stale-green lie)

    func testDisplaySeatFoldsStaleLiveIntoStaleLastKnownNeverConfidentLive() {
        let facts = parseLog(realLogLive)
        let asOf = isoDate("2026-09-09T14:17:47Z")!
        let liveness = DaemonLiveness.stale(lastActivity: asOf)
        let seat = displaySeat(facts: facts, liveness: liveness)
        XCTAssertEqual(seat, .staleLastKnown(.live, asOf: asOf))
        XCTAssertNotEqual(seat, .live)
    }

    func testDisplaySeatFoldsStaleBlockedIntoStaleLastKnown() {
        let facts = parseLog(realLogBlocked)
        let asOf = isoDate("2026-09-09T14:17:47Z")!
        let liveness = DaemonLiveness.stale(lastActivity: asOf)
        let seat = displaySeat(facts: facts, liveness: liveness)
        XCTAssertEqual(seat, .staleLastKnown(.blocked, asOf: asOf))
    }

    func testDisplaySeatIsLiveWhenLivenessIsLiveAndSeatIsLive() {
        let facts = parseLog(realLogLive)
        let asOf = isoDate("2026-09-09T14:17:47Z")!
        let liveness = DaemonLiveness.live(lastActivity: asOf)
        XCTAssertEqual(displaySeat(facts: facts, liveness: liveness), .live)
    }

    func testDisplaySeatIsBlockedWhenLivenessIsLiveAndSeatIsBlocked() {
        let facts = parseLog(realLogBlocked)
        let asOf = isoDate("2026-09-09T14:17:47Z")!
        let liveness = DaemonLiveness.live(lastActivity: asOf)
        XCTAssertEqual(displaySeat(facts: facts, liveness: liveness), .blocked)
    }

    func testDisplaySeatIsUnknownWhenLivenessIsUnknown() {
        let facts = parseLog(realLogLive)
        XCTAssertEqual(displaySeat(facts: facts, liveness: .unknown), .unknown)
    }

    func testDisplaySeatIsUnknownWhenStaleButSeatWasNeverKnown() {
        let text = "2026-09-09T13:41:05Z daemon start interval=900s"
        let facts = parseLog(text)
        let asOf = isoDate("2026-09-09T13:41:05Z")!
        let liveness = DaemonLiveness.stale(lastActivity: asOf)
        XCTAssertEqual(displaySeat(facts: facts, liveness: liveness), .unknown)
    }

    // MARK: - ResultInfo / parseResultHeader

    func testParseResultHeaderRealExitTwoIsHeldAndComplete() {
        let info = parseResultHeader(realResultHeld)
        XCTAssertEqual(info.command, "python3 reference/bookgate.py DtO9Vd44JB2bwMtSPPcxic")
        XCTAssertEqual(info.exitCode, 2)
        XCTAssertEqual(info.verdict, .held)
        XCTAssertTrue(info.isComplete)
    }

    func testParseResultHeaderSyntheticExitZeroGreenIsComplete() {
        let text = """
        $ python3 reference/bookgate.py DtO9Vd44JB2bwMtSPPcxic
        exit=0
        VERDICT: GREEN
        """
        let info = parseResultHeader(text)
        XCTAssertEqual(info.exitCode, 0)
        XCTAssertEqual(info.verdict, .green)
        XCTAssertTrue(info.isComplete)
    }

    func testParseResultHeaderSyntheticExitOneRedIsComplete() {
        let text = """
        $ python3 reference/assetgate.py DtO9Vd44JB2bwMtSPPcxic
        exit=1
        VERDICT: RED
        """
        let info = parseResultHeader(text)
        XCTAssertEqual(info.exitCode, 1)
        XCTAssertEqual(info.verdict, .red)
        XCTAssertTrue(info.isComplete)
    }

    func testParseResultHeaderMissingExitLineIsIncompleteAndUnknown() {
        let text = "$ python3 reference/bookgate.py DtO9Vd44JB2bwMtSPPcxic"
        let info = parseResultHeader(text)
        XCTAssertEqual(info.command, "python3 reference/bookgate.py DtO9Vd44JB2bwMtSPPcxic")
        XCTAssertNil(info.exitCode)
        XCTAssertEqual(info.verdict, .unknown)
        XCTAssertFalse(info.isComplete)
    }

    func testParseResultHeaderExitZeroWithoutVerdictYetIsIncomplete() {
        // The daemon writes `exit=` before the VERDICT line; while the file
        // is still being written this must read as incomplete, not GREEN.
        let text = """
        $ python3 reference/bookgate.py DtO9Vd44JB2bwMtSPPcxic
        exit=0
        """
        let info = parseResultHeader(text)
        XCTAssertEqual(info.exitCode, 0)
        XCTAssertFalse(info.isComplete)
    }

    func testParseResultHeaderEmptyTextNeverThrowsAndIsIncomplete() {
        let info = parseResultHeader("")
        XCTAssertNil(info.command)
        XCTAssertNil(info.exitCode)
        XCTAssertEqual(info.verdict, .unknown)
        XCTAssertFalse(info.isComplete)
    }

    func testParseResultHeaderUnrecognizedExitCodeIsUnknownVerdict() {
        let text = """
        $ python3 reference/bookgate.py DtO9Vd44JB2bwMtSPPcxic
        exit=127
        """
        let info = parseResultHeader(text)
        XCTAssertEqual(info.exitCode, 127)
        XCTAssertEqual(info.verdict, .unknown)
    }

    // MARK: - Filenames

    func testIsValidResultFilenameAcceptsFixedWidthIsoSlug() {
        XCTAssertTrue(isValidResultFilename("2026-09-09T134230Z-python3-reference-bookgate-py-DtO9Vd44JB2bwMtSPPcxic.txt"))
    }

    func testIsValidResultFilenameRejectsNonMatchingName() {
        XCTAssertFalse(isValidResultFilename("not-a-result-file.txt"))
        XCTAssertFalse(isValidResultFilename(""))
    }

    func testResultTimestampKeyReturnsFilenameWhenValidNilOtherwise() {
        let name = "2026-09-09T134230Z-python3-reference-bookgate-py-DtO9Vd44JB2bwMtSPPcxic.txt"
        XCTAssertEqual(resultTimestampKey(fromFilename: name), name)
        XCTAssertNil(resultTimestampKey(fromFilename: "garbage.txt"))
    }

    func testResultFilenamesSortLexicographicallyInChronologicalOrder() {
        let earlier = "2026-09-09T134230Z-python3-reference-bookgate-py-DtO9Vd44JB2bwMtSPPcxic.txt"
        let later = "2026-09-09T140239Z-python3-reference-assetgate-py-DtO9Vd44JB2bwMtSPPcxic.txt"
        XCTAssertTrue(isValidResultFilename(earlier))
        XCTAssertTrue(isValidResultFilename(later))
        XCTAssertLessThan(earlier, later)
    }

    // MARK: - Test helper

    private func isoDate(_ s: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: s)
    }
}
