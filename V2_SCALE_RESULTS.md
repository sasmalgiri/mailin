# V2 Scale Results — `mailin-v2-stress`

> **SCOPE: ENGINE QUALIFICATION — NOT production-UI qualification.**
> These measurements qualify the *bounded storage engine* (`EmailStore` +
> `FTSSearchIndex` + `EmailStoreRepository` + `FTSReconciler`) in isolation.
> They do **not** qualify any screen. The production UI still holds whole
> `[RawEmail]` arrays and has not been cut over. **Do NOT turn the Production
> Wiring Matrix's overall scale column green on the basis of this document.**

## What was measured

`StressHarness` (`maxmailin/StressHarness.swift`) drives the **real** shipping
code paths — no benchmark-only fake persistence:

- Storage: `MailinStorageEnvironment.disposable(at:)` — an isolated on-disk
  store + FTS index. The safety gate refuses any root overlapping production,
  so no run can read/alter/migrate/clear/vacuum real user data.
- Import: `EmailStore.insertBatch` (with the real per-message-ID dedup).
- Index: `FTSSearchIndex.indexBatch` (year-sharded FTS5).
- Reconcile: `FTSReconciler.reconcile(store:fts:)` (bounded keyset page-walk).
- Paging: `EmailStore.summaryPage` (keyset `(date DESC, id DESC)`).
- Search / count: `FTSSearchIndex.searchRaw` / `countRaw`, incl. `NEAR()`.
- Delete: `EmailStoreRepository.delete` (FTS-first, then store).

**Corpus** is deterministic (SplitMix64, seed `0x00004A115EED600D`): multiple
years (→ multiple FTS shards), a same-timestamp block (keyset tie-break),
common/rare terms, Boolean fixtures, `NEAR()` fixtures, 1% duplicate
Message-IDs, and known expected result-ID sets.

**Memory** is `phys_footprint` (the accounting the OS Jetsam limit uses).

### Honest caveats

- **Configuration = Debug.** Absolute throughput is a *lower bound*; a Release
  build is faster. Per the directive, the decisive signal is **RSS scaling**,
  which is configuration-insensitive. Scaling *shape* (below) is unaffected.
- **Body size = 600 bytes**, which is below SwiftData's external-storage
  threshold, so `externalStorageBytes = 0` at every scale — the
  `.externalStorage` blob path was **not** exercised here. Realistic multi-KB
  bodies will externalize; that path needs a separate measurement.
- **1M and 100K were not executed to completion** — see "Extrapolation".

## Results (Debug, seed `0x00004A115EED600D`, 600B bodies)

| Scale | Import msg/s | Import s | Index msg/s | Peak-import RSS (MB) | Post-import RSS (MB) | Reconcile RSS (MB) | Search RSS (MB) |
|------:|------:|------:|------:|------:|------:|------:|------:|
| 2,000 | 914 | 2.2 | 20,833 | 157.8 | 127.2 | 134.4 | 136.6 |
| 4,000 | 533 | 7.6 | 24,198 | 147.2 | 141.0 | 156.9 | 156.9 |
| 8,000 | 251 | 32.2 | 25,359 | 127.0 | 127.0 | 138.7 | 138.7 |
| 16,000 | 121 | 133.3 | 23,399 | 158.1 | 151.9 | 159.2 | 159.3 |

| Scale | First page ms | Deep page ms | Search p50/p95 ms | NEAR p95 ms | Count ms | Reopen count ms | Reopen first-page ms | Reconcile-verify s | Disk total MB (store / fts) |
|------:|------:|------:|------:|------:|------:|------:|------:|------:|------:|
| 2,000 | 26.6 | 23.6 | 2.4 / 2.9 | 1.95 | 0.33 | 1.60 | 36.4 | 0.10 | 15.5 (12.2 / 3.4) |
| 4,000 | 27.9 | 24.3 | 4.8 / 5.1 | 0.42 | 0.32 | 1.57 | 28.0 | 0.20 | 25.9 (20.2 / 5.7) |
| 8,000 | 32.0 | 29.1 | 8.3 / 9.0 | 0.41 | 0.39 | 0.89 | 31.9 | 0.41 | 47.1 (37.9 / 11.5) |
| 16,000 | 53.8 | 47.3 | 18.6 / 20.5 | 0.88 | 0.70 | 1.09 | 48.1 | 1.01 | 90.5 (71.5 / 23.3) |

