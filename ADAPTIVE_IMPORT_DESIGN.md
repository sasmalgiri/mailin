# Adaptive import design (3.0 §5 / P3)

## 2026-11-19 revision: RAM-aware import budgets (implemented, not benchmarked)

This revision supersedes the starting-budget and slow-commit rules below. It is a
performance correction to the existing adaptive importer, not a new archive engine.

On macOS, let `P` be installed RAM, `F` the current process footprint, and `A` a fresh
advisory sample of free + inactive VM pages (speculative pages are already in free;
compressed memory is not counted). Set:

```
reserve = max(512 MiB, P / 16)
process soft limit = min(P / 4, 8 GiB, F + max(0, A - reserve) / 2)
next batch resident allowance = min(1 GiB, limit / 4, max(0, limit - F) / 2)
next batch source-byte ceiling = allowance / 13
```

The existing 1 MiB progress floor still applies. The 13x expansion factor is the
historical measured MBOX factor, not a mathematical bound for every format. Individual
message decodes can exceed a batch budget. These limits are soft control thresholds,
not an allocation reservation or a guarantee against all memory pressure.

For a 16 GiB Mac with 512 MiB app footprint and 8 GiB advisory headroom, the limit is
4 GiB; the starting batch target is 512 MiB resident (~39 MiB source), with growth
up to 1 GiB resident (~79 MiB source). The main SQLite cache can use 512 MiB, mmap
256 MiB, and FTS caches 8 MiB each across at most 20 shards (160 MiB total). They
allocate on demand. Source size does not require loading the whole archive into RAM.
Small files do not allocate the entire cache allowance. Cache tiers fall as available
headroom falls, and pressure restores the 32 MiB / 64 MiB store fallback and 2 MiB
per-shard caches. Missing VM telemetry limits the process budget to at most 1 GiB.

iOS retains the small cache policy, uses a fresh `os_proc_available_memory()` sample,
reserves 256 MiB of that allowance and caps the process soft limit at 1 GiB or a
quarter of installed RAM, whichever is smaller. macOS budgets are not transferred
to iPhone/iPad merely because both devices have the same physical RAM.

Slow commits no longer repeatedly halve a healthy starting batch to eight messages.
They stop growth and undo growth above the starting envelope. Memory, thermal, disk
and index-backlog signals still shrink or pause. The store budget survives first-open
and reconnect, reduced caches release memory, and cleanup is awaited before import
returns. Normal spec-reader PST/OST batches now honor a live byte/count envelope.
Legacy PST array fallback and optional deep carving still materialize results; this
revision does not claim those paths or a single giant PST item are memory-bounded.

Validation: Swift grammar checks and `git diff --check` pass. Added
`ImportMemoryPolicyTests` (8) and `PSTAdaptiveMemoryTests` (2); adjusted the old
slow-commit expectation in `AdaptiveBatchControllerTests`. Swift/Xcode is unavailable
in the Linux editing environment, so compilation, these tests and speed/memory
measurements are NOT RUN. No speedup is claimed. Before merging, run on macOS:

```
swift test --package-path Packages/ArchiveCore --filter 'ImportMemoryPolicyTests|PSTAdaptiveMemoryTests|SearchChunkRunTests'
```

Also run the app's `AdaptiveBatchControllerTests` and `ImportMemoryBudgetTests` using
the existing focused test workflow. Compare Release app imports at base `e918bb0`
and this candidate on the owner's 16 GiB Mac: 213 MB / 56,699-message Enron MBOX,
1 GiB attachment-heavy MBOX, and real PST. Use both empty and existing large archives;
record first-visible, imported, fully indexed, peak footprint, swap/pressure, batch
counts and disk growth. Exercise low headroom, cancellation and restart; verify counts,
folders and exports. Use the same free disk space and app feature switches in A/B runs.

References: Apple's `os_proc_available_memory` documentation and XNU
`osfmk/mach/vm_statistics.h`; available-memory estimates are advisory and do not
justify filling all RAM.

## Historical design and measurements

The import pipeline bounds every batch by **message count and parsed bytes**, grows only while
every health signal is good, shrinks on the first bad one, pauses with a user-readable reason at a
hard limit, and never lets one oversized message break the envelope. Written 2026-09-27; numbers
are the measured ones in `RELEASE_READINESS.md` and `SCALE_RESULTS.md`, not targets.

## 1. Components and where they live

