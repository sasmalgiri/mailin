# mailin v2 — Completion Roadmap (bounded-memory + evidence-grounded AI)

**Premise (verified against `v2-honesty-pass`):** the v2 *engine* is right (SwiftData `EmailStore` + sharded FTS5 + streaming ingest + keyset pagination), but the **UI and AI layers still carry the v1 whole-array pattern** — the next layer of the same "built but not wired" problem PR #3 attacked. This roadmap finishes the foundation rewrite so *archive size does not determine resident memory*, and turns the AI assistant into an **evidence-grounded, bounded** feature.

**Do NOT pile these onto PR #3.** PR #3 is the honesty pass; this is the v2.0-completion track. Items marked 2.1/2.2 must not block v2.0.

Legend: ✅ done · 🔴 confirmed gap (code refs below) · ⏸️ 2.1/2.2 · 🧪 needs test/gate

---

## Verified gaps in current code (why this roadmap exists)
- 🔴 `ContentViewModel.parsedEmails: [RawEmail]`, `ParsedEmailListViewModel.allEmails/filteredEmails: [RawEmail]` — whole archive resident in the UI.
- 🔴 AI tools take `let emails: [MBOXParser.RawEmail]` (whole archive); `SearchEmailsTool` uses `EmailSearchIndex.shared.hybridSearch` (in-RAM), `GetThreadInfoTool` uses `ThreadGrouper.group(emails)` — AI bypasses the v2 engine.
- 🔴 `ParsedEmailListViewModel.swift:666` — proximity/regex `return nil` → in-RAM `proximitySearch`/`regexSearch` over `allEmails`.
- 🔴 `FTSSearchIndex.allIndexedIDs() -> Set<UUID>` — builds a full-corpus ID set (unbounded memory) for reconcile.
- 🔴 `FoundationModelEngine.modelInputCharCap = 12_000` — character approximation, not token-aware.

---

## v2.0-completion scope (what finishes the rewrite)

### P0 — `V2-CORE-CUTOVER` (new mandatory gate): bounded-memory UI end-to-end
No production screen holds `[RawEmail]` for the whole archive. UI works on `EmailSummary` / `EmailPage` / `SearchResult` / `EmailID`, hydrating `EmailStore.fullEmail(id:)` only on demand. Import → `BulkImportCoordinator` → `EmailStore` + `FTSSearchIndex` → paged IDs/summaries → UI.
**Gate:** stress harness (below) shows RSS does **not** grow linearly with corpus size.

### P0 — AI tools → v2 engine, never the whole archive
Replace the array-holding tools with bounded tools that call only `FTSSearchIndex` / `EmailStore` / forensic+analytics repositories: `SearchArchiveTool`, `FetchEmailTool`, `FetchThreadTool`, `FetchAttachmentTextTool`, `GetTimelineTool`, `GetContactStatsTool`, `GetArchiveStatsTool`, `GetEvidenceTool`. Tools receive query params + return bounded evidence, never `[RawEmail]`.

### P0 — Evidence-grounded AI answers (by construction)
`@Generable GroundedAnswer { answer; findings: [GroundedFinding]; limitations: [String] }`, `GroundedFinding { statement; evidenceIDs: [String]; confidence }`. Every factual assertion must cite retrieved message/evidence IDs; the model may answer *"not enough evidence in this archive."* Market as **Evidence-grounded archive AI**, not "AI Assistant." Keep `SystemLanguageModel` (on-device); never `PrivateCloudComputeLanguageModel` (breaks offline contract).

### P1 — Token-aware context packing
Replace the 12k char cap with `model.contextSize − (instructions + tools + output reserve + conversation)` = retrieval token budget; rank+pack evidence with `tokenCount(for:)`. (Foundation Models 26.4 APIs; availability-gate.)

### P1 — FTS5 proximity through real `NEAR()`, remove in-RAM fallback
Compile `budget NEAR/5 deadline` → `NEAR("budget" "deadline", 5)` and run through FTS5; delete the `allEmails` proximity path. **Regex:** extract mandatory literal fragments → FTS candidate retrieval → run regex only on candidate rows (no 10M-body scan); consider trigram tokenizer later.

### P1 — Bounded/paged FTS reconciliation
Drop the global `Set<UUID>`. Add a per-shard `indexed_message(email_id PK, indexed_revision)` table written in the same txn as FTS indexing; reconcile with a saved cursor, 5,000 store IDs at a time, query the registry, index only missing, advance cursor. Deterministic, cheap, no whole-corpus set.

