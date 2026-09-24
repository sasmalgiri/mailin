# mailin — Release Readiness

Tracks the 3.0 baseline, measured facts, and the split between
engineering-complete and owner/Apple gates. Companion to `V3_0_PLAN.md`.

Status: **P0 in progress** (started 2026-09-23).

---

## P0.0 Build baseline

| Item | Result |
|---|---|
| Workspace | `maxmailin.xcodeproj`, single shared scheme `maxmailin` |
| Targets | `maxmailin` (app), `maxmailinTests`, `maxmailinUITests` |
| Build (macOS, incremental, active config) | **PASS** — 0 errors, 44.5 s, 2026-09-23 |
| Baseline commit | working tree at `771e993` (pre-2.1-tag; the 2.1 tag does not exist yet, so all P0 numbers are labelled against `771e993`) |

Release-configuration build, clean-build time, and the iOS build are **NOT YET
MEASURED**.

---

## P0.1 Cold-launch work inventory

Every job that runs today on a cold launch with no user action, read out of
`mailinApp.swift:100–266`. "Owner" is the module that will own it after P1;
"3.0 disposition" is what has to change.

| # | Launch-time work | Site | Owner after P1 | 3.0 disposition |
|---|---|---|---|---|
| 1 | `StoreManager.resetDailyCountersIfNeeded()` | :101 | AppShell | keep |
| 2 | `configureAppearance()` | :102 | AppShell | keep |
| 3 | **`BackgroundAnalysisManager.shared.scheduleBackgroundAnalysis()`** | :105 | AI Insights | **gate** — no analysis scheduling on a disabled launch |
| 4 | `Tips.configure` | :106 | AppShell | keep |
| 5 | `MemoryPressureHandler.shared.start()` | :115 | AppShell | keep |
| 6 | Pressure hook → `FTSSearchIndex.evictIdleShards` | :121 | ArchiveCore | keep |
| 7 | **Pressure hook → `FoundationModelEngine` cache invalidation** | :131 | AI Insights | **gate** — registering it forces the AI type to exist |
| 8 | **Pressure hook → `AIAssistantView.invalidateNLPCache`** | :146 | AI Insights | **gate** — same reason |
| 9 | `AppSelfAttestation.shared.compute()` | :157 | AppShell | keep; measure cost |
| 10 | `MigrationService.shared.migrateIfNeeded()` (v1 JSON → SQLite) | :164 | ArchiveCore | keep — archive-core migration is always allowed |
| 11 | `StorageActivationCoordinator.shared.activate()` (SwiftData → SQLite gate) | :173 | ArchiveCore | keep |
| 12 | `HMACChainAuditLog.shared.append("v2.storage.activation")` | :174 | Professional | **gate** — owner ruling (§3.3 R6): no audit-chain write when Professional is off. Archive's own import receipt records the storage/activation provenance instead |
| 13 | `FidelityBackfillJob.shared.kickIfNeeded()` | :195 | ArchiveCore | keep as bounded repair; **measure** and declare the schedule |
| 14 | **`AttachmentTextIndexJob.shared.kickIfNeeded()`** | :199 | ArchiveCore | keep, but make it follow the per-import indexing choice (directive §2) instead of running unconditionally |
| 15 | **`DigestScheduler.shared.checkAndDeliver()`** | :201 | AI Insights | **gate** — weekly digest must not exist on a disabled launch |
| 16 | **`WorkflowService.seedBuiltins()`** | :205 | Professional | **gate** — directive §1 forbids workflow-catalog work on disabled launches |
| 17 | Detached `FTSReconciler.reconcile` + `dedupeShards()` | :213–233 | ArchiveCore | keep; **measure** bounded cost |
| 18 | `MaxmailinSelfTest.shared.runIfNeeded()` | :240 | AppShell | already `#if DEBUG` — fine |
| 19 | `HMACChainAuditLog.append(launch/selfTest)` + `verifyChain()` | :248–265 | Professional | **gate + move off launch** (§3.3 R6) — no launch append when Professional is off; verification runs on demand or on Page 3 open, never as a whole-chain walk at every cold launch |
| 20 | `TermsAcceptanceView` launch sheet | :90 | AppShell | keep |
| 21 | **`PersonaOnboardingView` launch sheet** | :92 | Professional (preference) | **remove from the launch path** — directive §0: a new customer sees Archive with no persona choice |
| 22 | `BiometricLockManager` lock overlay | :299 | AppShell / Enterprise | keep |
| 23 | `SpotlightIndexer.shared.handleSpotlightActivity` | :282 | ArchiveCore | not launch work (user activity) — fine |

