# Semantic search: vector-search decision gate (SCALE_TODO_3_0.md §3-Q2)

The plan requires a written decision before any SQLite vector extension is adopted. Decided 2026-10-11 for 3.0.

## What 3.0 has

- **Vectors.** One NaturalLanguage sentence embedding per email (`NLEmbedding.sentenceEmbedding`, English,
  512 dimensions, Float32 = 2 KB per email). They live in the on-device semantic index (`SemanticIndex.swift`,
  `<archive root>/embeddings/embeddings.db`), built by its own resumable job. Nothing leaves the device.
- **Search.** `SemanticIndexController.neighbors` does a brute-force cosine scan, streaming row by row (flat memory).
  Results are fused with full-text ranking by reciprocal-rank fusion in `ArchiveRetrievalService` (switch:
  `v3SemanticSearch`, off by default).
- **Cost per query.** Proportional to the number of indexed emails: about 200 MB read at 100k and about 2 GB at 1M.
  The 100k / 1M timings are measured in the test pass (F7) and recorded in `SCALE_RESULTS.md`.

## Options evaluated

| Option | For | Against | Verdict for 3.0 |
|---|---|---|---|
| sqlite.org **vec1** (ANN) | Official SQLite project; ANN gives sub-linear queries | Needs SQLite built with the extension. Apple's system SQLite does not load extensions on iOS, so mailin would ship and maintain its own SQLite build — a large dependency change for an archive that must stay readable for years | Not in 3.0 |
| **sqlite-vec** | Small, simple | Pre-1.0 (format and API may change); the same custom-SQLite requirement on iOS | Not in 3.0 |
| Brute force (current) | No new dependency; exact results; flat memory | Linear per query | **Kept for 3.0** |
| Plain-SQL coarse index (IVF: k-means centroids table + bucket column, scan the nearest buckets) | No extension; works with the system SQLite on every platform | Approximate; needs a rebuild when the archive grows a lot | **3.1 candidate** |
| Int8 quantisation (512 bytes per vector) | 4× less to read per query | Small recall loss | **3.1 candidate** (with IVF) |

## Decision

1. **No extension in 3.0.** Brute-force search stays. It is exact, needs no new dependency, and keeps memory flat.
2. **The limit is stated, not hidden (rule 6).** `SUPPORTED_FORMATS_AND_LIMITS.md` says that meaning-based
   search time grows with archive size. If a per-query time is too slow at 1M in the F7 measurement, the screen
   says so and the switch stays off at that size. Results are never cut silently.
3. **3.1** evaluates IVF plus int8 in plain SQL. The gate is equal results on the golden archive (F8) and
   sub-second queries at 1M emails.
