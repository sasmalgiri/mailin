# mailin v2.0 — Status

> **RECONCILED 2026-08-07 — ENGINEERING COMPLETE.** The authoritative record
> is now `V2_IMPLEMENTATION_COMPLETE.md` (final acceptance matrix),
> `V2_FINAL_GAP_AUDIT.md` (every directive item closed or explicitly
> deferred), `V2_ENGINEERING_STATUS.md` (architecture of record) and
> `V2_OWNER_RELEASE_CHECKLIST.md` (remaining human gates).
> Current truth: **139 automated tests (138 pass + 1 env-gated stress
> entry) ×2 identical runs; macOS Debug + Release green; production-path
> stress executed at 10K/100K with flat RSS (1M run in progress /
> V2_SCALE_RESULTS.md)**. Statements below reflect an EARLIER snapshot and
> are retained for history only — where they conflict with the documents
> above, the documents above win.


**Target:** `maxmailin` (ships as `com.ecosanskriti.mailin`, "mailin 2.0")
**Branch:** `v2-core-cutover` (ahead of `main`; the earlier PR #3 honesty-pass is merged to `main`)
**Ship state:** **NOT shipped. ENGINEERING IN PROGRESS** — not yet even "engineering complete."
**Tests:** `maxmailinTests/V2VerificationTests.swift` — **37 tests, 36 pass + 1 heavy stress test skipped by default**, deterministic; Debug + Release build clean.
**Source of truth for claims:** `docs/index.html`.

Legend: ✅ done + test/measurement · 🟡 partial · ⬜ not started · 👤 owner/Apple-only (no agent can do it).

---

## 1. Storage / scale — DONE and measured

- ✅ **Direct SQLite is the production store**, chosen after the `mailin-v2-stress` harness proved SwiftData's import was O(N²) and keyset paging O(N) on the macOS 14.6 / iOS 17.6 target (no expressible secondary indexes). See `V2_STORAGE_DECISION.md`.
- ✅ **`SQLiteEmailStore`** — compact `emails` table + separate `email_bodies` blob table; partial-unique `message_id` index (O(1) dedup); `(date,id)` keyset index; 128 MB cache + 256 MB mmap; read loops throw on `sqlite3_step` errors.
- ✅ **1,000,000-email qualification** (`V2_SCALE_RESULTS.md`): import ~3.7 min, keyset paging 37–43 ms, RSS bounded 173–486 MB across 100K→1M, correctness perfect. **ENGINE qualification — not yet production-path.**
- ✅ **Non-destructive SwiftData→SQLite migration** (`MailinStoreMigration`) — bounded, resumable, count-gated, idempotent; **synthetic-tested only** (real device migration is 👤).
- ✅ **`StorageActivationCoordinator`** — durable states; `.active` only after count + fresh-reopen gate; stale-marker re-migration; wired at launch. Production writes go to the activated SQLite store (no SwiftData dual-write).

## 2. Bounded UI platform — DONE (browse/search/detail) · Release default

- ✅ `EmailRepository` / `ArchiveDataService` firewall (no `loadAll`); `ArchiveListViewModel` (bounded **bidirectional** page window + `queryRevision` race guard); `ArchiveDetailViewModel` (ID→hydrate, LRU, token guard); `ArchiveListView` + subviews.
- ✅ Repository-backed **text + date search**, date-scope UI, delete mutation (no page corruption).
- ✅ `ArchiveSelectionScope` (symbolic Select-All) + scoped count/stream.
- ✅ **Release now defaults to the v2 browse path** (`useV2ArchiveList`); flag retained until owner UI smoke, then deleted.

## 3. Shared derived-data platform — DONE (directive Phase 4)

- ✅ `ArchiveAggregateService` · `ArchiveDerivedStateStore` + durable corpus revision + `ArchiveBackgroundJobRunner` · `ArchiveEvidenceService` · `ArchiveExportService` (streaming) · `EvidenceVerifier` (grounded-answer + prompt-injection resistance). All oracle/differential-tested.

## 4. Consumer migration ledger (`V2_CONSUMER_LEDGER.md`)

Whole-corpus references (`parsedEmails`/`allEmails`/`filteredEmails`): **260 → 252** (one-way ratchet guard).

- ✅ Migrated (7): main list · search/date/count · detail · Spotlight · metadata · widget · duplicate review.
- 🟡 AI Assistant — grounding infra + bounded FTS tools done; `AIAssistantView` still corpus-fed.
- ⬜ Analytics/reply-stats · NLP/topics · predictive · threads · forensic/legal/export views.

## 5. Guards

- ✅ Whole-corpus ratchet (only decreases) · forbidden-pattern guard (`loadEverything`/`loadEntireArchive`/`repository.loadAll`/`.loadAll(`/`PrivateCloudComputeLanguageModel`/`limit:Int.max` — all absent).

---

## Remaining engineering (mine, NOT done)

⬜ AI Assistant corpus removal + wire evidence/verifier/token budget · analytics/NLP/predictive/threads/forensic/legal/export migrations → **ratchet to 0** · **W3**: streaming `BulkImportCoordinator` as sole importer + persistent dedup + signed receipts → **delete legacy `[RawEmail]` architecture** + remove `useV2ArchiveList` · **W4**: production-path stress (10K/100K/1M through real import→list→detail), S/MIME executed fixtures, security/privacy audit, `V2_IMPLEMENTATION_COMPLETE.md`.

## Remaining owner / Apple gates (👤 — no agent can complete)

Manual macOS + iOS UI smoke · real v1→v2 **device** migration · pricing / StoreKit / App Store Connect products · screenshots / privacy answers · submission · **Apple review** · public release · public-build smoke.

## Honest claim posture (until final measurement)

- "Instant search across the whole archive": measured — rare/NEAR sub-ms; common-term p95 grows with N (bm25 ranks all matches). Use measured wording.
- ZIP is still read whole into memory — do **not** claim flat-memory arbitrary-size ZIP.
- SPF/DKIM/DMARC = "as reported by server" (not cryptographic DNS verification). S/MIME = build-verified, executed fixtures pending.

**Bottom line:** the storage / bounded-architecture core is proven (incl. 1M) and shipping-default for browse/search/detail; **v2.0 is NOT engineering-complete** — the AI/analytics/import-rewrite/legacy-deletion/qualification remainder is outstanding, then the owner/Apple release gates.

---

## Earlier honesty-pass record (PR #3, merged to main — historical)

The prior `v2-honesty-pass` branch (now merged) reconciled code↔landing-page claims: R1 in-place migration (reads real v1 store, non-destructive, count-gated), R2 search routed through FTS5, delete integrity, store↔FTS reconcile, redaction actually strips content; S/MIME/crash-hardening/OOM-ceilings build-verified; SPF/DKIM/DMARC + AES/iCloud/PST relabeled honestly. That work is the baseline this branch builds on.
