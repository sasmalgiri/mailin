# V2 Legacy Whole-Corpus Consumer Ledger

Tracks migration of every consumer of the in-RAM `[RawEmail]` corpus
(`ContentViewModel.parsedEmails` / `ParsedEmailListViewModel.allEmails` /
`filteredEmails`) onto the **ArchiveDataService** firewall (bounded,
SQLite-backed).

**Rule:** the array remains a temporary correctness ORACLE (`LEGACY_CUTOVER_ONLY`)
while consumers migrate. Each slice migrates ONE consumer, adds a differential
fixture test (new vs old on the same input), and only then retires the old
dependency. The ratchet guard `testLegacyCorpusConsumerCountOnlyDecreases`
started at **260** occurrences (5C.0) and may only decrease; it is now **255**.

A slice is complete only when its production dependency is removed and its test
is green. Do NOT add `repository.loadAll()`.

## Shared platform (built, all differential/oracle-tested)

`ArchiveDataService` (firewall) · `ArchiveListViewModel` (bounded bidirectional
page window) · `ArchiveDetailViewModel` (ID hydrate + LRU + race guard) ·
`ArchiveSelectionScope` · `ArchiveAggregateService` (SQL aggregates) ·
`ArchiveDerivedStateStore` + corpus revision + `ArchiveBackgroundJobRunner` ·
`ArchiveEvidenceService` · `ArchiveExportService` (streaming) · `EvidenceVerifier`
(grounded-answer + prompt-injection resistance).

## Ledger

| # | Consumer | Slice | Status | Differential test |
|---|----------|-------|--------|-------------------|
| — | **ArchiveDataService firewall** | 5C.0 | ✅ done | `testArchiveDataService_matchesArrayOracle` |
| 1 | Main mail list (browse) | W1-A | ✅ done (Release default) | `testArchiveListVM_differentialAgainstOracle` |
| 2 | Search / date / count filters | W1-B | ✅ done | `testDateBoundsHonoredAndTextPlusDateSupported` |
| 3 | Detail (open row) | W1-A | ✅ done | `testArchiveDetailVM_hydrationMissingAndRace` |
| 4 | Spotlight indexer | W2-B | ✅ done | `indexAllFromArchive` streams `streamFullEmails` |
| 5 | Metadata / counts / widget / recent | W2-B | ✅ done | `testArchiveAggregateService_matchesOracle` |
| 6 | AI Assistant (corpus handed in) | W2-C | 🔶 grounding infra done; `AIAssistantView` still takes `allEmails`/`filteredEmails` | `testEvidenceVerifier_...` |
| 7 | Analytics / reply statistics | W2-C | ⬜ (`EmailAnalyticsView(emails:)`) | derived aggregates vs array |
| 8 | NLP / topic precompute | W2-D | ⬜ | derived output vs array |
| 9 | Predictive coding / vectors | W2-D | ⬜ | features vs array |
| 10 | Duplicate review | W2-D | ⬜ (`removedDuplicates: [RawEmail]`) | duplicate set vs array |
| 11 | Forensic / export paths | W2-E | ⬜ (stream via `ArchiveExportService`) | exported set vs array |

Note: consumers 1–3 route the *shipping* browse/search/detail path onto the
repository; their legacy `ParsedEmailListView`/`filteredEmails` array remains as
the fallback/oracle (still counted by the ratchet) until W3 deletes it.

## Files touching the corpus (baseline 5C.0)

AIAssistantView, AIWindowManager, ArchiveComparisonView, ContentViewModel,
ContentView, CustodianPanelView, DuplicateManagerView, FoundationModelEngine,
ForensicReviewView, ParsedEmailListView, RemovedDuplicatesView,
ITAdminAnalysisView, KnowledgeGraph, SmartAutoTaggerView, MBOXParser,
LegalReviewWorkspaceView, ParsedEmailListViewModel, ReportBuilderView,
PredictiveEngine.

## Final steps (only after the ledger reaches zero)

- 5B.2 bounded authoritative import (parser → 200–500 batch → dedup → SQLite →
  FTS5 → checkpoint/receipt → release).
- 5C.6 delete `parsedEmails` / `allEmails` / `filteredEmails`, archive-wide
  `EmailSearchIndex.build(from:)`, whole-array dedup, corpus-resident caches.
- 5D.3 rerun the stress harness through the **production** import/list/detail
  path; promote only storage/import/pagination/detail matrix rows.