| Piece | File | Role |
|---|---|---|
| `BatchEnvelope` | `AdaptiveBatchController.swift` | `maxMessages` × `maxBytes`; the starting envelope is derived from physical RAM (1.5 %, clamped 96–512 MiB resident) through the **measured** parsed-expansion factor ×13 |
| `PressureSample` | same | footprint vs budget, OS memory pressure, free disk vs reserve, thermal state, last commit time, index backlog |
| `AdaptiveBatchController` | same | `next(after:sample:)` → `.proceed(envelope)` or `.pause(reason)`; trace of every transition, bounded |
| `LivePressureSampler` | same | builds a sample from the running system |
| `BulkImportCoordinator.nextEnvelope` | `BulkImportCoordinator.swift` | asked by the parser at every batch boundary; blocks (with the reason exposed as `pauseReason`) while the controller says pause; resumes on its own |
| Parsers | `MBOXParser`, `OffsetImportEngine`, `ParserFactory` chunk path | honour `envelopeProvider` at each boundary — MBOX/EML/EMLX/Maildir/Apple Mail natively, PST/OST/NSF/MSG through the generic chunk limit |
| User pause / stop | `BulkImportCoordinator.pause/resume/skipCurrentSource` | held at the same boundary as the pressure pause, so committed rows always equal the checkpoint |
| Volume gate | `BulkImportCoordinator.waitForStoreVolume` | no batch starts against an archive directory that is unreachable (external disk detached, image ejected) |
| Checkpoints | `ImportCheckpointStore` (schema v17) | the mid-file ordinal commits inside the insert transaction; identity = SHA-256 + size + parser + parser version + schema; a mismatch restarts the file |
| Storage preflight | `StoragePlanner`, `GuidedImportSheet` | refuses before start when the requirement does not fit; coefficients measured (store ≈ 1.08× source, FTS ≈ 0.03× on the attachment-heavy fixture; the sheet quotes 1.3× / 0.2× as its conservative planning figures) |

## 2. Batch cycle

1. Parser asks for an envelope → controller samples pressure → `.proceed` or `.pause`.
2. Parser fills the envelope (count or bytes, whichever first). An item larger than the whole
   envelope is spooled alone (`OversizedItemPlan.spoolAlone`), never inlined and never used to grow
   the envelope.
3. `persistBatch`: user-pause gate → volume gate → dedup + insert inside one transaction with the
   checkpoint ordinal → FTS index (degraded mode counted, never fatal) → locators (offset engine) →
   live stats (messages, bytes, indexed) → optional "stop this source" after the commit.
4. Outcome (messages, bytes, commit seconds) feeds the next decision.

## 3. Decisions and reasons

| Signal | Decision | Reason shown |
|---|---|---|
| memory pressure critical | pause | "memory pressure is critical" |
| free disk ≤ reserve | pause | "disk space is too low to continue safely" (with bytes) |
| free disk ≤ 2× reserve | shrink | "disk space running low" |
| footprint ≥ ¾ budget or pressure warning | shrink | — |
| slow commit | shrink | — |
| index backlog / thermal serious | shrink | — |
| all healthy for N consecutive batches | grow (capped) | — |
| user Pause | hold | "Paused by you" |
| archive volume unreachable | hold | "Archive volume detached — reconnect … to continue" |

## 4. Recovery

| Event | What happens | Where proven |
|---|---|---|
| Force-quit mid-file | relaunch → import the same file → resumes at the checkpoint ordinal (identity-verified) | `StoreBackedCheckpointTests`; `DiskImageFaultTests` (J-3) |
| ENOSPC | controller pauses before the wall; if it hits anyway, the persist failure is per file, counted, and the checkpoint stays at the last commit | `DiskImageFaultTests` (J-3) |
| Volume ejected | pause with reason; resume when reattached; cancel keeps checkpoints | manual row in J-3 |
| FTS commit fails | store row kept, `ftsDegraded` counted, launch reconciler repairs | `FTSReconciler`, receipt |

## 5. Measured so far

| Run | Result |
|---|---|
| 90 MB real fixture, fixed 500 | 2 batches, +400 MiB peak (the reason the controller exists) |
| same, adaptive | > 2 batches, peak bounded (see `RELEASE_READINESS.md` §P0.2) |
| 1.52 GB real-content fixture, production path | 15 batches, 1.3 MiB/s, peak Δ 790 MiB streaming / 452 MiB offset engine, exact counts (`SCALE_RESULTS.md`) |

## 6. Open

Per-format expansion factors (PST/NSF differ from MBOX) and the growth ceiling are P9 work and need
the larger corpora the owner has not yet supplied. Until then the numbers above are the envelope.
