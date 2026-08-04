# mailin v2 — Runtime Smoke Test (run before 3.3/3.4)

Verifies the two highest-blast-radius behavioral changes — **migration (R1)** and **search→FTS5 (R2)** — that a green build cannot prove. Run on a real device/build with a populated v1 archive. Nothing here is a regression test yet (that's Phase 5); this is the manual gate before proceeding.

---

## A. Migration (data loss — test hardest)

Watch the os.log line (subsystem `com.ecosanskriti.mailin`, category `Migration`):
`Migration complete: N legacy emails; expected E after dedup; store now holds S.`

### A1. Count verification — **directional, not "close enough"**
Compare `store now holds S` against `expected E`:

| Outcome | Verdict |
|---|---|
| **S == E** | ✅ PASS (clean) |
| **S > E** | ✅ ACCEPTABLE — benign within-chunk duplicate that slipped the pre-save dedup; no data lost |
| **S < E**, even by 1 | 🛑 **STOP AND INVESTIGATE** — real messages didn't land (data loss). Do **not** wave through. |

Rationale: dedup counts on both sides use the **raw `Message-ID`** (no trim/case/bracket normalization), so `E` and `S` are computed by the same rule. A shortfall is never benign.

### A2. Non-destructive
After migration, the original v1 store is still on disk, untouched:
`~/Library/Application Support/mailin/saved_emails.json` (or `.json.lz`).

### A3. Crash-resume
Kill the app mid-migration → relaunch → it retries and completes (the completion flag is only set inside the success block, after the count gate passes).

### A4. Idempotency (everyday second-launch path)
Relaunch after a **successful** migration → it does **not** re-import (no second pass appending). Status should be `.skipped`.

### Failure → diagnosis map
- **A1 low (S < E)** → dedup rule or insert path, **not** the gate. Open `EmailStore.insertBatch` / `MigrationService` pre-count.
- **A2 v1 files gone** → the non-destructive change didn't take. Confirm `archiveLegacyAsBackup` is gone from the flow (`MigrationService`).
- **A3 no retry after mid-kill** → completion flag being set outside the success block. Check `performMigration` — flag must not be set on the `.failed`/guard paths.
- **A4 re-imports on second launch** → flag not read on launch or `hasMigrated` wired wrong. Check `migrateIfNeeded` / `completionKey`.

---

## B. Search → FTS5 (parity + async refresh)

Diff FTS vs the old in-RAM path on representative queries. The critical one is B-refresh.

| Query | Expect |
|---|---|
| `running` (bodies contain only `run`) | **B-refresh:** list flips **empty → populated** when the async FTS task lands. In-RAM substring returns nothing; FTS (porter stem + `"running"*` prefix → `run*`) matches. If it stays empty → missing `@Published` refresh after the Task calls `applyFilters()` — the one unverified seam. |
| `budg` | matches `budget` **from FTS** (prefix `"budg"*`), not from the substring fallback |
| `a AND b` | real boolean AND (not a literal phrase) |
| empty-result query on a **populated** index | zero results **without** dropping into the slow in-RAM fallback (population gate, not result-count) |
| post-**redact** (not post-delete) | *Defer:* only a real test once redaction calls `invalidateSearchCache()` + FTS reindex (3.x). Post-delete is doubly-safe (count changes + `deletedIDs` filter) so it proves little. |

Note: search is intentionally served by the **in-RAM** engine while `isParsing` is true (index builds incrementally); FTS engages once import completes. A search fired in the brief post-parse/pre-`indexBatch` window may fall back — known residual.

---

## Pass criteria to proceed to 3.3/3.4
Migration: **A1 S ≥ E** (equal or higher, never lower), A2 v1 files present, A3 retries-then-completes, A4 no re-import.
Search: **B-refresh** visibly repopulates on `running`/`run`.

If all green, migration + search are verified. If anything breaks, capture the exact log line / behavior and hand it back with the failure-map pointer — go straight at that seam, no full re-review.
