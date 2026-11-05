# Five jobs — requirement tracker

Governing plan: [`FIVE_JOBS_MASTER_PLAN.md`](FIVE_JOBS_MASTER_PLAN.md) (owner, 2026-11-05). Branch `v3-architecture`.
Baseline reconciled against HEAD `4788ed0` (2026-10-22, 3.0.2 build 903) on 2026-11-05 — Stage 0 done.
The plan's findings were taken at `a8e8758` (2026-10-09); the "Source state" column below is what the code
does **now**, not then.

States: `not started` · `in progress` · `implemented` · `verified` · `failed` · `blocked`.
"Implemented" is not "verified": verified needs the test/fixture named in "Test" to have run on the candidate.
Rules from `CLAUDE.md` still apply (never destroy data, counts before whole-archive actions, no hidden caps,
every string in 10 languages, test with each change, new engines behind a `Capability`, commit per step).

## Stage 0 — baseline (done 2026-11-05)

| Plan finding (at a8e8758) | At HEAD 4788ed0 | Evidence |
|---|---|---|
| PST/OST/NSF/MSG materialise whole result before batching | **still true** | `EmailParserProtocol.swift:250,397-408`; `PSTSpecReader.messages()`; `NSFParser.swift:11`; `MSGParser.swift:8` |
| Sidebar caps labels at 200 | **still true** | `ArchiveSidebar.swift:143,165`; `SQLiteEmailStore.swift:3464-3478`; not covered by `v3PagedLists` |
| No DOCX/XLSX/PPTX extraction; OCR not in search | **partly fixed** — OCR of images and scanned PDFs feeds `attachment_search` (4d95577, 5b79600); no Office extraction | `AttachmentTextIndexJob.swift:254-301` |
| "Attempted" without searchable text | **still true** — `attachment_text_state(email_id, indexed_at, text_count)` only; no extractor version | `SQLiteEmailStore.swift:850-854`; `AttachmentTextIndexJob.swift:151-152` |
| 500,000-char attachment cutoff; 4 MiB body budget | **still true**, no chunking; body truncation is at least recorded and shown | `AttachmentTextIndexJob.swift:56,249`; `FTSSearchIndex.swift:1127,1144-1158` |
| Duplicate content scan stops at 5,000 | **partly fixed** — `DuplicatesEngine` streams whole archive behind `.v3Duplicates` (on by default); old 5,000 path remains as fallback | `DuplicatesEngine.swift`; `DuplicateManagerView.swift:479-480` |
| "Exact" = Message-ID or 200-char body prefix | **still true** (+ EDRM MIH normalised hash, 67da27e); all three keys → one "exact" bucket, FNV-64 shortened; no raw-byte SHA-256, attachments not compared | `DuplicatesEngine.swift:38-57`; `FeatureIndex.swift:130-156` |
| Folder export only flat / by-year | **still true** | `ExportRequest.swift:25-27` |
| Per-file manifest removed on success | **still true** — receipt has one optional whole-output sha256, no per-file hashes, no verified/failed counts | `ArchiveExportService.swift:591-593`; `ExportReceipt.swift:32-48` |
| >100 MiB messages are locators into the uncopied original | **still true**; `copiesOriginals` only affects the storage estimate | `OffsetImportEngine.swift:56,245`; `BulkImportCoordinator.swift:133-138` |
| Real OST/NSF never executed; drive-removal-during-write untested | **still true** — 15 real PSTs pass vs readpst; OST/NSF "no fixture"; mid-write detach kills the process (SIGBUS), recovery not tested from outside | `SUPPORTED_FORMATS_AND_LIMITS.md:98,244`; `SCALE_RESULTS.md:170,213-240` |

Already solid (reuse): import checkpoints bound to source SHA-256/size/parser (`ImportCheckpointStore.swift`),
export cancel/keep-partial/resume with 17 tests (`ExportResumeTests.swift`), legal-hold check inside delete
(`deleteReportingHeld`), source identity table, many-to-many `email_tags`.

## Requirement matrix

