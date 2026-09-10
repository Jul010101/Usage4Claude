# Handoff — "Brand OS" quota section in Usage4Claude

**For:** the next agent working on Usage4Claude. Self-contained; you do not need the Brand OS session that produced this.
**Goal:** the owner stops running terminal commands to know whether the Brand OS pipeline is moving. The menu-bar popover shows it; a notification fires when a queued gate verdict lands.

## Why this exists

A python daemon (`quotarun.py`, running via nohup on this machine) watches the Figma MCP seat quota (a rolling window that blocks/unblocks unpredictably) and runs queued design-gate commands whenever capacity exists. It writes **plain local files**. Today the owner reads them with `tail`; that is the pain. Usage4Claude already sits in the menu bar showing Claude/Codex usage — this section makes it show Brand OS pipeline state too.

**The app only READS three artifacts. It never runs anything, never touches the network for this feature.**

## The three artifacts (all under `~/.config/opencode/skills/brand-os-figma/.watchdog/`)

1. **`quota-log`** — append-only, UTC-timestamped lines:
   ```
   2026-09-09T13:42:03Z daemon start interval=900s
   2026-09-09T13:42:08Z probe: seat LIVE
   2026-09-09T13:42:08Z RUN  python3 reference/bookgate.py DtO9Vd44JB2bwMtSPPcxic
   2026-09-09T13:42:30Z HELD exit=2 (quota died or cannot-check) -> /Users/…/quota-results/….txt
   2026-09-09T16:12:01Z probe: seat blocked
   2026-09-09T…Z DONE exit=1 -> /Users/…/quota-results/….txt
   ```
   Seat status = last `probe:` line (`seat LIVE` / `seat blocked`). Daemon liveness = last line age < ~20 min (interval is 900s) — stale log ⇒ show "daemon stopped".
2. **`quota-queue`** — one shell command per line, `#` comments allowed; empty/missing file = queue drained (all work done).
3. **`quota-results/`** — one `.txt` per finished/held run, named `<UTC-ts>-<slug>.txt`, first line `$ <cmd>`, second `exit=<code>`, then full gate output containing a `VERDICT: GREEN` or `VERDICT: RED` line (exit 0=GREEN, 1=RED, 2=held/cannot-check).

## What to build

### A. Popover section (SwiftUI)
`Views/Components/BrandOSQuotaSection.swift` — small section following `CodexColumnView`'s style, inserted into `UsageDetailView`'s composition, hidden entirely when the feature toggle is off or the skill dir doesn't exist:
- **Seat row:** 🟢 "Figma seat live" / 🔴 "Figma seat blocked" / ⚪ "daemon stopped" (stale log)
- **Queue row:** "Queue: 2" with the short names of pending commands (parse the script name + file key from each line, e.g. "bookgate · DtO9Vd4…")
- **Last verdict row:** from newest `quota-results/*.txt`: "bookgate — GREEN ✓" (green) / "RED, 15 failures" (red) / "held — retrying" (gray). Reuse `UsageColorScheme` semantics.
- Use `L.xxx` localization accessors — add every new key to ALL 7 `Resources/*.lproj/Localizable.strings` (CI: `python3 scripts/check_l10n.py`).

### B. Data layer
- `Helpers/BrandOSQuotaParser.swift` — **pure functions** (parse log lines → seat state + last activity date; parse queue text → [String]; parse a result file header → (cmd, exit, verdict)). Add this file to `Package.swift` `sources` allowlist (mandatory — SwiftPM tests only see allowlisted files).
- `Services/BrandOSQuotaService.swift` — `@MainActor final class`, FileManager reads of the three paths, returns a `BrandOSQuotaData` model. Follow `CodexAccountUsageFetcher` conventions (typed errors, `Logger` category — add `Logger.brandOS` in `Helpers/LoggerExtension.swift`).
- Plumbing: `@Published var brandOSQuota: BrandOSQuotaData?` on `DataRefreshManager`; refresh **piggybacks on the existing `mainRefresh` tick and on `refreshOnPopoverOpen()`** (file reads are free — no new timer needed); mirror through `MenuBarManager.setupDataBindings()` into `UsageDetailView` like the existing bindings.

### C. Notification (the actual point)
When a result file with exit 0/1 appears that wasn't there on the previous tick → post a macOS user notification: "Brand OS: bookgate GREEN — roast-ready" / "bookgate RED (15 failures)". Track last-seen result filename in UserDefaults. Respect the feature toggle.

### D. Settings
`UserSettings.shared` toggle per house pattern (`@Published var brandOSQuotaEnabled` + `didSet` → defaults + `.settingsChanged` post + `init()` load + `resetToDefaults()`), default **false** (opt-in). UI: a `SettingCard` in `Views/Settings/Tabs/GeneralSettingsDisplaySection.swift` with `Toggle(...).toggleStyle(.checkbox).focusable(false)`.

### E. Sandbox — decide-first, it blocks everything
App Sandbox is ON; entitlements (`Config/Usage4Claude.entitlements`) have NO file access — the app cannot read `~/.config/...` today. Decision (already made, implement it): **add `com.apple.security.temporary-exception.files.home-relative-path.read-only` with `/.config/opencode/skills/brand-os-figma/.watchdog/`** — the app is distributed via Sparkle DMG (not App Store), so a temporary-exception is acceptable. Keep it read-only and as narrow as that directory. If notarization complains in practice, fall back to the security-scoped-bookmark flow (NSOpenPanel grant in settings) — but try the exception first.

## Tests
XCTest in `Tests/Usage4ClaudeCoreTests/` (`@testable import Usage4ClaudeCore`), one file: `BrandOSQuotaParserTests.swift` — feed verbatim samples from this document (log with LIVE/blocked/stale, queue with comments/empty, result headers exit 0/1/2) and assert states. Only the pure parser is testable (services aren't in the SwiftPM target — consistent with the codebase).

## Build & verify
```bash
cd "/Users/julieng/Projects Dev/usage4claude"
swift test                          # parser tests
python3 scripts/check_l10n.py       # l10n completeness (CI-enforced)
./scripts/build.sh --config Debug   # full app build
```
Manual check: run the built app while `quotarun.py` daemon is up (check: `pgrep -f quotarun.py`); the section should show live state within one refresh tick.

## Conventions that will get your PR bounced (from CLAUDE.md)
English commits, no emoji, no Co-Authored-By; CHANGELOG.md is the version source; user-facing strings only via `L.xxx` in all 7 languages; main-thread delivery for service callbacks; no new root-level .md files; reuse `TimerManager`/`Logger`/`UsageColorScheme` — no raw Timers, prints, or ad-hoc colors.

## Out of scope
Do NOT touch the Brand OS skill (`~/.config/opencode/skills/brand-os-figma/`) — the daemon, its file formats, and its queue are owned by the Brand OS session. If a format seems wrong, flag it in the Multica issue instead of changing the daemon. Format changes must be coordinated (the parser + daemon move together).

## Acceptance
- [ ] Toggle off (default): zero UI change, zero file reads
- [ ] Toggle on: seat/queue/verdict rows render with real daemon data
- [ ] Notification fires exactly once per new finished result
- [ ] Daemon stopped ⇒ ⚪ state (no crash, no stale-green lie)
- [ ] `swift test` + `check_l10n.py` + Debug build all pass
- [ ] Entitlement added, read-only, narrow