**Eight items must be gated or moved for P1's "disabled means nothing runs"
criterion: #3, #7, #8, #12, #15, #16, #19, #21.** #12 and #19 were resolved by
the owner ruling recorded as `V3_0_PLAN.md` §3.3 R6 — no provenance carve-out;
the audit chain is Professional-owned and silent while Professional is off,
with Archive's receipts carrying Page 1 provenance. Three items (#9, #13, #17)
need measurement before we can claim the cold-launch budget is unaffected.

Consequence to implement with #12/#19: the chain's genesis entry must declare
that it starts at Professional enablement and that earlier activity is
evidenced by import/export receipts only — never implying unbroken continuity
across a disabled period.

---

## P0.1b Singleton inventory

69 `static let shared` declarations across 66 files. First-pass classification
(to be confirmed file-by-file during the P1 extraction):

| Prospective owner | Count | Notes |
|---|---|---|
| ArchiveCore (store, FTS, import, export, migration, checkpoint) | ~24 | e.g. `SQLiteEmailStore`, `EmailStore`, `EmailRepository`, `FTSSearchIndex`, `EmailSearchIndex`, `MigrationService`, `StorageActivationCoordinator`, `ImportCheckpointStore`, `ImportActivityManager`, `FidelityBackfillJob`, `AttachmentTextIndexJob`, `ArchiveExportService`, `ExportRunCenter`, `ExportSigner` |
| Archive feature (derived analysis/UI services) | ~9 | `ArchiveDerivedState` (×2), `ArchiveDerivedAnalysis`, `ArchiveAnalyticsService`, `ArchiveFullAnalytics`, `ArchiveAggregateService`, `ArchiveRetrievalService`, `ArchiveTimelineService`, `ArchiveDataService` |
| AI Insights | ~8 | `BackgroundAnalysisManager`, `DigestScheduler`, `AIProvenance`, `AIMetrics`, `CloudAIProvider`, `CustomExpertManager`, `PredictiveCodingEngine`, `SmartAutoTagger` |
| Professional | ~17 | `HMACChainAuditLog`, `ChainOfCustodyManager`, `CustodianManager`, `BatesNumberingManager`, `ForensicManager`, `ForensicReviewManager`, `ReviewStateService`, `ReviewBatchManager`, `CollaborationManager`, `CollaborativeReviewActivity`, `PersonaManager`, plus the five 2.1 studios (`ACHMatrixStudio`, `FactEvidenceMatrixStudio`, `EvidenceDesksStudio`, `ActionRegisterStudio`, `ReasoningStudio`) |
| Live Mail / cloud (currently excluded by `OFFLINE_MODE`) | 5 | `GmailConnector` (×2), `OutlookConnector` (×2), `iCloudSyncManager` |
| AppShell / platform | ~6 | `MemoryPressureHandler`, `AppSelfAttestation`, `MaxmailinSelfTest`, `LegalComplianceManager`, `BiometricLockManager`, `FeedbackManager`, `ToolWindowPresenter`, `PluginManager`, `WidgetDataProvider`, `WorkspaceManager`, `WatchFolderManager`, `SpotlightIndexer`, `TriageQueueService`, `ThreadKeyService`, `EncryptedStorageManager` |

