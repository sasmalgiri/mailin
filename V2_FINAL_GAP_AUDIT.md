# V2 FINAL GAP AUDIT — zero-remainder tracker

_Authoritative remainder list for the final completion directive. Every item
ends as `implemented` / `tested` / `wired` / `v2.1-deferred` with evidence.
Baseline commit: d73b600 (branch `v2-core-cutover`)._

Status legend: ☐ open · ◐ partial · ☑ done · ⏭ v2.1 deferred (with reason)

## Storage (§2–§4)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| S1 | PRAGMA user_version transactional migrations | ☐ | |
| S2 | Migration fixtures (empty/populated/rerun/bad version) | ☐ | |
| S3 | Full-fidelity hydration (messageType/attachments/domains/tags) | ☐ | rawEmailFromRow placeholders |
| S4 | `sources` table (sha256, parser, imported_at…) | ☐ | |
| S5 | `email_participants` normalized table | ☐ | |
| S6 | `attachments` metadata table | ☐ | |
| S7 | `email_tags` / `email_domains` | ☐ | |
| S8 | source_id + source_ordinal UNIQUE locator | ☐ | |
| S9 | emails table extension (message_type, size_bytes, has_attach…) | ☐ | |
| S10 | DedupPolicy enum (preserveAll/messageID/fingerprint) | ☐ | |
| S11 | dedup_key nullable + partial unique index (message_id no longer unconditionally unique) | ☐ | |
| S12 | Differential persist→reopen→hydrate contract test | ☐ | |

## Import (§5–§9)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| I1 | BulkImportCoordinator sole importer + Options | ☑ | ContentViewModel:282,348 |
| I2 | Free-tier cap enforced in coordinator | ☑ | BulkImportCoordinator:312–319,428 |
| I3 | Streaming source hashing | ☑ | BulkImportCoordinator sha256 FileHandle 1MB |
| I4 | stored→indexed crash-window batch state in SQLite | ☐ | checkpoints JSON-only |
| I5 | Checkpoints in durable transactional storage | ◐ | JSON w/ thrown errors; move or justify |
| I6 | Receipt keyed HMAC + verifyReceipt + tamper tests | ☐ | SHA-256 self-hash only |
| I7 | MBOX read errors throw (no try?→fake EOF) | ☐ | MBOXParser:277,386 |
| I8 | Per-message byte ceiling | ☐ | |
| I9 | Unsupported extension explicit error (incl. ZIP) | ☐ | ParserFactory default→MBOX |
| I10 | lastRecoveryReport global removed from production truth | ☐ | MBOXParser:179 |
| I11 | V2_FORMAT_MATRIX.md | ☐ | |
| I12 | EML as bounded RFC822 (From:-first header works) | ◐ | verify + test |

## Migration (§10)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| M1 | Content-identity gate (per-ID + fingerprints, not count) | ☐ | count-only today |
| M2 | v1 duplicate Message-ID preservation | ◐ | JSON→SwiftData ok; SQLite unique idx conflicts |
| M3 | No data resurrection after clear (tombstone) | ☐ | |

## Query/Search (§13–§18)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| Q1 | EmailQuery full shipping filter breadth | ☐ | text+date only |
| Q2 | ArchiveQueryCompiler (from:/to:/has:attachment/…) | ☐ | |
| Q3 | DB-native sorts (subject/size/priority keyset) | ☐ | (date,id) only |
| Q4 | Ranked continuation cursor across shards | ☑ | FTSSearchIndex:420–522 |
| Q5 | Year-shard pruning + differential test | ☑ | FTSSearchIndex:380–390 |
| Q6 | Exact text+date count beyond 2,000 cap | ☐ | EmailRepository:130,195 |
| Q7 | streamMatchingIDs for Select All/exports/bulk | ☑ | ArchiveSelectionScope:47–85 |
| Q8 | Scope exclusions verified against query | ☐ | blind subtraction :41 |
| Q9 | Bounded regex | ☑ | FTSSearchIndex:1268–1392 |
| Q10 | Attachment text search bounded or honestly absent | ☐ | EmailSearchIndex:863 in-memory |

## Review/User state (§19–§20)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| R1 | email_review_state / tags / annotations tables | ☐ | user_review_data.json |
| R2 | Trash soft-delete + Restore + Permanent Delete | ☐ | physical row delete today |
| R3 | Old review JSON migrated + verified | ☐ | |
| R4 | No archive-sized review maps at startup | ☐ | in-memory Sets |

## Forensic (§21)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| F1 | Evidence tags/annotations/hashes in durable tables | ☐ | ForensicManager in-memory |
| F2 | Audit log persisted + paged (HMAC chain kept) | ◐ | JSON whole-in-memory |
| F3 | Source identity by source_id+SHA not filename | ◐ | |
| F4 | Per-email hash semantics documented | ☐ | |

## Derived (§22–§26)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| D1 | Per-email invalidation (no global full recompute) | ◐ | verify corpusRevision semantics |
| D2 | Partial analyzer updates never NULL other families | ◐ | single derived row; verify/fix |
| D3 | cancel() cancels live Task; compute off MainActor | ☑ | ArchiveBackgroundJobRunner:175 |
| D4 | NLP/topics/predictive/threads persisted | ☑ | derived/thread_keys/predictive tables |

## UI (§27–§28, §35, §37)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| U1 | V2_UI_PARITY_MATRIX.md | ☐ | |
| U2 | All still-shipping legacy capabilities migrated/deferred | ◐ | Advanced mode carries most |
| U3 | ArchiveComparisonView off [RawEmail] init arrays | ☐ | |
| U4 | One browse architecture (no rollback flag) | ☑ | useV2ArchiveList removed |

## AI (§29–§31)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| A1 | Corpus properties removed; scope-based | ☑ | AIAssistantView workingSet |
| A2 | Mandatory grounding + abstention | ☑ | AIGroundingGate |
| A3 | Agentic action authorization | ☑ | AgenticPlanner onConfirmAction |
| A4 | Prompt-injection fixtures | ◐ | verify coverage |

## Lifecycle (§11)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| L1 | ArchiveLifecycleService canonical clear | ☐ | Clear&StartFresh → legacy clear only |
| L2 | Erase-all covering every store | ◐ | LegalComplianceManager partial |
| L3 | No-resurrection regression test | ☐ | |

## Trust/Security (§48–§49, §68)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| T1 | S/MIME claim reconciled (detached honest) | ◐ | .unverifiable mapping done; copy audit open |
| T2 | Offline Release audit | ☑ | entitlements, OFFLINE_MODE |
| T3 | Receipt integrity wording truthful | ☐ | ties to I6 |
| T4 | Final claim audit (README/metadata/help) | ☐ | |

## Qualification (§54–§63)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| P1 | >2,000-match paging regression fixture | ☐ | |
| P2 | Full suite ×2 recorded | ☐ | |
| P3 | Build matrix (macOS Debug/Release) | ◐ | Debug green at baseline |
| P4 | Zero-stub audit (§64) | ☐ | |
| P5 | Live-wiring audit (§65) | ☐ | |
| P6 | Scale runs recorded honestly | ◐ | store-engine 1M done; production-path env-gated |

## Docs (§67–§70)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| X1 | Status docs rewritten from actual state | ☐ | |
| X2 | V2_FORMAT_MATRIX / UI_PARITY / OWNER_RELEASE / V2_1_BACKLOG | ☐ | |
| X3 | V2_IMPLEMENTATION_COMPLETE.md | ☐ | only when remainder = 0 |
| X4 | Final PR prepared | ☐ | |
