# mailin v2 — Implementation Log (companion to V2_CLAIMS_AUDIT_AND_ACTION_PLAN.md)

Records what has actually been changed in the working tree. Every entry below **builds clean** (verified with BuildProject). Nothing committed — all changes are in the working tree for review.

## Corrections adopted from the "Final Action Plan"
1. **NSF crash line is `:444`/`:427`, not `:368`.** Slice created at `:368`; trap fires downstream. Fixed at source (`:368`).
2. **New finding — Info.plist ↔ landing-page contradiction** (IMAP `NSLocalNetworkUsageDescription`). Removed.
3. **Migration count-check must NOT be `stored >= legacyEmails.count`** — `insertBatch` dedupes by Message-ID, so real archives (duplicate Message-IDs across Gmail labels) would fail the guard and retry forever. Implemented as `stored >= 1` + a present-but-unreadable guard instead.

## Done (builds clean)

| Plan item | Change | Files |
|---|---|---|
| 0.1 Migration (R1) | Read real v1 store via `EmailPersistence.load()`; non-destructive; count-verified (`>= 1`); never marks-complete-on-read-failure; added `legacyStoreExists`; deleted wrong-path legacy readers | `MigrationService.swift`, `EmailPersistence.swift`, `EmailStore.swift` (+`count()`) |
| 0.2 Schema versioning | `MailinSchemaV1: VersionedSchema` + `EmailStoreMigrationPlan`; container built with migration plan | `EmailStore.swift` |
| 0.3 NSF crash | Wrapped slice in `Data(...)` → 0-based for `lzssDecompress`/`stripCompositeHeader` | `NSFParser.swift:368` |
| 0.4 ZIP (partial) | Extract all supported formats (mbox/eml/emlx/msg/pst/ost/nsf), zip-slip path guard | `ContentViewModel.swift` |
| **1.1 Route search → FTS5** | `ParsedEmailListViewModel.applyFilters` now resolves free-text + boolean queries via `FTSSearchIndex.search` (async, cached by query key), with `EmailSearchIndex` as synchronous fallback. Regex/proximity stay in-RAM by design. Empty FTS result → fall back (no blank-list regression). | `ParsedEmailListViewModel.swift` |
| 1.2 FTS operators | `escapeForFTS` now preserves AND/OR/NOT, quotes leaf terms only | `FTSSearchIndex.swift` |
| 1.3 FTS delete | Added `FTSSearchIndex.delete(id:)` (per-row delete across shards) | `FTSSearchIndex.swift` |
| 2.1 MSG crashes | `Int(compressedSize)+4` overflow guard; `Int(clamping:)` on 64-bit size; `collectTree` recursion → iterative (stack-overflow fix) | `MSGParser.swift` |
| 3.1 Forensic honesty | SPF/DKIM/DMARC copy relabeled from "Verify" → "as reported by the receiving server" (landing page + in-app threat/spoof/risk strings) | `docs/index.html`, `SecurityAnalysisFeatures.swift`, `ForensicManager.swift` |
| 4.2 Biometric (R4) | Wired `BiometricLockManager` + `BiometricLockView` into app root (topmost overlay when locked) + scene-phase handler. Face ID plist string is now legitimate. | `mailinApp.swift` |
| 4.1 AES (R3) | **Relabeled** (hybrid): dropped false "AES-256 encrypted storage" claim; states OS file protection | `README.md` |
| 4.4 PST export (R5) | **Relabeled** "experimental, not guaranteed to open in Outlook" / dropped from primary export list | `README.md`, `AppStoreMetadata.txt` |
| 4.3 iCloud (R7) | **Relabeled** — dropped "iCloud sync" (compiled out of shipping build) | `README.md` |
| plist | Removed misleading IMAP `NSLocalNetworkUsageDescription` | `Info.plist` |

## Deferred — with reason (need runtime testing or are business decisions)

| Plan item | Why deferred |
|---|---|
| ~~1.1 Route search UI → FTS5~~ | **DONE** (see above). Still wants a real in-app search run to confirm result parity vs the old in-RAM path. |
| 0.4 ZIP off-main + streaming | Format/zip-slip fixes are done; moving the whole-file read off `@MainActor` and streaming (the OOM part) needs call-site refactor + a large-zip test. |
| 2.2 size ceilings / 2.3 RecoveryReport | RecoveryReport threads through every parser + import UI (cross-cutting); needs its own pass + tests. |
| 3.3 S/MIME trust-chain/detached | Needs S/MIME test vectors to change verdict logic safely. |
| 3.4 store↔FTS atomicity / ENOSPC | Needs careful design + fault-injection tests. |
| 3.5 redaction content-strip verify | Needs a PDF text-extraction assertion test. |
| 3.2 real DKIM/DMARC crypto | Plan marks "later, L"; relabel (3.1) is the honest interim (done). |
| Full PST writer | Plan marks weeks/L; relabel (done) is the hybrid answer. |
| Migration **integration test** vs real v1 fixture | Build ≠ runtime-verified; still the top validation gap (Phase 5 §8.3). |

## Phase 1 review fixes (from code review of the rewire)
- **Fallback now gated on index population, not result count.** `FTSSearchIndex.rowCount() > 0` decides authoritative-vs-fallback. An empty result from a populated index = authoritative zero matches (no O(N) in-RAM scan); empty because nothing is indexed = fall back. Fixes the perf regression + non-deterministic semantics on the no-match seam.
- **Prefix match on the last term** (`"budg"*` → matches "budget") in `escapeForFTS`, so partial words match inside FTS5 — removes the main reason a substring fallback was needed.
- **Cache keyed by `query + allEmails.count`** so import/delete invalidate it. Single-slot cache (one Set), bounded by construction. Deletes are also excluded by the downstream `deletedIDs` filter regardless.

