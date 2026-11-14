# Button audit — does each button do what its name says? (3.0, 2026-10-09)

Trigger: Work Center ▸ Reports "Build report" only showed a table (fixed in a8e8758).

## Coverage

- Every `Button` in `maxmailin/*.swift` was extracted by script (label + action body): **1,083**.
  438 are trivial (Done/Cancel/close, open a sheet, set a selection) and were classified automatically;
  the other **645 action bodies were all read**, and the helper each one calls was opened where
  the outcome depended on it. Menu items, context menus, swipe actions and keyboard-shortcut
  commands are `Button`s, so they are included.
- Also checked: all 6 `onTapGesture` actions (selection/expansion only) and every "Auto-…" toggle
  (each is read by the feature it names).
- Not done: clicking through the running app. Findings are from reading the code.

Judged on: (a) the result matches the name, (b) failures are visible, (c) no hidden cap,
(d) a numbered document / audit entry is written only when the thing actually happened,
(e) it works on every platform where the button is shown, (f) the work survives closing the window.

## P0 — wrong legal or forensic outcome

| # | Button | Where | Problem |
|---|---|---|---|
| 1 | Every tool hosted by `ArchiveWorkingSetView` (~70: E-Discovery, Bates, Chain of Custody, Custodians, GDPR/DSAR, Automation Rules, Anomalies, Smart Alerts, Review Batches, IOC, IT Admin, Legal Review, Journalist…) | `ArchiveWorkingSetView.swift:22` (`defaultCap = 2_000`) | Tools get the **newest 2,000 emails** of the scope; no tool says so. "Apply legal hold to **all** emails", "Run search across all emails", "Assign Bates to all N emails", production load files, and a GDPR data-subject report (which must find *all* of the person's data) silently skip older mail. |
| 2 | Integrity verification: E-Discovery ▸ Verify & Seal Collection; Chain of Custody ▸ Verify | `EDiscoveryWorkflowView.swift:1313`, `ChainOfCustodyManager.swift:100` | Stored seals are only loaded for the visible list page. For every other email the tool computes the *current* hash, keeps it in memory (the stored original is untouched), then compares current vs current — **a tampered email passes**, and already-sealed emails are counted as "newly sealed". The menu's "Verify All Email Integrity" (`ArchiveExportService+Professional.swift:97`) has the same gap but reports such emails as "unverified" rather than passed. Fix: load stored seals per batch (`prefetchForensicWindow`) before verifying. |
| 3 | Legal Review workspace — all privilege calls | `LegalReviewWorkspaceView.swift:95-108` | Privilege designations, issue tags, custom issue tags, notes and the workspace "audit trail" are screen memory only: **lost when the window closes**, and never reach the app's evidence tags, so the app Privilege Log and Case Bundle ignore them. |
| 4 | Legal Review ▸ Generate PDF (Privilege Review Report) | `LegalReviewWorkspaceView.swift:1165` | The PDF is the generic investigation report — it contains **no privilege calls**. With nothing coded it silently includes every email. iOS: does nothing. No confirmation, no document; author hard-coded "Legal Reviewer". |
| 5 | E-Discovery ▸ Run NLP Analysis | `EDiscoveryWorkflowView.swift:1027` | **Runs nothing.** Writes "NLP analysis executed on N emails" to the audit trail and shows "complete". (The preview above it re-classifies up to 2,000 emails on every redraw.) |
| 6 | E-Discovery ▸ Generate Load File / Export / Privilege Log | `EDiscoveryWorkflowView.swift:1168-1212` | Save result discarded: cancelling still logs "Load File Generated" and shows success. iOS saves nothing but reports success. No document. |
| 7 | Batch Operations ▸ Export Selected | `BatchOperationsView.swift:562`, callers `ContentView.swift:1046`, `ContentView+Modifiers.swift:410` | Ignores the **selection and the chosen format** — opens the generic "export current filter" flow — yet logs "Exported N email(s) as FORMAT" and posts an export document before anything is exported. Progress bar is fake. |
| 8 | Journalist ▸ Generate PDF | `JournalistInvestigationView.swift:1568` | Sheet promises "N leads, N key quotes"; neither is passed to the generator. iOS: does nothing. No confirmation, no document; author hard-coded "Journalist". |

## P1 — false success, lost work, or silent loss

| # | Button | Where | Problem |
|---|---|---|---|
| 9 | Journalist — leads, key quotes, bookmarks | `JournalistInvestigationView.swift:16-21` | Screen memory only — lost on close. Export (`:1832`) does nothing on iOS and gives no confirmation. |
| 10 | Duplicates ▸ Remove All | `DuplicateManagerView.swift:389` | Posts "Removed N duplicates" **before** removing and ignores the result. |
| 11 | Near-Duplicates ▸ Remove All Duplicates (trash icon) | `NearDuplicateDetectionView.swift:275` | Only hides the group from the list; nothing is removed. |
| 12 | E-Discovery ▸ Create Review Batches | `EDiscoveryWorkflowView.swift:1330` | Produces a category count list + privilege scan; **no review batches** are created. |
| 13 | Legal Review ▸ Export (privilege log); IT Admin ▸ Export CSV | `LegalReviewWorkspaceView.swift:2087`, `ITAdminAnalysisView.swift:1891` | Hand-built CSV: the `Date` header ("Mon, 12 Aug…") is unquoted, so **columns shift on every row**; commas in names/subjects are rewritten to ";" (alters the text). iOS: nothing. No confirmation. |
| 14 | Audit Trail ▸ Daily Report | `AuditTrailView.swift:391` | Posts an RPT number with **no content** — the report only goes to the clipboard. |
| 15 | IOC ▸ Export CSV | `IOCExtractorView.swift:324` | Posts an "export" document before the save panel; cancelling leaves a record of an export that never happened. macOS write is silent on failure. |
| 16 | Triage ▸ Export IOC Blocklist | `TriageQueueView.swift:265` | iOS writes a temp file and never shows Share (does nothing). Source silently capped at 2,000 confirmed emails. |
| 17 | Chain of Custody ▸ Export Audit Trail / Export PDF Report | `ChainOfCustodyManager.swift:530,562` | macOS: silent on failure, and **unsigned** (iOS adds a `.sig`). |
| 18 | E-Discovery ▸ Export Summary | `EDiscoveryWorkflowView.swift:1616` | "Summary exported" even when cancelled; iOS does nothing. |
| 19 | Documents ▸ Reverse | `WorkCenterView.swift:602` | One click posts a permanent reversal (cannot be undone) with no confirmation and a fixed reason. |
| 20 | AI Assistant ▸ Export CSV | `AIAssistantView.swift:1521` | "Body" column holds only the first 500 characters. |
| 21 | IMAP server search | `IMAPClient.swift:316,355` | Fetches only the first 500 / 200 matches — the **oldest** — without saying so. |
| 22 | Silent saves | `CustodianPanelView.swift:399`, `ExportRunCenter.swift:341`, `ImportMeasurement.swift:323`, `WorkCenterView.swift:715` (shows "Saved" regardless), `ContentView+Modifiers.swift:201` (Headers CSV) | A failed write looks like success. |

## P2 — naming / polish

| # | Button | Where | Problem |
|---|---|---|---|
| 23 | Batch Print All Filtered… | `ContentView.swift:4268` | Saves a .txt file; does not print. |
| 24 | Word Document (.doc) | `EmailDetailView.swift:1577` | HTML saved with a .doc extension. |
| 25 | Export Bates Index | `BatesNumberingManager.swift:405` | A failed write is reported as "Export cancelled." |
| 26 | Summarize (row menu) | `ParsedEmailListView.swift:2453` | Silently copies to the clipboard (the other menu says "(copy to clipboard)"). |

## Verified good (patterns to copy)

Redact & Export; File/Export/Forensic menu exports (vCard, ICS, Hash Manifest, MSG, PST, Relativity,
Forensic CSV, Concordance, Tagged, Privilege Log, Batch EML — streamed full scope, progress, receipts,
free-plan limits stated); Sealed Case Bundle; Investigation Report sheet; Report Builder; the four
studios' Confirm buttons; Keyword sweep; Bates assignment document; Triage verdicts; conversation
export; review-state export/import; archive clear/erase; purchases/restore; cloud/IMAP fetch limits
(visible stepper); Predictive Coding and Review Batch state (persisted); Work Center ▸ Build report.

## Fix status (2026-10-10)

All 26 items fixed in the working tree (not yet committed):

- **#1** every working-set tool shows "working on the newest N of M emails in this scope" when its set is smaller than the scope (`ArchiveWorkingSetView`, plus the 8 tools that load their own set); legal-hold/search labels say "this collection"; the GDPR data-subject report now streams the **whole archive**.
- **#2** Chain of Custody verify, E-Discovery Verify & Seal and the streamed integrity check load stored seals before comparing; legal-hold seals are set once and never overwritten (`CustodianManager.sealEvidence`). Regression test fails without the fix, passes with it.
- **#3/#4** Legal Review coding is saved and restored (`ReviewWorkspaceStore`), privileged calls become Privileged evidence tags (audit-logged); the privilege PDF/CSV list every coded email with designation, basis and Bates, RFC 4180 quoting.
- **#5–#8** Run NLP Analysis really classifies (off the render path) and posts a document; production buttons, Export Summary and Batch Export report the real outcome, log only on success, work on iOS; Batch Export exports the selection in the chosen format via the streamed export service; Journalist PDF carries leads and quotes.
- **#9–#22** Journalist work persisted; dedup records after removing and respects legal holds (it did not before); near-dup button renamed "Hide This Group"; Create Review Batches creates real batches (never overwriting reviewed ones); IT/Legal CSV quoting; Daily Report document carries the report; IOC export records only real saves; blocklist streams every confirmed email and works on iOS; custody exports signed on macOS; Reverse asks for confirmation; AI CSV full bodies; IMAP takes newest matches and says when limited; silent saves now report failures.
- **#23–#26** labels renamed (Save All Filtered for Printing…, Word-compatible Document, Summarize (copy to clipboard)); Bates index distinguishes cancel from failure.

Shared helpers: `PlatformExport.save` / `ExportOutcome` (honest saved/shared/cancelled/failed, read-back verified) and `csvRow` (RFC 4180).
