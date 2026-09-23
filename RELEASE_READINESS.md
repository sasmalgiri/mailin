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

Not measured yet, and why:

| Metric | Status |
|---|---|
| Cold-launch time (Release) | NOT MEASURED — measurement run pending |
| Idle RSS after launch | NOT MEASURED — same |
| On-disk footprint of a fresh install | NOT MEASURED — same |
| Import of `Sent.mbox` (time, peak RSS, FTS coverage) | NOT MEASURED — next step |
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
