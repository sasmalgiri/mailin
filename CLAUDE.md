# mailin — instructions for every coding session

## Current goal (owner decision 2026-10-10)

Ship **3.0** so it needs no structural revision for a long time: every tool works on the **whole archive at
any size**, memory stays flat, work survives interruptions, legal results are provable, nothing claims more
than it did.

**The plan and progress tracker is [`SCALE_TODO_3_0.md`](SCALE_TODO_3_0.md). Read its §0–§2 and §4 before
any work.** Work the first unchecked item in §4 order, to its "done means", then tick it there with the
commit hash. Do not start a later step while an earlier gate is red. If the plan is wrong, fix the plan
first and tell the owner.

**Working mode (owner, 2026-10-10): implement the whole plan first behind OFF switches, keeping it compiling;
then one full test-and-fix pass.** Don't run test suites per item during the implementation pass.

## Rules that are never broken

1. Never destroy old data in 3.0 — migrations copy, verify one-for-one, keep old files read-only.
2. Snapshot the archive before every schema migration.
3. Never renumber Bates numbers.
4. Every whole-archive action shows the affected count before it runs.
5. Audit entries / numbered documents only after the action really happened; saves report
   saved / shared / cancelled / failed via `PlatformExport` / `ExportOutcome`; partial work says "X of Y".
6. No hidden caps: stream in batches; never `workingSet(cap:)` or `if acc.count >= N { break }`.
   Real limits are stated on screen.
7. Offline-first: nothing leaves the device unless an online toggle is on (Private Cloud Compute,
   RFC 3161 time-stamping, Spotlight PCC mode are online features, off by default).
8. Counts in code, the AI model only narrates (on-device model reads 4,096 tokens per session).
9. Fewest clicks; progress visible; jobs resume by themselves.
10. Every new user-facing string translated into all 10 languages before a step is done
    (`~/mailin-loc-work/keys-*.py`; catalog written with `json.dumps(indent=2, separators=(',', ' : '))`,
    no `sort_keys`).
11. Every change ships with a test that fails without it; zero new warnings; suite green before commit.
12. Never edit `maxmailin.xcodeproj/project.pbxproj` by hand while Xcode is open.
13. Commit after each step; branch `v3-architecture`.
14. Old code is switched off, never ripped out, in 3.0: every rebuilt engine/tool is a new capability in
    `Capability.swift` next to the untouched old path (bug fixes only); new code in new files; one dispatch
    seam per tool. More code is accepted for a rollback switch on everything.
15. New engines default OFF (`maturity: .preview`) until their gate passes; a crash while one runs trips it
    off on next launch (plan §3-M2).
16. Both engines see the same data for the whole of 3.0 (dual-write or read adapter) — switching back loses nothing.

## Project facts

- App target `maxmailin` (Xcode project `maxmailin.xcodeproj`), package `Packages/ArchiveCore`
  (SQLite store, export service). Tests: `maxmailinTests` (XCTest + Swift Testing), `maxmailinUITests`.
- Prefer Xcode MCP tools: `BuildProject`, `RunSomeTests`, `RunAllTests`, `XcodeRefreshCodeIssuesInFile`,
  `DocumentationSearch` (Apple docs — use it for any API newer than your training).
- Mac UI tests need the owner present to approve automation ("Timed out while enabling automation mode").
- Reference implementations of the right pattern: File/Export menu exports (`runStreamingExport`),
  Redact & Export, `PlatformExport.save`, `csvRow`.
- Audit history: `BUTTON_AUDIT_3_0.md` (all 1,083 buttons, 2026-10-09).