> "Reopen count ms" = time for the first `totalCount()` on a *fresh* container
> over the same on-disk data (cheap aggregate). "Reopen first-page ms" = first
> `summaryPage` on that fresh container (pays the same unindexed-sort cost as
> "First page"). They measure different operations, not a clean cold/warm pair.

**Correctness: PASS at every scale** — store count == distinct (dedup dropped
the 1% duplicate Message-IDs); FTS common-term count == distinct; paging
visited every row with no skips and no duplicates (incl. across the
same-timestamp block); rare-term, Boolean-AND, and `NEAR()` result sets matched
the known expected IDs exactly; delete was consistent across store + FTS;
reconcile rebuilt the entire index from the store after a full FTS clear;
reopen persisted the full corpus.

## Analysis — what scales and what does not

**PASS — memory is bounded (the decisive metric).**
Peak-import RSS is **flat at ~127–158 MB across an 8× scale range** (2K→16K),
with no upward trend. Post-import, reconcile, and search RSS are likewise flat.
The bounded-memory architecture (streamed batches + keyset paging + bounded
reconcile + no whole-archive `[RawEmail]`) **works**: archive size does not
determine resident memory for the engine's core workflows.

**PASS — index throughput is linear (O(N)).**
FTS5 `indexBatch` holds ~20–25K msg/s regardless of scale — constant per-doc
cost. FTS is not the bottleneck.

**PASS — reopen, count, rare/NEAR search stay fast.**
Fresh-container count reopen ~1 ms; count ~0.3–0.7 ms; rare-term and `NEAR()`
p95 sub-millisecond, flat.

**FAIL — import throughput is quadratic (O(N²)).**
Import time per doubling of scale: 2.2 → 7.6 → 32.2 → 133.3 s — each 2× of
scale ≈ **4× the time**. Throughput halves on every doubling (914 → 533 → 251 →
121 msg/s). **Root cause:** `EmailStore.insertBatch` performs a per-email dedup
fetch `#Predicate { $0.messageID == mid }`, and `StoredEmail.messageID` has **no
secondary index** (only `id` is `.unique`). Each insert therefore scans the
whole table → O(N) per insert → O(N²) overall. The contrast with the *flat*
index throughput (which touches the same rows without a messageID lookup)
isolates the dedup fetch as the cause.

**DEGRADING — keyset paging latency is linear (O(N) per page).**
First-page latency grows 26.6 → 53.8 ms over 2K→16K. **Root cause:**
`summaryPage` sorts/filters on `StoredEmail.date`, which is **not indexed**, so
each page pays an O(N) sort/scan instead of an O(log N) index seek.

**LINEAR (acceptable, bounded memory) — reconcile time.**
A full reconcile-verify pass is O(N) time (0.10 → 1.01 s over 2K→16K) at flat
memory — expected for a full page-walk that re-indexes nothing.

## Extrapolation to 100K / 1M

A literal 1M run was **not executed** because the measured O(N²) import makes it
infeasible, and running it would only re-confirm the curve at great cost:

| Scale | Projected import time (∝ N², from 16K = 133 s) | First-page latency (∝ N) |
|------:|------:|------:|
| 100,000 | ~87 minutes | ~0.3 s |
| 1,000,000 | ~144 hours | ~3.3 s |

Disk is linear (~4.5 KB/email store + ~1.5 KB/email FTS at 600B bodies):
~6 GB projected at 1M (higher with realistic multi-KB, externalized bodies).

**Conclusion:** the *architecture* (bounded memory, correct paging semantics,
linear FTS) is sound and proven. Two operations — **import (dedup)** and
**keyset paging** — do not scale, and both trace to the **same missing
secondary indexes** (`messageID`, `date`) that the current SwiftData
configuration on the deployment target cannot express. This is the input to
`V2_STORAGE_DECISION.md`.

## Reproduce

```
# Drop a config into the app container tmp (sandboxed host can't read shell env):
CFG=~/Library/Containers/com.ecosanskriti.mailin/Data/tmp/mailin_stress_config.txt
printf 'SCALES=2000,4000,8000,16000\nCONFIG=Debug\nBODY=600\n' > "$CFG"
xcodebuild test -project maxmailin.xcodeproj -scheme maxmailin -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:maxmailinTests/V2VerificationTests/testStressHarnessSweep
# Results JSON: ~/Library/Containers/com.ecosanskriti.mailin/Data/tmp/mailin_stress_results.json
```
