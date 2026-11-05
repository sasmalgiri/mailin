# mailin — instructions for every coding session

## Current goal (owner decision 2026-11-05)

The next release makes the **five archive jobs** fully functional end to end: **open large archives,
preserve folders, search messages and attachments, identify duplicates safely, verify exports.** Nothing
else expands — no live mail, cloud AI, analytics, studios or personas (online 4.0 was proposed and
cancelled the same day; see `FIVE_JOBS_MASTER_PLAN.md` §3).

**The governing plan is [`FIVE_JOBS_MASTER_PLAN.md`](FIVE_JOBS_MASTER_PLAN.md) (36 IDs: OPEN/FOLD/FIND/DUP/
OUT/LIFE, stages 0–E, ten gates). The progress tracker is [`FIVE_JOBS_TRACKER.md`](FIVE_JOBS_TRACKER.md) —
read its Stage 0 table and "Order of work" before any work.** Work items in stage order, move the row's
state (`not started → in progress → implemented → verified`) and record the commit hash. "Implemented" is
not "verified": a row is verified only when its named test has run on the candidate. If the plan is wrong,
fix the tracker first and tell the owner.

**Working mode:** one item at a time, each with its failing-then-passing test, build green, commit. Stage A
items ship with their tests; no "implement everything then test" pass this time.

The 3.0 plan `SCALE_TODO_3_0.md` is history — read it for what was built and why, don't work from it.

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
