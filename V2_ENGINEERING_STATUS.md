# Mailin 2.0 — Engineering Status & Handoff (branch `v2-core-cutover`)

_This is an honest status, not a "complete" sign-off. It records exactly what is
bounded and verified, what remains, and why each remaining item is gated._

## The invariant

**Archive size must not determine resident memory.** v2 moves storage to SQLite
(+ FTS5) and every access path to bounded pages/streams so that browsing,
searching, analysing, and answering questions over a 1-email or a 1-TB archive
cost the same RAM. Proven to 1,000,000 emails (import, keyset paging 37–43 ms,
flat RSS — see `V2_SCALE_RESULTS.md`).

## Bounded & verified (oracle/differential tests in `maxmailinTests/V2VerificationTests.swift`, 46 pass + 1 stress-skip)

- **Storage**: `SQLiteEmailStore` (WAL, mmap, keyset `(date,id)`, partial-unique
  `message_id` O(1) dedup + persistent dedup findings), `FTSSearchIndex` (FTS5 bm25/NEAR).
- **Read/list/detail/search**: `ArchiveDataService` firewall (no `loadAll`),
  `ArchiveListViewModel` bounded page window, `ArchiveDetailViewModel`, FTS search.
- **Analytics/insight engines migrated off the in-RAM corpus (each oracle-tested):**
  1. `PredictiveEngine` — bounded working-set.
  2. `AnomalyDetectionEngine` — archive-wide streaming tally.
  3. `ArchiveFullAnalyticsService` (was `EmailAnalyticsView`) — scoped streaming.
  4. `CommunicationPatternAnalyzer` — two-pass streaming aggregates.
  5. `ArchiveTimelineService` (was `EmailTimelineView`) — day-bucket stream + range drill-down.
  6. `ExecutiveDashboardView` — order-independent 2-pass streaming.
- **AI substrate — primary answer paths bounded (owner smoke-test pending):**
  `ArchiveRetrievalService` (FTS5 bm25 → hydrate, oracle-tested); corpus-free
  `respond`/`respondStreaming`/`respondSmart`/`summarize`/`triageEmails`/
  `generateInsights`/`synthesizeThread`/`securityBrief`/`generateDigest(period:)`.
  Consumers migrated: AppIntentShortcuts, AIAssistantView (all 5 answer paths),
  General/ITAdmin/Journalist/Personal (analysis + digest).

## OWNER SMOKE-TEST GATE (do this first — it unblocks the residual AI work)

Run the app on a real archive and confirm each still cites the right emails:
1. AI assistant — a **general** question (`respondSmart`, top-50 bm25 relevant).
2. **Insights**, **Security brief**, **Thread story** actions (bounded ≤200 recent).
3. **Daily/weekly digest**.
4. Global search (FTS5 bm25).

Ranking is now FTS5 bm25, **not** the old in-RAM sentence-embedding vector hybrid.
If any answer is worse, note which — retrieval limits are easy to tune, or the
vector path can be restored for that specific call.

## Remaining engineering (gated — reasons stated)

1. **Residual AI retrieval helpers** (smoke-test-gated): `chunkSearch(in:emails)`,
   `expandByThread(allEmails:)`, and the synchronous NLP-fallback `hybridSearch`
   sites in `AIAssistantView`/`AgenticPlanner`/`GeneralAnalysisView`. These are
   corpus-array-based and partly synchronous → a sync→async cascade in the
   answer-quality path. Migrate after the smoke-test confirms bm25 retrieval is
   acceptable, so quality is judged once.
2. **Retire the in-RAM `EmailSearchIndex` build** (`ContentView` import path): only
   after (1), since those helpers are its last consumers.
3. **Legacy corpus views** (`ParsedEmailListView` ~3460 lines; the 5 analysis
   views ~1100–1850 lines each): still receive `[RawEmail]` for list rendering,
   text search, and multi-feature display. Each needs migration to paged/query
   access. Their engine families are largely bounded already (see list above);
   what remains is list/search/display wiring — large and behaviourally
   UI-verifiable only.
4. **Remove `EmailPersistence.load()` startup rehydration** + **ratchet → 0** +
   **remove `useV2ArchiveList`**: all blocked on (3) — the startup corpus is
   load-bearing for the un-migrated legacy views. Removing it before they are
   migrated would break them. (Alternatively, the owner may choose the
   "bounded-preview" product tradeoff — a decision, not a code task.)
5. **W4**: production-path stress (10K/100K/1M through the real import→list→
   detail→AI path), S/MIME executed fixtures, security/privacy audit.

## Owner / Apple gates (cannot be done by an agent)

Device UI smoke, real v1→v2 device migration, pricing/StoreKit/App Store Connect,
screenshots/privacy answers, submission, Apple review, public release.

## One-line summary

The storage floor, all read paths, six analytics/insight engines, and the primary
AI answer paths are bounded and test-backed. The remaining work is (a) owner
smoke-test of AI answer quality, then (b) the large legacy-view list/search
migrations that unblock startup-rehydration removal and ratchet→0, then (c) W4
stress + the owner/Apple release gates.
