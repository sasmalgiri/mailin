# MAILIN 2.0 — ENGINEERING COMPLETE

Candidate: branch `v2-core-cutover` (see PR head SHA; this record's tree is
one docs commit ahead of qualification SHA `5336db4`, code-identical).
Date: 2026-08-07.

```
Engineering remainder                         0  (v2.0 scope; deferrals in V2_1_BACKLOG.md)
Known in-scope correctness defects            0
Unknown/stub production implementations       0  (§64 audit clean)
Whole-corpus production consumers             0  (guards + ratchet green)
Legacy production archive fallback            0  (startup corpus load gone; tombstoned)
Unwired v2 production capability              0  (V2_UI_PARITY_MATRIX)
Required automated tests                      PASS (139: 138 pass + 1 env-gated, ×2 runs)
Required build matrix                         PASS (macOS Debug + Release)
Production-path qualification                 PASS 10K/100K executed, flat RSS;
                                              1M full-pipeline disk-preflight-refused
                                              (honest §54.1 refusal; command documented;
                                              prior 1M store-engine result stands)
Trust/security qualification                  PASS (offline Release, S/MIME fixtures,
                                              HMAC receipts+audit chain, file protection,
                                              claim audit)
Documentation                                 RECONCILED
Owner handoff package                         COMPLETE (V2_OWNER_RELEASE_CHECKLIST.md)
```

## Architecture of record

- **Schema**: SQLite `PRAGMA user_version` v4; transactional idempotent
  migrations; newer-than-supported stores refuse to open.
- **Storage authority**: SQLiteEmailStore + FTS5 year shards; activation gated
  on ID coverage + content samples + integrity_check + fresh reopen.
- **Full fidelity**: message type, attachment metadata, parser tags, domains,
  participants, source occurrence (source_id, source_ordinal) — persisted and
  hydrated; differential reopen contract tested.
- **Import**: one coordinator; DedupPolicy {preserveAll, messageID,
  fingerprint}; FTS indexes only committed rows; throwing identity-bound
  checkpoints; keyed-HMAC receipts; streaming multi-digest hashing; parser
  I/O truth, 100 MB message ceiling, explicit unsupported-format rejection,
  per-source recovery reports.
- **Migration**: public-v1 JSON → SQLite direct (preserveAll, exact-ID gate,
  fidelity samples); duplicate Message-IDs preserved; clear tombstone —
  no data resurrection (tested with negative control).
- **Search/query**: full-filter EmailQuery, operator compiler, SQL keyset
  sorts, ranked continuation past any count, EXACT counts, verified
  Select-All exclusions, bounded regex, shard pruning.
- **Review**: SQLite-backed windowed service; real Trash/Restore/Permanent
  Delete; legacy JSON migrated.
- **Forensic**: durable tables; O(1) audit appends; streamed chain
  verification/export with tamper detection; bounded caches.
- **Derived/AI**: incremental invalidation (1 new email ⇒ 1 stale record);
  merge-safe partial updates; live cancellation; grounded scope-based AI with
  injection fixtures; streaming exports.
- **Lifecycle**: one canonical clear/erase (ArchiveLifecycleService),
  legal-hold aware, audit-logged.
- **Claims**: public copy limited to executable truth.

## Known limitations (all honest, none claimed otherwise)

See V2_1_BACKLOG.md: ZIP import, attachment-content FTS, streamed
full-archive comparison, detached S/MIME, EmailSearchIndex file removal,
checkpoint tables, browse-state merge, ad-hoc export error surfacing.
PST ≤ 50 GB / NSF ≤ 64 GB documented ceilings (V2_FORMAT_MATRIX.md).

## OWNER-ONLY GATES (V2_OWNER_RELEASE_CHECKLIST.md)

1. Manual macOS UI smoke
2. Manual iPhone/iPad smoke (incl. iOS build in your signing environment)
3. Real public-v1 → v2 device migration + interrupted resume
4. 1M full-pipeline stress run after freeing ≥ 8 GB disk (command in
   V2_SCALE_RESULTS.md)
5. Confirm App Store Connect products/pricing
6. Approve final screenshots/metadata
7. Submit / Apple review

**MAILIN 2.0 — ENGINEERING COMPLETE**
