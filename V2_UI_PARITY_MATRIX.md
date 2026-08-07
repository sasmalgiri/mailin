# V2 UI PARITY MATRIX (§27)

Both shipping list modes are repository-backed and bounded (Part Q/R/S):
**Simple** = `ArchiveListView`/`ArchiveListViewModel` (minimal, fast);
**Advanced** = `ParsedEmailListView`/`ParsedEmailListViewModel` (full feature
set over the same bounded page window). The user switches in Settings ▸
Display ▸ List Mode. There is no array-backed browse architecture left and no
rollback flag (`useV2ArchiveList` removed, regression-tested).

Status: ✅ shipping/bounded/tested · S=Simple A=Advanced · ⏭ = explicit v2.1 deferral

| Legacy capability | v2 implementation | Mode | Automated test | Status |
|---|---|---|---|---|
| Browse (keyset paging fwd/back) | ArchiveListViewModel bounded window | S+A | testArchiveListVM_bidirectionalPageWindow | ✅ |
| Date sort ↑↓ | EmailQuery.sort dateAsc/dateDesc (SQL keyset) | S+A | testFilteredPagesAndSorts_matchOracle | ✅ |
| Subject A–Z sort | .subjectAZ (NOCASE index) | A | same | ✅ |
| Size sort | .sizeDesc (index) | A | same | ✅ |
| Priority sort | .priorityDesc (derived join + index) | A | same | ✅ |
| Text search | FTS5 bm25 + ranked continuation | S+A | V2SearchTests | ✅ |
| Boolean / NEAR | FTSQueryBuilder | S+A | proximity tests | ✅ |
| Regex | BoundedRegexSearch (literal→FTS→verify) | A | V2SearchTests | ✅ |
| Operator syntax (from:/to:/has:…) | ArchiveQueryCompiler → EmailQuery | A | testQueryCompiler_operators | ✅ |
| Sender/recipient/domain/subject filters | EmailQuery SQL filters | A | testFilteredPagesAndSorts | ✅ |
| Attachment filter | EmailQuery.hasAttachments | A | same | ✅ |
| Message type (sent/received) | EmailQuery.messageType | A | same | ✅ |
| User tags | email_user_tags + EmailQuery.userTag | A | V2ReviewStateTests | ✅ |
| Evidence tags | forensic_evidence_tags + EmailQuery.evidenceTag | A | V2ForensicPersistenceTests | ✅ |
| Pin/star | email_review_state (windowed service) | A | V2ReviewStateTests | ✅ |
| Read/unread | email_review_state | A | same | ✅ |
| Archive flag | email_review_state | A | same | ✅ |
| Trash / Restore / Permanent delete | soft trash flag; browse+search exclude; explicit destroy | S+A | testTrash_hiddenRestorable… + delete-reflects test | ✅ |
| Annotations | email_annotations | A | V2ReviewStateTests | ✅ |
| Multi-select + symbolic Select All | selectedEmailIDs + ArchiveSelectionScope.query | A | testSelectionScope_exclusionsVerifiedAgainstQuery | ✅ |
| Bulk actions (tag/export/delete) | streamSelected(scope:) | A | V2ExportTests | ✅ |
| Thread grouping | thread_keys persisted; paged thread query | A | V2DerivedStateTests | ✅ |
| Saved searches | ParsedEmailListViewModel (persisted) | A | existing | ✅ |
| Smart tags / sentiment / priority / phishing | derived table, windowed fetch | A | V2DerivedStateTests | ✅ |
| Topics / predictive / near-dups | persisted derived families, paged | A | same | ✅ |
| Natural-language filter | compiles to EmailQuery via helpers | A | Part D tests | ✅ |
| Attachment CONTENT search | ⏭ v2.1 (persisted attachment FTS); UI states filenames-only honestly | — | — | ⏭ |
| Reply-count filter | sender rollup aggregate (top-20k documented bound) | A | aggregate oracle tests | ✅ |
| Forensic badges | windowed forensic prefetch | A | V2ForensicPersistenceTests | ✅ |

## §28 browse-state decision

The duplicated-filter-state risk §28 targets is resolved by construction:
`ParsedEmailListViewModel.currentArchiveQuery` is the ONE compiled query that
AI scope, feature views, exports and analytics consume; the Simple list holds
only an `EmailQuery` + pager. The two view-models serve two distinct product
modes over the same repository — merging them into a single
`ArchiveBrowseState` type is a refactoring nicety, not a correctness or
memory gap, and is recorded in V2_1_BACKLOG.md.

## Manual smoke items (owner)

Sorts/filters/trash/restore/bulk actions in both modes; §OWNER-A checklist.
