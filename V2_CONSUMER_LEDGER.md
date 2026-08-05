# V2 Legacy Whole-Corpus Consumer Ledger

Tracks migration of every consumer of the in-RAM `[RawEmail]` corpus
(`ContentViewModel.parsedEmails` / `ParsedEmailListViewModel.allEmails` /
`filteredEmails`) onto the **ArchiveDataService** firewall (bounded,
SQLite-backed).

**Rule:** the array remains a temporary correctness ORACLE (`LEGACY_CUTOVER_ONLY`)
while consumers migrate. Each slice migrates ONE consumer, adds a differential
fixture test (new vs old on the same input), and only then retires the old
dependency. The ratchet guard `testLegacyCorpusConsumerCountOnlyDecreases`
(baseline **260** occurrences at 5C.0) fails if the count ever rises.

A slice is complete only when its production dependency is removed and its test
is green. Do NOT add `repository.loadAll()`.

## Ledger

| # | Consumer | Slice | Status | Differential test |
|---|----------|-------|--------|-------------------|
| — | **ArchiveDataService firewall** | 5C.0 | ✅ done | `testArchiveDataService_matchesArrayOracle` |
| 1 | Main mail list (browse) | 5D.1 | ⬜ | list ids/order/count vs array |
| 2 | Search / date / count filters | 5D.2 | ⬜ | filter result set vs array |
| 3 | Detail (open row) | 5D.1 | ⬜ | `EmailID → fullEmail(id:)` |
| 4 | Spotlight indexer | 5C.1 | ⬜ | indexed ids vs array |
| 5 | Metadata / counts / widget / recent | 5C.1 | ⬜ | aggregates vs array |
| 6 | AI Assistant (corpus handed in) | 5C.2 | ⬜ | evidence set vs array |
| 7 | Analytics / reply statistics | 5C.3 | ⬜ | derived aggregates vs array |
| 8 | NLP / topic precompute | 5C.4 | ⬜ | derived output vs array |
| 9 | Predictive coding / vectors | 5C.4 | ⬜ | features vs array |
| 10 | Duplicate review | 5C.5 | ⬜ | duplicate set vs array |
| 11 | Forensic / export paths | 5C.5 | ⬜ | exported set vs array |

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
