# Mailin 2.0 — Engineering Status (branch `v2-core-cutover`)

_Rewritten 2026-08-07 from actual code + executed evidence (final directive
run). Supersedes all earlier status labels. Tracker: V2_FINAL_GAP_AUDIT.md.
Completion record: V2_IMPLEMENTATION_COMPLETE.md._

## The invariant — held end to end

**Archive size does not determine resident memory.** Canonical storage is
versioned SQLite (schema v4, `PRAGMA user_version` transactional migrations)
plus FTS5 year shards. Every production path — import, browse (both list
modes), search, filters, review state, forensic state, derived analysis, AI
retrieval, exports, clear/reset — is paged, streamed or windowed. Executed
production-path evidence: flat 105→117 MB RSS from 10K→100K
(V2_SCALE_RESULTS.md); prior 1M store-engine qualification stands; the 1M
full-pipeline run was disk-preflight-refused this session (honest deferral,
command documented).

## What ships (each with automated tests — 139 total, ×2 runs, 0 failures)

- **Storage**: schema versioning v1→v4; full RawEmail fidelity (message type,
  attachments metadata, parser tags, domains — no placeholders); normalized
  sources/participants/attachments/tags/domains tables; stable
  (source_id, source_ordinal) occurrence identity; DedupPolicy
  {preserveAll, messageID, fingerprint} with partial-unique dedup_key.
- **Import**: BulkImportCoordinator sole engine; FTS indexes only committed
  rows; identity-bound throwing checkpoints; HMAC-signed receipts (keyed,
  fingerprinted; forged-checksum attack regression-tested); streaming
  triple-digest source hashing; parser I/O errors throw; 100 MB per-message
  ceiling; unknown/ZIP extensions rejected explicitly; per-source recovery
  reports (no global state).
- **Migration**: public-v1 JSON → SQLite DIRECT (full fidelity, preserveAll,
  exact-ID-coverage + sampled-content gate); SwiftData→SQLite activation gate
  verifies ID coverage + content samples + integrity_check + fresh reopen;
  clear tombstone prevents resurrection (§61 regression + negative control).
- **Query/search**: EmailQuery covers the shipping filter set; SQL-compiled
  filters + keyset sorts (date/subject/size/priority); ArchiveQueryCompiler
  for operator syntax; ranked continuation past any result count (2,100-match
  regression); EXACT text(+filter) counts via streamed cursor; Select-All
  exclusions verified against the query; bounded regex; shard pruning.
- **Review state**: SQLite tables + windowed service; REAL Trash
  (soft, searchable-on-restore, permanent delete separate); legacy JSON
  migrated verified.
- **Forensic**: tags/annotations/hashes/source hashes/audit log in SQLite;
  audit chain O(1) append + streamed verification/export with tamper
  detection; bounded caches only.
- **Lifecycle**: ArchiveLifecycleService — one canonical clear/erase across
  every layer, legal holds respected, audit-logged.
- **Derived/AI**: incremental invalidation (1 new email ⇒ 1 stale record —
  tested); merge-safe partial updates; LIVE job cancellation; scope-based AI
  with mandatory grounding + injection fixtures; streaming exports over
  ArchiveSelectionScope.
- **Claims**: README/metadata/docs reconciled to executable truth (S/MIME
  opaque-only, server-reported DKIM, AES-256 export scope, measured latency).

## Remaining

Engineering: **none in v2.0 scope** — deliberate deferrals live in
V2_1_BACKLOG.md (ZIP import, attachment-content FTS, streamed full-archive
comparison, detached S/MIME, EmailSearchIndex file deletion, checkpoint
tables, browse-state merge, ad-hoc export error surfacing).

Owner/device/App Store gates: V2_OWNER_RELEASE_CHECKLIST.md
(macOS/iOS smoke, real v1→v2 device migration, StoreKit confirmation,
screenshots, submission) plus the 1M full-pipeline stress run once ≥8 GB
disk is free.
