# V2 Storage Decision

**Status: DECISION REQUIRES ONE PRODUCT INPUT (deployment target).**
Evidence is complete and unambiguous about *what fails*; the choice between the
two remedies hinges on whether Mailin must keep supporting macOS 14 / iOS 17.

See `V2_SCALE_RESULTS.md` for the measurements this rests on.

## What the harness proved

| Property | Result |
|---|---|
| Correctness (dedup, paging, search, Boolean, `NEAR`, delete, reconcile, reopen) | ✅ PASS at every scale |
| **Resident memory bounded as archive grows** (the decisive metric) | ✅ PASS — flat ~127–158 MB across 8× scale |
| FTS5 index throughput | ✅ PASS — linear (~20–25K msg/s, flat) |
| Reopen / count / rare / `NEAR` latency | ✅ PASS — ~1 ms, flat |
| **Import throughput** | ❌ FAIL — **O(N²)**; 1M ≈ 144 h (infeasible) |
| **Keyset paging latency** | ⚠️ DEGRADING — **O(N) per page**; ~3.3 s/page at 1M |

The bounded-memory **architecture is sound** — and it lives behind
`EmailRepository`, so it survives any storage swap. The two failures are **not**
architectural; they are a **storage-configuration** problem.

## Single root cause

Both failures are missing **secondary indexes**:

- Import: the per-email dedup fetch on `StoredEmail.messageID` scans the whole
  table because `messageID` is **not indexed** (only `id` is `.unique`).
- Paging: `summaryPage` sorts/filters on `StoredEmail.date`, which is **not
  indexed**, so every page is an O(N) sort instead of an O(log N) seek.

**Why the current SwiftData config can't just add them:** the deployment target
is macOS 14.6 / iOS 17.6. SwiftData's secondary-index macro `#Index` requires
**macOS 15 / iOS 18**. The only index primitive available on 17.6 is
`@Attribute(.unique)`, which is unsafe here: `messageID` is optional, and a
unique constraint over NULLs (plus SwiftData's upsert-on-conflict) risks
collapsing or replacing distinct no-Message-ID emails — data loss. So on the
shipping target, SwiftData **cannot express the indexes the engine needs.**

## The two remedies

### Option A — KEEP SwiftData, raise deployment target to macOS 15 / iOS 18
Add `#Index([\.messageID])` and `#Index([\.date, \.id])` (schema V2 +
migration), then re-run the harness.
- **Pros:** smallest change; keeps all SwiftData integration; both failures are
  directly addressed by the missing indexes.
- **Cons:** **drops macOS 14 / iOS 17 users** (a product/market decision, not an
  engineering one); still bound to SwiftData's query/migration behavior at
  scale (unverified above 16K).

### Option B — REPLACE the store with direct SQLite/blob behind `EmailRepository`
Port `EmailStore` to a direct-SQLite engine (bodies as blobs / external files)
with explicit `CREATE INDEX` on `message_id` and `(date, id)`; keep the exact
`EmailRepository` contract; re-run the **same** 10K→100K→1M harness.
- **Pros:** keeps macOS 14.6 / iOS 17.6 support; full control over indexes,
  pragmas, WAL, and batching; the app **already runs direct SQLite successfully
  for FTS5** (`FTSSearchIndex`), so the competency and pattern exist; the
  repository boundary was built for exactly this swap — **no UI rewrite**.
- **Cons:** larger implementation effort; needs a v1/SwiftData → SQLite device
  migration path and its own correctness tests.

## Recommendation

**Option B (direct SQLite behind `EmailRepository`)**, unless dropping
macOS 14 / iOS 17 is already acceptable — in which case **Option A** is the
faster route to the same scaling fix.

Rationale for leaning B: it preserves the current OS support matrix, it removes
the SwiftData scale unknowns above 16K entirely, the codebase already proves
direct-SQLite competence in `FTSSearchIndex`, and the `EmailRepository` boundary
(Stage 3) exists precisely so this swap touches **zero** UI. The measured
bounded-memory architecture is retained either way.

## Why this is paused for input (per the execution directive)

The directive said to continue automatically **unless the measurements are
genuinely ambiguous or uncover a new architectural failure.** They uncovered a
new one: a deployment-target-bound index limitation with **two legitimate
remedies whose choice depends on a product call** (keep iOS 17 support or not)
that the original "SwiftData fails → replace" framing did not consider. Porting
a whole storage engine (B) vs. raising the OS floor (A) is not a decision to
make silently. One bit of input picks the path; then execution resumes
automatically (schema/engine change → re-run harness → storage decision
finalized → Stage 5).

## Not-yet-measured (fold into whichever path is chosen)

- Realistic multi-KB bodies that actually exercise external/blob storage
  (harness used 600 B; `externalStorageBytes = 0`).
- A completed 100K and 1M run on the fixed engine (the point of the re-run).
- Release-configuration absolute throughput (Debug numbers are a lower bound).