P1 rule that follows from this: a `static let shared` on an optional-module
type is only safe if touching it does **no work** — the five studios and the
eight AI singletons must either become registry-owned instances or prove that
their initializer allocates nothing and schedules nothing. That check becomes a
unit test asserting no file I/O and no timer registration on first access.

---

## P0.2 Runtime baseline

### Measurement fixture (owner-provided, 2026-09-23)

| Fixture | Size | Content | Use |
|---|---|---|---|
| `~/Downloads/Mail/Sent.mbox` | 91 MiB (95.4 MB decimal) | ~526 messages by `From_` count; ~173 KB/message average, so attachment-heavy | Import throughput, attachment coverage, FTS coverage, MBOX round-trip (P4 H2) |
| `~/Downloads/Mail/*.eml` | 10 files, ~840 B each | Single RFC-822 messages | EML path + duplicate-policy checks |

This is a real byte-scale fixture, not a synthetic one, and it exercises the
attachment path that small corpora miss. It is **not** a substitute for the
P9 16/50/100/200 GB rows.

Note on the production container: TCC blocks this agent from reading inside
`~/Library/Containers/com.ecosanskriti.mailin/Data`, so whether a real archive
lives there cannot be confirmed from the shell. Launch-time items #10, #11,
#13, #14 and #17 run against whatever is there — the same jobs that run on any
normal launch, but they do mutate the store (backfill, FTS dedupe). Measurement
runs check the app's own archive state on launch before importing anything.

### Measured — Release build, existing library, all optional pages off

Host: this Mac (arm64, macOS 27.0). Build: `xcodebuild -configuration Release
-destination platform=macOS,arch=arm64` → **BUILD SUCCEEDED**. Run: launched
from DerivedData, left idle, sampled with `ps`/`lsof`, 2026-09-23.

| Metric | Measured | Note |
|---|---|---|
| App bundle size | **81 MB** | Release, unstripped of dSYM side files |
| Process visible after `open` | **≤ 3 s** | coarse: first `pgrep` check. Launch-to-usable is NOT MEASURED — needs signpost instrumentation |
| Idle RSS | **526 MiB** (538,688 KB) | steady across ~10 min idle |
| Idle CPU | **0.0 %** | no spin at rest |
| Open FTS year-shard databases at idle | **20** (`email_search_0.db` + per-year shards) | each with `-wal` and `-shm` |
| Main store open | `emails.db` + `-wal` + `-shm` | as expected |
| Open regular files | **141** | |
| **Network sockets** | **0** | zero-network baseline holds on the signed Release build (pre-3.0: `OFFLINE_MODE` excludes all connector code and the entitlements carry no `network.client`) |
| Graceful quit | **vetoed** — AppleScript quit returned `-128 User cancelled`; needed `SIGTERM` | a modal launch gate (terms or persona sheet) is the suspect; confirm during P1's launch rework |

**This is an existing-library baseline, not a fresh-install baseline.** The 20
open year-shards prove a real archive lives in the container, spanning roughly
2007–2026. A fresh-install baseline requires a clean container (separate bundle
id or a moved-aside container) and is still NOT MEASURED.

### Finding: 20 FTS shard handles stay open at idle

`MemoryPressureHandler` only evicts shards *under pressure* (keep 4 on warning,
2 otherwise — `mailinApp.swift:121–124`). With no pressure, all 20 stay open and
hold their SQLite page caches, which is the bulk of the 526 MiB. Nothing here is
an optional module: this is Page 1's own resting cost, and it grows with the
number of years in the archive.

Directly relevant to the §3.3 requirement — the all-off baseline is supposed to
be the floor every other module is measured against, and a floor that scales
with archive age is the wrong shape. Added to the plan as **A9: idle shard
eviction** (close shards untouched for N minutes; open lazily on query) with a
before/after RSS measurement.