| ID | Stage | Source state at HEAD | Required change | State | Change ref | Test |
|---|---|---|---|---|---|---|
| OPEN-01 | B | Classifier (64 KB sample) + Guided Import sheet + storage preflight; encryption only detected while parsing; no corrupt/inaccessible preflight | `SourceFormatClassifier.preflight(url:)` → `SourceCondition` ready / unsupported / inaccessible (missing, no permission, unlistable folder) / damaged (empty, PST shorter than its header or with table roots past the end, NSF/MSG too short, ZIP without a directory — still starts, parser reports) / encrypted (undocumented PST encoding; ZIP whose every file member is encrypted; partly encrypted ZIP = ready + count). The import sheet shows the condition and reason per file before Start and only starts what can start; no credential is ever asked for | verified | see OPEN-01 commit | `V2CutoverTests.testOPEN01_preflightTellsTheFourObstaclesApart`: real mbox, non-mail text, missing + chmod-000 file, empty/short/truncated PST, directory-less ZIP, crypt-3 PST vs cyclic PST, all-/partly-encrypted ZIP, `ImportPlan` split |
| OPEN-02 | B | Only mbox/eml/"" stream; PST/NSF/MSG return full arrays | `PSTParser.parseStreaming` (one message per node, NID order, carve keeps key sets) and `NSFParser.parseStreaming` (one record at a time, no 500,000-note cap) behind `streamingBinaryParsers` (on; requires MS-PST reader); `ParserFactory` routes pst/ost/nsf there. MSG stays whole-file: one message per file. Limits doc updated | verified | d3c15e4 (PST), dbf9b82 (NSF) | `V2CutoverTests.testOPEN02_pst*` / `testOPEN02_nsf*`: ~100 MB fixtures, 2,000 messages, batches of 100 through the factory, footprint grew < half the file, every message once, same first message as the array path; PST writer/reader and engine-matrix tests green; package NSF stub tests |
| OPEN-03 | B | Checkpoints bound to SHA-256/size/parser; resume tested incl. eject at batch boundary | Verify only; add process-restart-after-mid-write test from outside the process | implemented | existing | `FaultVolumeTests` + new out-of-process kill test |
| OPEN-04 | B | Browsing during import exists; "mail imported" vs "attachments indexing" partly shown | Verify; show processed counts/bytes when total unknown | not started | | UI check on PST (unknown total) |
| OPEN-05 | B | Receipt per run with discovered/parsed/inserted/duplicates/damaged/skipped/persistFailed; per-source only identity | Per-source counts; add `unreadable` and `unresolvedRegions` | not started | | receipt reconciles to fixture ground truth |
| OPEN-06 | E | 15 real PSTs; 1 GB rows; OST/NSF no fixture; ≤50 GB | Run §8.1 matrix on candidate; record first-message/total/peak RSS/temp disk | not started | | `SCALE_RESULTS.md` rows tied to commit |
| FOLD-01 | A | `labelLimit = 200`, flat ForEach | Under "Complete lists (3.0)": folder total shown, 200 per page with Show more, server-side name filter (LIKE, wildcards escaped); switch off = previous busiest-200. Tree view waits for FOLD-02's folder table | verified | eed9466 | `V2CutoverTests.testFOLD01_*` (2): 10,000 folders paged to completion once, filter/case/literal-%, sidebar model both paths |
| FOLD-02 | B | Folders are flat tag strings; sources table exists; no parent/child, no empty folders | Schema v21 (additive, snapshot first): `folders(source_id, path, name, parent_id, declared)` + `email_folders`, backfilled from `email_tags` at upgrade (Apple Mail flag tags excluded); dual-written with `email_tags`. PST declares its whole folder tree (empty folders kept); Apple Mail / Maildir / EML-folder imports stamp the mailbox from the layout; Gmail labels are memberships of one email; `RawEmail.folderPath` + `flags`; `EmailQuery.folderID`; sidebar "Folders" tree per source under Complete lists (3.0); `rebuildFoldersFromTags()` recovery. Maildir++ sub-folders and nested EML folders still flatten to the root name (members are not expanded) — stated | verified | 79f6c2e | `V2CutoverTests.testFOLD02_*` (5, incl. the schema-guard check that caught `currentSchemaVersion` lagging the chain): two PSTs with the same "Inbox" stay distinct, nested Clients under its own Inbox, empty "Archive 2019" declared with 0, per-folder query returns only that source's mail, sidebar tree; Gmail two labels = one email with parents; flags excluded + rebuild from tags; directory layout → mailbox name |
| FOLD-03 | B | `email_tags` many-to-many | Verify; UI explains unique vs occurrence counts; dedup must keep memberships (see DUP-04) | not started | | Gmail multi-label fixture |
| FOLD-04 | B | `email_tags` (source) vs `email_user_tags` (user) separate | Verify immutability: rename shows display label only | not started | | rename then export shows original path |
| FOLD-05 | D | No tree layout on export | With OUT-03: safe names + mapping file for collisions/Unicode/long paths | not started | | adversarial names fixture |
| FIND-01 | C | PDF text, RTF, HTML, plain; no Office | DOCX/XLSX/PPTX extraction (ZIP + XML, no macros) with sheet/slide context | not started | | target string only inside each Office type |
| FIND-02 | C | OCR → `attachment_search` when switch on | Verify in v3 search path; label recognised vs original text; query Vision supported languages at runtime | in progress | 4d95577, 5b79600 | labelled scan set, per language |
| FIND-03 | A | `attachment_text_state` = indexed_at + text_count | `AttachmentCoverageStore` (sidecar SQLite) records per attachment extracted/truncated/noText/unsupported/locked/failed + extractor version + reason; queued is derived, processing is the in-flight email; stale rows re-queued at pass start (`extractorVersion`); "no attachments matched" notice names what was not searchable. Also fixed: Office MIME ("…xml…") bytes were indexed as Latin-1 text. Per-attachment badge in the detail view comes with FIND-05 | verified | 72eb3de | `V2CutoverTests.testFIND03_*` (2): five-attachment fixture states/characters/summary/search, stale re-queue + re-index, notice wording; OCR + attachment-search suites green |
| FIND-04 | C | FTS over subject/sender/recipients(To+Cc)/body; attachment content only via `in:attachments` in old list | Attachment content in the v3 search path by default; Bcc indexed; literal default; Bengali/Hindi tests | not started | | 3-language fixture |
| FIND-05 | C | Attachment hit returns email_id only; no snippet | Hit → attachment id + filename + snippet (FTS5 `snippet()`), opens attachment and parent | not started | | same filename twice |
| FIND-06 | C | Budgets exist (timeout/decompression); encrypted handling implicit | Verify; encrypted → `locked` state, never "no text" | not started | | encrypted PDF/ZIP |
| FIND-07 | C | 500,000-char attachment prefix; 4 MiB body prefix | Chunked FTS rows with parent id + offset/page; query across chunks; remove both ceilings | not started | | word at end of 2 MB doc; phrase across chunk boundary |
| DUP-01 | A | Message-ID / 200-char prefix / MIH all labelled "exact" | `DuplicateVerification` compares every group in full (stored bytes → byte-identical; else all addresses, date, subject, whole body, attachment bytes/identity → content-equivalent; else candidate naming the differing fields). Only verified groups enter bulk selection; archive-wide one-click removes verified copies only and reports candidate groups | verified | afd47f5 | `V2CutoverTests.testDUP01_*` (8): same ID + different attachment, body differs after prefix, transport headers only, metadata-only attachments, bulk selection, chunked archive-wide, store groups |
| DUP-02 | C | Streaming engine on by default; old 5,000 path as fallback | Verify whole scope; surface scan errors; fallback must say so on screen | in progress | b285a7c, 20306fd | identical copies beyond 5,000 |
| DUP-03 | C | One bucket | Classes: byte-identical (SHA-256 raw), content-equivalent (full body + attachment hashes), similar (MinHash), candidate | not started | | adversarial set, zero false identical |
| DUP-04 | C | Delete drops tags/annotations of removed copy | Merge memberships/annotations into survivor before hide/remove; hide-as-duplicate before delete | not started | | memberships preserved after cleanup |
| DUP-05 | C | Holds respected; no undo; minimal receipt | Diff view, survivor preview, recoverable removal (tombstone + restore), durable receipt, honest bytes estimate | not started | | undo restores memberships |
| OUT-01 | D | Many formats; PDF/CSV not flagged as non-restorable | Format picker labels: mail-preserving / attachments / report | not started | | UI strings |
| OUT-02 | D | Selection snapshot for resume exists | Verify drift-free under concurrent import; unique vs per-occurrence choice | not started | | import during export |
| OUT-03 | D | Headers/bodies/attachments exported; no source-tree layout | `ExportLayout.sourceFolders`; record format-induced changes | not started | | tree fixture round trip |
| OUT-04 | D | Receipt: requested/written/outcome; no verified/failed; handoff only counts messages | Reconciliation: selected/written/checked/excluded/failed; full reparse + SHA-256 vs source; "sampled" when sampled | not started | | tamper one file → fails |
| OUT-05 | E | Automated 526/526; Apple Mail/Thunderbird rows NOT TESTED | Owner runs Apple Mail import (and Thunderbird if claimed); record versions | blocked (owner) | | `MAIL_CLIENT_HANDOFF_TESTS.md` |
| OUT-06 | D | Cancel/partial/resume with 17 tests; free-space preflight; no mid-write ENOSPC test | Add export ENOSPC-mid-write test (disk image) | implemented | ca6dc9e, 98b8b46 | `DiskImageFaultTests` export row |
| OUT-07 | D | Manifest deleted on success | Finalise manifest into durable `inventory.json` (per file: source id, sha256, bytes, attachments) next to output; receipt links it | not started | | inventory present after success |
| LIFE-01 | B | Linked-source only (locators) | `selfContainedArchive` switch (on): each single-file source is copied into `<archive>/sources/<sha256>/` with the copy's SHA-256 checked against the import hash (temp name, moved into place; a mismatch leaves nothing) and parsed FROM THE COPY, so every locator points inside the archive. Directory sources hold no locators and are not copied — stated. Linked mode: `missingLocatorSources()` (messages + how many have no other copy) and `relinkLocators(sourceDigest:to:)` after the SHA-256 matches; Settings ▸ Health "Original files" section with Relink… | verified | see LIFE-01 commit | `V2CutoverTests.testLIFE01_*` (3): copy verified / tampered copy discarded with no leftover; self-contained import reads and verifies the deferred message after the original is deleted; linked mode names the moved file with counts, refuses an impostor, relinks the real file |
| LIFE-02 | B | Snapshots before migration exist | SQLite online backup + blobs + inventory; restore on clean profile | not started | | clean-profile restore |
| LIFE-03 | B | Field contract implicit | Write field contract doc; concurrent-job test | not started | | import during dedup + export |
| LIFE-04 | E | Safe HTML, bounded extraction exist | Verify protection of indexes/temp/logs; diagnostic export omits bodies | not started | | |
| LIFE-05 | E | Sample mbox, help exist | Recovery actions: Reconnect / Retry failed / Rebuild index / Restore | not started | | |
| LIFE-06 | E | Newest-500 free tier; Pro Lifetime | Owner policy decision on post-expiry reading/export; capability table tested | blocked (owner) | | entitlement matrix |