### P1 — Production stress harness = release gate (`mailin-v2-stress`)
Uses the **shipping app's APIs** (not the standalone `maxmailin` bench). Corpora 10K (every CI) / 100K (release) / 1M (qualification) / 10M (nightly). Measure import throughput, **peak RSS**, store+FTS size, first-page latency, deep pagination, search p50/p95, Boolean/NEAR/regex, delete visibility, reconcile time, cold/warm launch, AI first answer + retrieval. **Hard gate: RSS must not grow linearly with corpus.** If the SwiftData bridge fails, *then* port the proven direct-SQLite store from `maxmailin` (benchmark first, don't rewrite on vibes).

### P1 — Honest scale UX (instead of faking "instant across everything")
Measured reality (from `maxmailin` oracle): 10M unrestricted FTS ≈ 8.4 s. So default large archives to a **time scope** (All / Recent year / 90 / 30 / custom) and detect date constraints from the query, routing to relevant shard(s). Relabel "instant across your whole archive" accordingly.

### P1 — Uniform import receipts (extends RecoveryReport)
Every import emits an immutable, signed/hashed receipt: source (name/size/SHA-256/parser+version), result (discovered/imported/duplicates/damaged/attachments/warnings), timing, integrity (source hash, checkpoint state, destination count, FTS indexed count), recovery (resumed?, recovered/skipped batches). Turns "I imported it" into "prove exactly what happened."

### P1 — S/MIME fixtures (promote 3.3 to executed)
Untrusted-CA message + genuine detached signature → assert untrusted reports untrusted, detached verifies.

### P2 — `BGContinuedProcessingTask` (iOS/iPadOS), availability-gated
User-started import continues in background with a Live Activity + cancel; older OS uses foreground + existing checkpoint/resume. Safe because imports are resumable.

### P2 — Device gates (unchanged, still open)
Real-device v1→v2 migration (`V2_SMOKE_TEST.md`); pricing/copy business decisions (Step 9).

---

## Explicitly DEFERRED to 2.1/2.2 — must NOT block v2.0
- ⏸️ **Core AI** (OS 27 beta; AOT targets OS 27+) — define `protocol SemanticReranking` now, ship `NLEmbeddingReranker`, add `CoreAIReranker` later. No rewrite.
- ⏸️ **OS 27 Dynamic Profiles** mapped to personas (Personal/Analyst/Legal/IT/Journalist) — architecture now, runtime after OS 27 final.
- ⏸️ **Semantic reranking** — `NLEmbedding` rerank of FTS top-50/200 → top-20 (on-device); NOT a 10M-vector DB.
- ⏸️ Secure Enclave P-256 dual-anchor for Pro (device-backed signature alongside HMAC+Ed25519) — don't overclaim.
- ⏸️ Real DKIM/DMARC DNS crypto · loadable PST writer · true ZIP central-directory streaming · full semantic corpus index · Siri/Apple Intelligence surface · new UI.

---

## Target architecture (v2.0 done)
```
                      MAILIN 2.0
              ┌────────────┴────────────┐
          Import                    Query
       Streaming parser          Query planner
       batches 200–500        ┌──────┴──────┐
          checkpoint      structured filters   FTS5
          EmailStore          └──────┬──────┘
       ┌──────┴──────┐          candidate IDs
   metadata     bodies/blobs   optional NL reranker
       └──────┬──────┘            evidence set
        paginated UI          Foundation Model (bounded tools)
                                  GroundedAnswer → answer + evidence IDs
```
Result: a **private, bounded-memory, evidence-grounded archive analysis engine** — not "an email viewer with AI."

---

## First increments — STATUS (on `v2-honesty-pass`, each with executed tests)
1. ✅ **P0-S1 FTS5 `NEAR()` proximity** — `FTSQueryBuilder` + `searchRaw`; in-RAM proximity fallback removed. Tests: near/far match, quoting-safe, live dispatch (red-then-green).
2. ✅ **P0-S2 paged reconciliation** — `indexed_message` registry (same-txn), `indexedSubset` (chunked), `FTSReconciler` (keyset cursor, restartable, no 100k ceiling, no whole `Set`). Tests: missing-beyond-first-page, interrupted/resumed.
3. ✅ **P0-#3 AI `SearchEmailsTool`/`GetThreadInfoTool` → FTS5+EmailStore** (bounded). Test: reaches FTS5, ≤5 evidence, not the corpus.
4. ⏸️ **Scale-claim relabel** + query-driven time scoping — copy + query planner (next).
5. ⏸️ **Analytics AI tools** (timeline/contacts/stats) still take `[RawEmail]` — repository-backed aggregates (next AI increment).

**STOP HERE on this branch** (per plan). The big track — **P0 whole-UI bounded-memory cutover** (`ContentViewModel`/`ParsedEmailListViewModel` off `[RawEmail]`) — goes on **`v2-core-cutover`** with **`mailin-v2-stress`** built first as its acceptance oracle (RSS must not grow linearly with corpus).