### Measured — engine-path import of the real fixture (isolated)

`FixtureImportMeasurementTests` parses `~/Downloads/Mail/Sent.mbox` into
`MailinStorageEnvironment.disposable(at:)`, which hard-refuses any root
overlapping the production tree, so the owner's real archive is untouched. This
drives the production parser, store and FTS directly — it is **not** the
`BulkImportCoordinator` production path (that is `@MainActor` and wired to the
shared singletons; see task A10). **Configuration: Debug** — timing is not
quotable, memory shape is.

| Metric | Measured |
|---|---|
| Source | 94,915,160 bytes (90.5 MiB), Sent.mbox |
| Discovered / stored / damaged | 526 / 526 / **0** |
| Messages with attachments | **152** of 526 |
| FTS rows after import | 526 — **coverage equals stored rows** |
| Batches at the production default (500) | **2** |
| Wall time | 44.6 s — **Debug build, not a throughput claim** |
| RSS baseline → peak | 170.8 MiB → **571.3 MiB** (**+400.5 MiB**) |

Reconciliation is asserted, not eyeballed: `stored + damaged == discovered` and
`ftsRows == stored` are test assertions, so the measurement fails if accounting
ever drifts.

### Measured — PRODUCTION-path import of the real fixture

After plan task A10 (dependency injection into `BulkImportCoordinator`), the
same coordinator the app uses can be driven over disposable storage. This row
may be quoted as production-path; the Debug-configuration caveat still applies.

| Metric | Measured |
|---|---|
| discovered / parsed / damaged | 526 / 526 / 0 |
| inserted / stored | 526 / 526 |
| duplicates / persistFailed | 0 / 0 |
| indexed / FTS rows | 526 / 526 |
| Wall time | 44.0 s (Debug) |

Accounting identities asserted by the test, not read off a log:
`discovered == parsed + damaged`, `stored == parsed - persistFailed`, and
`ftsRows == stored`.

### Measured — A9 idle shard eviction

| Observation | Result |
|---|---|
| Handles open at launch (Release, existing 20-year archive) | 20 |
| Handles after the 180 s idle TTL | **0** — verified by `lsof` on the shipped Release build |
| Scheduler fires without being called | **yes** — `testScheduledSweep_firesWithoutBeingCalled` drives the real sweep task, not the sweep function |
| Data after eviction | intact — rows, queries and re-indexing all verified after handles close |
| Idle RSS reduction | **NOT DEMONSTRATED.** Samples were 421 MiB at 25 s, 388 MiB at 140 s, 392 MiB at 270 s (handles already 0). Closing a connection returns its page cache to SQLite's allocator, which need not return pages to the OS; `sqlite3_release_memory` is now called after a sweep, but no before/after A-B has been run. Claim only the handle result. |

A true RSS before/after needs the eviction behind a runtime flag so one binary
can be measured both ways — not yet built.

### CORRECTION (2026-09-24): the 400 MiB import peak is NOT batch-driven

The finding below was written as the justification for `AdaptiveBatchController`
and attributed the 400 MiB peak to batch sizing. Measurement after wiring the
controller shows that attribution was **wrong**:

| Batching | Batches | Max batch | Peak RSS delta |
|---|---|---|---|
| Fixed 500 messages | 2 | 500 | +400 MiB |
| Adaptive, 32 MiB byte bound | 3 | 256 | +410 MiB |
| Adaptive, expansion-aware 16 MiB bound | 4 | 168 | +423 MiB |

Halving batch residency twice did not move peak memory at all, so the memory is
not held by the batch. Attributing it properly:

- **The fixture spans 19 years (2007–2025)**, so the import opens **19 FTS
  shard connections**, each with its own SQLite page cache. That cost
  accumulates with the import's date spread, not with batch size.