### Phase 1 review fixes — round 2 (shard-granularity + cache-version + migration count)
- **Search disabled against a half-built index.** FTS now engages only when `!isParsing` (VM's own parse flag); during import the in-RAM engine (parsed-so-far set) serves search. Removes the shard-partial race (global `rowCount()>0` couldn't tell "2019 indexed, 2023 not"). *Residual:* the brief post-parse / pre-`indexBatch` window isn't covered by `isParsing` — needs an explicit "FTS indexing complete" flag to fully close; logged below.
- **Cache key now tracks mutations, not cardinality.** Added `corpusVersion` (bumped by `invalidateSearchCache()`), folded into the key alongside `allEmails.count`. Redaction/reindex must call `invalidateSearchCache()` when wired (3.x).
- **Migration completion gate strengthened** from `stored >= 1` to `stored >= (distinct Message-IDs + no-MID count)` — meaningful verification that accounts for dedup; a Gmail export with duplicate Message-IDs legitimately lands fewer rows and still passes (no retry-forever), but a real shortfall now fails and retries.

### Known limitations to log (not regressions)
- **Post-parse indexing window** — `isParsing` covers the parse but not the trailing `FTSSearchIndex.indexBatch`; a search fired in that sub-second gap can fall back to in-RAM. Close with an explicit "indexing complete" flag if it matters.
- **Proximity (NEAR) still in-RAM** — has an FTS5 form (`NEAR(a b, n)`) but escaping needs a raw-query path; until then proximity hits the corpus-resident wall. Don't let the landing page imply proximity is fast at scale.
- **Regex is in-RAM by nature** (no FTS5 regex) — relabel as "regex matches loaded messages" for huge archives.
- **Redaction-content cache staleness** — count-keyed cache doesn't catch a redaction that changes content without changing count; resolved once redaction calls `FTSSearchIndex.delete(id:)`+reindex (tied to the 3.x integrity work).

## Test infrastructure — hooks staged (builds clean; NOT yet a regression net)
The `#if DEBUG` hooks the 2a/2b tests depend on are landed and compiling. **This is the source half only** — proven to compile, *not* proven to work. The regression net does not exist until 2a/2b actually run red-then-green against these hooks, which needs a Unit Testing Bundle added to the `maxmailin` scheme in Xcode (there is currently no test target — the `maxmailin` test plan has 0 tests).
- `EmailPersistence.testBaseDirectoryOverride` — isolate the v1 store to a temp dir.
- `EmailStore.testInMemory` + `resetForTesting()` — in-memory store, no real-store pollution.
- `FTSSearchIndex.debugSearchCallCount` + `resetDebugSearchCallCount()` — observe the FTS dispatch (2a). Reset immediately before the observed `applyFilters()`, assert `== 1`.
- `ParsedEmailListViewModel.lastFTSSearchTask` — retained handle so 2a awaits the async FTS pass deterministically (no poll).

**Test target created + tests written + compiling (via `xcodeproj` gem, no hand-edited pbxproj):**
- `maxmailinTests` unit-test target added to `maxmailin.xcodeproj`, wired into the `maxmailin` scheme test action. `ENABLE_HARDENED_RUNTIME=NO` for Debug (needed for test-bundle injection).
- `maxmailinTests/V2VerificationTests.swift` — **2b** `testMigrationFromRealV1Store` (temp-dir v1 store, 100 rows / **90 distinct MIDs hardcoded**, in-memory EmailStore, asserts `stored ≥ 90`) and **2a** `testLiveSearchDispatchesToFTS` (populate FTS → reset counter → `applyFilters()` → `await lastFTSSearchTask?.value` → assert `debugSearchCallCount == 1`). Both **compile** (confirmed: `GetTestList` enumerates them, which requires a successful build-for-testing).

**RUN AND VERIFIED — red-then-green demonstrated (`RunSomeTests`).**
- Correction: my earlier "compiles (GetTestList enumerates)" claim was wrong — `GetTestList` used a stale index build; the fresh test build caught a missing `timestamp:` arg in the fixture (`RawEmail.init`), now fixed.
- Both tests **PASS** green.
- **2b red-then-green:** forced the R1 regression (empty legacy load) → failed with `XCTAssertGreaterThanOrEqual failed: ("0") is less than ("90") — MIGRATION S < E — data loss: stored=0 < expected=90` (the exact `S < E` signature, not a throw/crash) → reverted → green.
- **2a red-then-green:** stubbed the `FTSSearchIndex.search` dispatch out of `applyFilters` → failed with `XCTAssertEqual failed: ("0") is not equal to ("1") — live search must dispatch to FTS exactly once (got 0)` (clean counter `0`, not a timeout/hang) → reverted → green.
- (Note: the earlier "No result" on the first two run attempts resolved on retry — the host app now launches in this environment.)

So R1 (migration) and R2 (search→FTS5) now have a **real, executed regression net** — each proven to fail on its specific regression before passing.

## Business decisions (not code — need owner sign-off)
- **"Now live on the App Store"** copy on `docs/index.html` — leave or change depends on actual release state (only the owner knows).
- **Pricing drift** — landing page vs `AppStoreMetadata.txt` differ; correct numbers are a business call, not an engineering one.
- **App Store Connect metadata** — the iCloud/PST/verify relabels also need to be applied in App Store Connect itself (the `.txt` is documentation only).