## Owner decisions taken during the work

- 2026-11-05 — tests: only the five-jobs tests and the classes a change touches; no full suite, no AI /
  Professional test classes.
- 2026-11-05 — scale: fixtures of ~100 MB per format are the evidence; the bounded-memory design (streaming
  parsers, batch writes, no whole-result arrays) is what covers larger files. The plan's 1–100 GB tiers
  (§8.1) are not run; docs say "tested at 100 MB; memory does not grow with file size".

## Order of work

Stage A (done 2026-11-05): DUP-01 afd47f5 → FOLD-01 eed9466 → FIND-03 72eb3de → truthful labels (the previous
duplicate engine states its 5,000-email window, alone or after a fallback; the attachment-search notice names
what was not searchable — see commit after 72eb3de). Exit evidence: candidate groups cannot drive bulk removal;
every folder reachable; an attempted attachment without text is shown as such.
Stage B (now): OPEN-02, FOLD-02, LIFE-01, OPEN-01, OPEN-05, LIFE-02, LIFE-03, OPEN-03/04 verify.
Stage C: FIND-07, FIND-01, FIND-04, FIND-05, FIND-02/06 verify, DUP-03, DUP-04, DUP-05, DUP-02 verify.
Stage D: OUT-07, OUT-04, OUT-03 + FOLD-05, OUT-01, OUT-02, OUT-06 test.
Stage E: OPEN-06, LIFE-04/05/06, OUT-05 (owner), gates.

## Gates (§9) — all open

| # | Gate | State |
|---|---|---|
| 1–10 | see plan §9 | open |

## Owner decisions needed

- OLM reader and TAR/TGZ wrapper: proposed additions, not adopted. Adopt or defer?
- LIFE-06 post-expiry policy (plan recommends: reading + basic export stay available).
- OUT-05 Apple Mail / Thunderbird interactive import runs.
- OST and NSF real fixtures (none exist; without them those rows stay "partially supported").