- **`SQLiteEmailStore` sets `PRAGMA cache_size = -131072` (128 MB), plus
  `mmap_size = 256 MB` and `temp_store = MEMORY`** (`SQLiteEmailStore.swift:103–105`).
  The store is *configured* to hold up to 128 MB of pages, and touched mmap
  pages count in `phys_footprint`.

So the levers for import peak memory are the SQLite cache/mmap budget and the
number of shard connections held open during an import — **not** batch size.
Added to the plan as **P3.3**. The controller is still required (bounded,
byte-aware batches; pause on real pressure; oversized-item spooling — all
directive requirements), but it must not be sold as the fix for this number.

Measured expansion factor worth keeping: a 32 MiB source-byte bound produced
~410 MiB of peak footprint, so parsed objects run roughly **13×** the source
bytes they came from. `BatchEnvelope.measuredParsedExpansion` records it.

### P3.3 attribution: the parser's per-message object graph owns the peak

Three hypotheses, measured in order. Two were wrong:

| Hypothesis | Change made | Peak RSS delta | Verdict |
|---|---|---|---|
| Batch size | fixed 500 → adaptive 256 → adaptive 168 | 400 → 410 → 423 MiB | **falsified** |
| SQLite cache/mmap + shard cap | store 128→32 MB cache, 256→64 MB mmap, shard cap 20→4 | 419 MiB | **falsified** |
| Parser residency | stage-by-stage attribution | see below | **confirmed** |

Stage attribution over the same corpus and batch shape
(`ImportMemoryAttributionTests`, deltas are per-stage because process RSS does
not fall back when memory is freed):

| Stage | Footprint delta |
|---|---|
| Parse only | **+334.8 MiB** |
| Parse + store | +147.3 MiB (marginal; the heap had already grown in stage 1) |
| Parse + store + index | +171.4 MiB (marginal) |

Parsing alone accounts for the bulk. That also explains why changing the batch
count did nothing: the high-water mark is set by the **per-message transient
graph**, not by how many messages are in flight. For each message
`MBOXParser` joins every line into one full string copy
(`MBOXParser.swift`, `currentLines.joined`), `MIMEParser` builds part objects,
attachments are decoded, and the resulting `RawEmail` then retains
`rawSource` *and* `plainBody` *and* `htmlBody` — several copies of the same
message resident at once. On a 173 KB average message that is a few hundred KB;
on one message with a 20 MB attachment it is tens of MiB, and the worst single
message sets the peak.

So the lever is per-message parse residency — plan task **P3.4**. Note
`RawEmail` already carries `isBodyCompacted` and `bodyPreview`, so a compaction
path exists to build on.

P3.3's budget work is kept as correctness hygiene (bounded caches, capped shard
connections, both restored after an import) but it must not be claimed as a
memory improvement: measured, it changed nothing.

### Hypothesis ledger for the import peak (four measured, three falsified)

| # | Hypothesis | Change / instrument | Result | Verdict |
|---|---|---|---|---|
| 1 | Batch size | fixed 500 → adaptive 256 → 168 | 400 → 410 → 423 MiB | **falsified** |
| 2 | SQLite cache/mmap + shard cap | 128→32 MB cache, 256→64 MB mmap, cap 20→4 | 419 MiB | **falsified** |
| 3 | Attachment base64 retained per message | `retainAttachmentBytes: false` | `base64` is **already nil** — `EmailBodyExtractor.swift:325` never populates it | **falsified** |
| 4 | Retained MIME part tree | deterministic object-byte count | **28 bytes** retained for a 1.4 MB message | **falsified** |
| 5 | Per-message allocator churn | not yet measured | — | **remaining candidate** |

Hypothesis 3's plumbing was **reverted**: it changed parser output (`mimeRoot`
nil, which `ForensicManager.buildMIMETree` reads) for zero measured benefit.
The parameter survives on `MBOXParser.processRawMessage` with a warning
comment so the same wrong conclusion is not re-derived from its name.

**Instrument caveat that matters more than any of the above:** identical runs
produced 400, 410, 419, 423 and 478 MiB. That is roughly ±15 % variance, so a
single run cannot attribute a change of this size. Deterministic object-byte
counting (as in `AttachmentCompactionTests`) settled hypotheses 3 and 4 in
seconds where RSS could not. Future memory work needs repeated runs, a larger
corpus, or an allocation-level instrument — not another single-run RSS reading.

What stage attribution does still say: parse-stage first-touch growth was
+334.8 MiB while store and index added marginal amounts, and since neither
retained structure explains it, the remaining candidate is the per-message
String/Array churn — `currentLines` holding one `String` per line, the
`joined()` full copy, and `EmailBodyExtractor` re-splitting the same text.
Addressing that means parsing from bytes rather than `[String]`: plan task
**P3.5**, a real parser rewrite on the most safety-critical code in the app.

### Finding (SUPERSEDED as an explanation): the fixed 500-message batch ignores message size

A 90 MiB source with 526 attachment-heavy messages fits in **two** batches at
`batchSize = 500`, and peak RSS rises **400 MiB** above baseline. The batch
bound is a message *count*, so batch memory scales with whatever those messages
happen to weigh — exactly the failure mode `AdaptiveBatchController` exists to
prevent (plan §5.1: bound parsed **bytes** as well as count). This is now
measured evidence for that design rather than an assumption, and it is the
before-number for A9/P3 work.

Note the shape: 400 MiB of batch residency against a 526 MiB idle store cost
means a large import on a small Mac is fighting the resting FTS cost too.

### Still not measured, and why

| Metric | Status |
|---|---|
| Fresh-install cold launch, idle RSS, footprint | NOT MEASURED — needs a clean container (see above) |
| Launch-to-usable timing | NOT MEASURED — needs signpost instrumentation, added to P1 |
| Release-configuration timing of any measurement test | NOT MEASURABLE this way — `@testable import maxmailin` needs `ENABLE_TESTABILITY`, which Release correctly does not set. Route Release timing through the in-app `StressHarness` (Release-safe by design) extended to accept a real file — task A11 |
| Production-path (`BulkImportCoordinator`) import of the fixture | NOT MEASURED — the coordinator is `@MainActor` and bound to the shared singletons; needs the repository injection in task A10 |
| Signed-entitlement dump (`codesign -d --entitlements`) | NOT VERIFIED — the tooling call kept timing out in this environment; source entitlements are known (§1 B6), signed-binary confirmation still owed |
| v1 JSON → SQLite migration timing | NOT MEASURED — needs a genuine v1 library fixture |
| v1 JSON → SQLite migration timing | NOT MEASURED — needs a genuine v1 library fixture |
| 2.x customer-library open timing | NOT MEASURED — needs a copy of a real 2.x library |
| `HMACChainAuditLog.verifyChain()` cost vs chain length | NOT MEASURED — needs a long chain fixture |
| Clean-build time, Release config, iOS build | NOT MEASURED |

---

## Owner / Apple gates (not engineering)

| Gate | Needed for | Status |
|---|---|---|
| Release iOS 2.0, then 2.0.1 | current train | owner |
| Cut the 2.1 tag (studios) and renumber `V3_PLAN.md` / `V3_RELEASE_PLAN.md` from 3.0 → 2.1 | 3.0 branch point | open |
| Microsoft Entra app registration (client ID + `msauth.com.ecosanskriti.mailin://auth`) | 3.0 Page 4 | open |
| Google Cloud project + restricted-scope/CASA decision | 3.1 Gmail (L3b) | open |
| iCloud container identifier + Documents-vs-CloudKit choice | P8 prototype | open |
| Apple Business Manager enrolment | Enterprise Offline SKU | open |
| App Store privacy label + description rewrite | 3.0 submission | open |
| Test hardware / corpora (250 GB Mac, ~1 TB mixed sources) | P9 | open — absent these, P9 rows ship as NOT TESTED |
