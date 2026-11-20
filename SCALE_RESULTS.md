# Scale results (supersedes `V2_SCALE_RESULTS.md` for the 3.0 line)

Every row states its fixture, its host and its build configuration. A row
that was not executed says **NOT TESTED**. Nothing here is extrapolated.

## Host

- MacBook Air, Apple silicon, macOS 27.0, Xcode test host (the app itself).
- **Debug configuration** for every row below. Debug numbers are a lower
  bound on throughput, not a claim about the shipping build.
- Volume: 228 GiB, 21–27 GiB free during the runs.

## Fixtures

| Name | What it is | Size | Messages |
|---|---|---|---|
| `~/Downloads/Mail/Sent.mbox` | the owner's REAL mailbox: CRLF, attachment-heavy (~173 KB/message) | 95.4 MB | 526 |
| `~/Downloads/Mail/Scale/Sent-x16.mbox` | **real content, synthetic replication**: `Sent.mbox` written 16 times by `make_scale_fixture.py` (beside it), changing only Message-ID (`.cN` suffix) and Date (+37 days per copy). Bodies, MIME, attachments and line endings are the real bytes | 1,518,669,686 B (1.52 GB) | 8,416 |
| `~/Downloads/Mail/Scale/Sent-x16.zip` | the file above inside a stored (method 0) ZIP | 1,518,669,862 B | 8,416 |

The replication is labelled as such wherever these numbers are quoted: it
exercises byte volume, attachment decoding, FTS sharding across years and
the store at 1.5 GB, but its vocabulary and sender population are those of
one mailbox.

## Executed 2026-10-12 — every Legal (L) tool at 100,000 emails (§4 gate 5)

`V3ScaleTests.testScaleTier_everyToolAnswersExactly_memoryFlat`, Debug, on this Mac, synthetic archive
with planted rates. Every answer equals the arithmetic expectation; memory growth stays under the 700 MB
ceiling; the run now also fails any tool slower than 120 s per 100,000 emails.

| Tool | Seconds | Peak growth (MB) |
|---|---|---|
| E-Discovery search | 12.7 | 0 |
| NLP classification | 15.5 | 0 |
| Review batches (plan) | 20.8 | 8 |
| Verify & seal | 30.7 | 2 |
| Load file (Concordance DAT) | 15.7 | 0 |
| Legal hold / release | 24.3 / 2.0 | 261 / 0 |
| Legal hold straight into the database (F4, one call) | 0.7 | 11 |
| Custodians (assign all) | 0.2 | 0 |
| Privilege scan | 16.6 | 0 |
| Automation rules | 11.0 | 27 |
| Batch tag | 0.9 | 5 |
| Investigation report | 41.9 | 1 |
| PII report | 19.7 | 1 |
| IOC extractor | 18.5 | 1 |
| Keyword sweep | 11.6 | 8 |
| Exact duplicates | 29.3 | 32 |
| Bates numbering | 1.2 | 35 |
| Fingerprint tree | 5.0 | 27 |
| IT stats | 11.5 | 0 |

Found and fixed by this run (the first run took over an hour):

- **Custodians ▸ Assign to all: 3,691 s → 0.2 s.** With the legal-data engine off, the archive-wide assign
  set each email's custodian one by one, and each write rewrote the whole custodian file (quadratic). Every
  bulk custodian and legal-hold path now writes once.
- **Verify & seal: 317 s → 30.7 s; legal hold 67 s → 24 s.** Each batch re-published the forensic caches
  (the hash cache once, the tag/annotation caches three times through an `inout` trim that changed
  nothing), and every publish redrew every screen observing the forensic manager — the job's time was
  main-thread redraws, not work. The hash cache now notifies at most once a second (with a trailing
  notice), and the trims run only when a cache is over its cap.

## Executed 2026-10-11 — 3.0 whole-archive engines at 1,000,000 emails (V1)

Test: `V3ScaleTests.testScaleTier_everyToolAnswersExactly_memoryFlat`, `MAILIN_SCALE_TIER=1m`, Debug,
app-hosted, nothing else running. A synthetic archive of 1,000,000 emails is generated batch by batch with
known answers; every tool's result must equal the SQL count, and footprint growth must stay under 700 MB.
Result: **TEST SUCCEEDED** (the 100k tier passes in every full run).

| Tool | Wall | Peak footprint growth |
|---|---|---|
| insert 1,000,000 | — | 176 MB |
| count | 0.2 s | 0 MB |
| sender filter | 0.4 s | 11 MB |
| keyword sweep (FTS, whole archive) | 209.8 s | 369 MB |
| PII report (every email) | 292.1 s | 130 MB |
| IT stats (every email) | 279.7 s | 130 MB |
| Bates numbering (every email) | 70.0 s | 152 MB |
| fingerprint tree | 158.8 s | 141 MB |

An earlier run the same day failed only in the test: memory fell below its baseline and the unsigned growth
wrapped (fixed: growth clamps at 0); a second run hit SQLite "disk I/O error" while builds and the fault test
ran beside it on a near-full disk; this third run had the machine to itself.

Related rows executed the same day: disk full and drive unplugged mid-import
(`FaultVolumeTests`, package, on the 512 MB fault volume) — both pass: the import pauses with the named
reason and resumes exactly; Release build idle CPU 0.0 % over 60 s with the owner's archive (80 index
shards; footprint 731 MB, shards closed after idle eviction).

## Executed 2026-10-11 — import rows re-run on the 3.0 build (V2)

Debug, app-hosted, `MAILIN_SCALE=1`. Fixtures as in the 2026-09-26/27 sections (`Sent-x16.*` regenerated with
`make_scale_fixture.py`, identical sizes). Every row reconciles exactly (discovered = parsed = inserted = stored).

| Row | Result | Wall | Throughput |
|---|---|---|---|
| mbox 1.5 GB, streaming parser + export round trip | 8,416 / 0 dupes, PASS | 242.7 s (import 114.7 s) | 12.6 MiB/s · 73 msg/s |
| ZIP 1.5 GB (stored member) | 8,416 / 0, PASS | 129.2 s | 11.2 MiB/s · 65 msg/s |
| mbox 1.5 GB, **offset engine** (3.0 default) | 8,416 / 0 exact; memory check failed alone (+1.9 GB) → fixed (autorelease pools), now +755 MiB PASS | 438.2 s | 3.3 MiB/s · 19 msg/s |
| EML folder 1 GB | PASS | 107.3 s | — |
| Maildir 1 GB | PASS | 106.2 s | — |
| Apple Mail package 1 GB | PASS | 74.4 s | — |
| EMLX folder 1 GB | PASS | 85.2 s | — |
| gzip mbox 1 GB | PASS | 114.6 s | — |
| mixed four formats 1 GB | PASS | 88.4 s | — |
| message above the row ceiling (blob tier) | PASS | 8.5 s | — |

**Found and fixed — import memory (2026-10-11).** Run alone, the 1.5 GB offset-engine row peaked at
+1.85–1.97 GB over baseline (2026-09-26: +452 MiB). Bisection put it before the 3.0 work (present at 7230eea);
neither the parallel parse nor the batch size changed it. A heap sample showed a short early spike to 2.1 GB.
Cause: every chunked file read (`FileHandle.read(upToCount:)`) returns autoreleased storage, and the loops run
in background tasks with no autorelease pool draining between iterations — so the source digest, the offset
scanner, the mbox parser, blob writes, exports and signing all kept every chunk of the file until the task
ended. Fix: each chunk read inside `autoreleasepool` (11 loop sites). After: **peak +755 MiB, row PASSES**
(438.2 s). Regression test `testChunkedFileDigest_releasesEachChunk` (fails without the fix: +218 MB for a
192 MB file). Speed in Debug: streaming 12.6 MiB/s, offset 3.3 MiB/s (Release measured 86 MiB/s on 2026-09-28).

## Executed 2026-09-26 — 1.5 GB through the production import path

Path: `BulkImportCoordinator.runImport` over disposable storage (store +
FTS + v17 store-backed checkpoints), exactly the shipping pipeline minus the
UI. Test: `ScaleFixtureImportTests` — opt-in with `MAILIN_SCALE=1` in the test
environment (each run is 15–35 minutes); skips when the fixture is absent.

| Run | discovered / parsed / damaged | inserted / duplicates | stored = FTS rows | batches | wall | throughput | RSS baseline → peak → after | store / FTS on disk (ratio to source) |
|---|---|---|---|---|---|---|---|---|
| mbox, streaming parser | 8,416 / 8,416 / 0 | 8,416 / 0 | 8,416 | 15 | 1,095.9 s | 1.3 MiB/s · 8 msg/s | 93 → 883 → 839 MiB (peak Δ 790) | 1,640,820,870 / 39,305,216 B (1.080 / 0.026, total 1.106) |
| mbox, **offset engine** (S4, `useOffsetEngine`) | 8,416 / 8,416 / 0 | 8,416 / 0 | 8,416 | 15 | 1,141.3 s | 1.3 MiB/s · 7 msg/s | 1,175 → 1,627 → 1,061 MiB (peak Δ 452) | 1,641,128,934 / 39,301,120 B (1.081 / 0.026) |
| **ZIP** (stored member), container path | 8,416 / 8,416 / 0 | 8,416 / 0 | 8,416 | 15 | 886.7 s | 1.6 MiB/s · 9 msg/s | 97 → 794 → 707 MiB (peak Δ 697) | 1,640,833,158 / 39,301,120 B (1.080 / 0.026) |

Export round trip after the streaming run: `exportMBOXArchive` over the
whole archive wrote **8,416 records, 1,518,972,059 bytes in 17.5 s**
(SHA-256 `7c6aef7c…39c85`); re-parsing that file returned **8,416 messages, 0
failed**. Every message that went in came back out.

### What the numbers say

- **Correctness at 1.5 GB holds.** Discovered = parsed, zero damaged, zero
  persist failures, store count = FTS count, dedup kept every distinct copy,
  export round trip exact. The ZIP path verified 1.5 GB of CRC-32 on the way
  in and reached the same counts.
- **Throughput is the finding: 1.3–1.6 MiB/s in Debug**, consistent with the
  91 MiB baseline (44.6 s ≈ 2 MiB/s). At this rate 200 GB would take about
  40 hours. Re-parsing the exported 1.5 GB took as long as importing it
  (the round-trip test ran 2,117 s in total, of which import was 1,096 s and
  export 17.5 s), so the time is in **parsing**, not in SQLite or FTS. This
  is the plan's P3.5 item ("per-message parse churn": full-string joins,
  String-based MIME walk, attachment decode) measured at scale.
- **The offset engine is not faster here** (1,141 s vs 1,096 s). It removes
  the line-by-line separator scan but every message still goes through the
  same MIME/body extraction and store path. Its benefit is the 100 MB
  per-message ceiling and byte-exact locators, not speed. Promoting it for
  throughput would be a false claim.
- **Memory does not scale with the file**: peak Δ 450–790 MiB for 1.5 GB in,
  and the "after" figure stays near the peak because freed buffers stay in
  the allocator (the same high-water behaviour measured for the offset
  scanner). The offset run's baseline of 1,175 MiB is that effect from the
  run before it in the same process, not a leak in the engine.
- **Storage growth is lower at this size than at 91 MiB**: store 1.08× the
  source (was 1.243×), FTS 0.026× (was 0.044×); fixed overheads amortise.

### Not tested

| Row | Status |
|---|---|
| Release-configuration throughput | NOT TESTED — needs the Release-safe in-app harness (plan A11) or a Release test build |
| 16 / 50 / 100 / 200 GB, 1 TB, mixed formats | NOT TESTED — no corpus and no disk headroom on this Mac |
| PST / OST / NSF / MSG at any size | NOT TESTED — no real fixtures on this machine (see `RELEASE_NOTES_2_1.md`) |
| Low-disk, external-volume disconnect, force-quit mid-import | NOT TESTED at this size |

## Executed 2026-09-27 — 3.0 Phase J-3: the 1 GB format matrix

Fixtures: `make_format_fixtures.py Sent.mbox ~/Downloads/Mail/Scale` — the
owner's real Sent.mbox replicated 11× (Message-ID `.cN` suffix, Date shifted)
into each container form under `~/Downloads/Mail/Scale/formats/`. Every row
is 5,786 real messages (≈1.04 GB) unless stated; the mixed row is four
disjoint quarters. Path: `ProductionImportRun` → `BulkImportCoordinator`
(offset engine + locators for line-structured sources, `ParserFactory` for
directory forms) into disposable storage, Debug configuration, this Mac
(21 GiB free, other suites running earlier in the same process for some rows,
which is what the RSS baseline shows). Test: `FormatMatrixScaleTests`
(`MAILIN_SCALE=1`).

Two production defects were found by these rows before any number could be
recorded, both fixed the same day (commit b06edb8 and its follow-up):
`BulkImportCoordinator` hashed every source through a file handle, so a
folder source (EML folder, Maildir, Apple Mail package, EMLX folder) failed
before parsing with "the file doesn't exist" and produced ZERO messages — no
folder import through the production path had ever worked; and the PST
parser read zero messages from every real PST (B-tree pages by `ptype`
instead of `cLevel`, private block-page types, no `bCryptMethod` decoding for
PST files).

| Row | discovered / parsed / damaged | inserted / duplicates | stored = FTS rows | wall | throughput | RSS baseline → after |
|---|---|---|---|---|---|---|
| gzip (`mbox-1gb.mbox.gz`, 739,584,855 B compressed → 1.04 GB) | 5,786 / 5,786 / 0 | 5,786 / 0 | 5,786 | 762.9 s | 1.3 MiB/s · 7.6 msg/s | 192 → 759 MiB |
| Apple Mail package (`applemail-1gb.mbox/`) | 5,786 / 5,786 / 0 | 5,786 / 0 | 5,786 | 549.1 s | 1.8 MiB/s · 10.5 msg/s | 153 → 814 MiB |
| EML folder (5,786 files) | 5,786 / 5,786 / 0 | 5,786 / 0 | 5,786 | 1,850.3 s | 0.54 MiB/s · 3.1 msg/s | 814 → 514 MiB |
| EMLX folder (5,786 files, `EMLXParser` batch path) | 5,786 / 5,786 / 0 | 5,786 / 0 | 5,786 | 740.0 s | 1.35 MiB/s · 7.8 msg/s | 514 → 830 MiB |
| Maildir (`cur/`, 5,786 files) | 5,786 / 5,786 / 0 | 5,786 / 0 | 5,786 | 1,844.6 s | 0.54 MiB/s · 3.1 msg/s | 829 → 354 MiB |
| mixed: mbox + EML folder + ZIP + Maildir, disjoint IDs (4,208 msgs, 759,198,114 B) | 4,208 / 4,208 / 0 | 4,208 / **0 duplicates** | 4,208 | 951.0 s | 0.76 MiB/s · 4.4 msg/s | 354 → 520 MiB |
| **1.1 GB single message** (`LargeMessageBlobTests`: one 1,153,445,255-byte mbox record, base64 attachment above SQLite's 1 GB row ceiling) | 1 / 1 / 0 (header-only import, `bodiesNotDecoded` 1, locator recorded) | 1 / 0 | 1 | import 6.7 s | — | — |

The 1.1 GB row's export: `exportMBOXArchive` wrote **1 record, 1,153,445,255
bytes — exactly the fixture's size** — by streaming the located bytes from
the source in 1 MiB chunks (`MBOXStreamingExport`). The first pass wrote a
427-byte headers-only stub, because the exporter had no path for a message
whose bytes are located rather than stored; that was the missing half of the
S3b/S5 claim and is now executed.

### Fault injection on a disk image (B-2 / B-5) — executed 2026-09-27

`fault_volume.sh create 512m && attach` → a 512 MiB APFS image at
`/Volumes/MailinFault`. Run UNSANDBOXED as the package test
`FaultVolumeTests` (`xcrun swift test --package-path Packages/ArchiveCore`):
the app-hosted test bundle inherits the app sandbox, which cannot write to
any mounted volume (FileManager reports the denial as a `DecodingError`).

| Row | What happened | Verdict |
|---|---|---|
| ENOSPC: 8 × Sent.mbox (760 MB of source, unique Message-IDs) into a store on the 512 MiB image, storage preflight OFF | The import committed **1,592 messages** (2,015 in an earlier pass), then the live disk guard paused it with the reason *"Paused: less than 134.2 MB of disk space is free, which the archive needs for the database, index and temporary files."* — 133,738,496 bytes were still free; the volume was never filled to the wall. The watchdog cancelled after 180 s as a user would; the run ended with `CancellationError` (a named outcome, not a clean completion); the store **reopened with 1,592 rows, FTS 1,592** — consistent | PASS |
| Unplug mid-import (at a batch boundary — the "unplug-before-write" the design guards): 2 × Sent.mbox into the image; after 319 messages the run is paused, the image is force-detached (`hdiutil detach -force`, what pulling the cable does), the run resumed, the image re-attached | Pause named **18.6 s** after the detach: *"Archive volume detached — reconnect … to continue"*. After the re-attach the run **finished by itself**: 1,051 inserted + 1 recorded duplicate = the 1,052 messages of both sources (copy 0 carries the fixture's own IDs; one message without a Message-ID is identical in both copies), `persistFailed` 0, no file errors, **FTS 1,051 = store 1,051** | PASS |

What the unplug row found before it passed: the handles opened before the
eject pointed at the OLD mount, so after the reconnect every write failed
with "disk I/O error" and one batch's index write was lost. The coordinator
now re-opens the store connection and the FTS shards when the volume returns,
and an insert or index write that fails while the directory is unreachable
waits for the volume and retries once (the v17 checkpoint rides the insert's
transaction, so the retry writes exactly the same rows).

**Known limit, stated plainly:** an unplug that lands DURING a SQLite write
terminates the process. WAL mode memory-maps the `-shm` index, and touching a
mapped page of a removed volume is a bus error the OS delivers as SIGBUS
(observed once in this row before the eject was moved to a batch boundary).
This is the same for any application whose database is on the removed disk.
What holds then is WAL recovery plus the v17 checkpoint on relaunch
(`ResumeTests`); it cannot be exercised in-process.

Two defects this row found before it could pass: `BulkImportCoordinator.cancel()`
cancelled only the `startImport` task, so a run started through `runImport`
(the production UI path wraps it in its own Task) parked in a pause loop could
never be stopped by the coordinator; and the live disk reserve was a flat
5 GiB with "healthy" at twice that, so any volume under 10 GiB — or any Mac
with less than 10 GiB free — could not import one message. The reserve is
now 1 % of the volume clamped to 128 MiB–2.5 GiB (healthy above twice that).

### What the numbers say so far

- **Every container form now reconciles exactly** (discovered = parsed,
  zero damaged, zero persist failures, store = FTS, dedup keeps every
  distinct copy).
- **Per-file sources are 3.4× slower than a single-file source of the same
  bytes** (EML folder 1,850 s vs package 549 s). The log shows why: 2,369
  "Evicted idle FTS shards under memory pressure" events during the EML row
  — each member file is a separate parse whose batch re-opens the year
  shards the previous member's eviction closed. That is an FTS import-mode
  tuning item (open-shard budget per SOURCE, not per member), recorded in
  the tracker as a 3.1 performance item, not a correctness one.
- Throughput in Debug is 1.3–1.8 MiB/s for single-file sources, in line with
  the 1.5 GB rows above.

## Executed 2026-09-28 — Release throughput, and where the time went

Test: `ImportThroughputTests` in the ArchiveCore package, run with
`swift test -c release` (the package carries `-enable-testing` in every
configuration, so the optimised build is measurable without the app). Same
file (the owner's real Sent.mbox, 94,915,160 B, 526 attachment-heavy
messages), same Mac, production coordinator into disposable storage.

| Build | Engine | Before | Fix 1 | Fix 2 | Fix 3 | Fixes 4–6 | Speed-up |
|---|---|---|---|---|---|---|---|
| Release | offset engine (3.0 default) | 78.7 s · 1.15 MiB/s | 35.8 s | 16.8 s · 5.4 MiB/s | 2.4 s · 37 MiB/s | **1.0 s · 86.6 MiB/s · 503 msg/s** | **≈ 75×** |
| Release | streaming parser | 63.5 s · 1.43 MiB/s | 45.1 s | 10.0 s · 9.0 MiB/s | 3.2 s · 28 MiB/s | **2.3 s · 40 MiB/s · 233 msg/s** | **≈ 28×** |
| Debug | offset engine | 174.3 s · 0.52 MiB/s | — | — | — | — | — |

Counts were identical in every run (526 stored, 526 indexed, 0 damaged); the
handoff round trip stayed 526 of 526 byte-identical after every step; the
full unit suite (484 tests) was green after fix 3 and again after fixes 4–6,
and itself now runs in 4–6 minutes instead of 24.

- **Fix 3 — byte-level MIME split, compiled-once regexes, byte-level
  quoted-printable.** `MIMEParser` split the whole message and every part
  with `components(separatedBy:)` (Foundation, UTF-16 bridged), rebuilt five
  `NSRegularExpression`s per part, and the quoted-printable decoder stepped
  Characters with `index(_:offsetBy:)`. All three are now one pass over
  UTF-8 (`ByteSplit`, static regexes, byte QP). 16.8 s → 2.4 s.
- **Fix 4 — parse on several cores.** The offset engine's scan (sequential
  I/O) and the store (one writer) stay serial; each batch's messages are
  parsed on up to `activeProcessorCount − 1` (≤ 8) cores and put back in
  ordinal order, so checkpoints see the same sequence as before.
- **Fix 5 — no temp file per attachment during bulk import.** Every decoded
  attachment was written to the temp directory (a second copy of the whole
  mailbox's attachments, gone at relaunch); the import passes
  `materializeAttachments: false` and readers fall back to decoding from the
  stored message, as they do after a relaunch anyway.
- **Fix 6 — FTS import-mode shard cap 4 → 20**, so a per-file source no
  longer reopens the shards the previous file evicted (2,369 evictions in
  the EML-folder row → 146).
- Also: "is the body empty" is a byte scan instead of a whole-body
  `trimmingCharacters` through ICU.

### The 1 GB rows, re-run after the fixes (Debug, 2026-09-28)

| Row | Before (Debug) | After (Debug) | Speed-up |
|---|---|---|---|
| gzip | 762.9 s | 89.7 s | 8.5× |
| Apple Mail package | 549.1 s | 76.1 s | 7.2× |
| EML folder (5,786 files) | 1,850.3 s | 96.5 s | 19× |
| EMLX folder | 740.0 s | 55.3 s | 13× |
| Maildir | 1,844.6 s | 97.1 s | 19× |
| mixed four formats (4,208 msgs) | 951.0 s | 85.8 s | 11× |
| 1.1 GB single message (import + byte-exact export) | 6.7 s | 5.7 s | — |

Same counts, same reconciliation, same byte-exact export. These are Debug
figures because `xcodebuild test` builds Debug; the Release package test
above is the shipping-speed number. The folder penalty is now ≈ 1.3×
instead of 3.4×.

**The first finding was that Release was NOT faster than Debug** (1.15 vs the
1.3 MiB/s recorded above): the optimiser was not the problem, the algorithm
was. Sampling the import thread:

- **Fix 1 — 61 % of all import time was one line.** `AttachmentSaver` cleaned
  every base64 attachment body with
  `.filter { "ABC…+/=".contains($0) }`: for every Character of a
  multi-megabyte body, a linear scan of a 65-Character String, with
  grapheme-cluster semantics on both sides. Replaced by a one-pass byte
  table over UTF-8 (same result: stray boundary lines dropped, non-alphabet
  bytes skipped). A second Character-level whitespace filter before
  `Data(base64Encoded:)` was removed — the decoder ignores whitespace itself.
- **Fix 2 — every message was MIME-parsed twice.** `processRawMessage` parsed
  the tree for headers, then `EmailBodyExtractor.extractContents(from:)`
  parsed the same text again. The extractor now walks the parts it is given.
- SQLite and FTS5 did not appear in either profile. The store already does
  one transaction per batch with prepared statements, WAL and
  `synchronous = NORMAL`, which is what the literature recommends; there was
  nothing to gain there yet.

What remains in the profile after both fixes, in order: `MIMEParser`'s
Character-level splitting (`components(separatedBy:)`, `Substring.index
(offsetBy:)`, grapheme walks), the offset engine's per-message part scan and
locator writes (it is now slower than the streaming parser by that margin),
and one temp-file write per attachment during import. Those are the next
items, each an order of magnitude smaller than the two above.

### The table the owner asked for, restated with the measured Release rate

At 86 MiB/s (offset engine, Release, this MacBook Air, 95 MB real mailbox) —
and, more conservatively, at the ≈ 12 MiB/s the 1 GB rows reached in DEBUG:

| Source | Single file at 86 MiB/s (Release) | Single file at 12 MiB/s (Debug 1 GB rows) | Folder of files (≈ 1.3× slower) |
|---|---|---|---|
| 1 GB | ≈ 12 s | ≈ 1.5 min | ≈ 2 min |
| 10 GB | ≈ 2 min | ≈ 15 min | ≈ 20 min |
| 100 GB | ≈ 20 min | ≈ 2.5 h | ≈ 3.2 h |
| 200 GB | ≈ 40 min | ≈ 5 h | ≈ 6.5 h |

The true shipping figure lies between the two columns and will be set by
disk speed on the customer's Mac rather than by the parser once the source
is read faster than 86 MiB/s; nothing above 1.5 GB in one file has been
executed, and the claim wording ("verified up to 1.5 GB") stands.

## Executed 2026-11-06 — the format matrix at 100 MB (five jobs OPEN-06)

Owner's rule for this release (2026-11-05): every format is tested at about 100 MB; larger files are
covered by the bounded-memory design, and the documents say "tested at 100 MB; memory does not grow
with file size" — nothing more. `HundredMegabyteFormatMatrixTests.testFormatMatrix_100MB_…`, Debug test
host, this Mac. **Synthetic fixtures** (no real 100 MB corpus is on this Mac any more): a generated mbox
of 1,570 messages (~2 KB text + one 45 KB base64 PDF each, 97 senders, dates spread over six years),
imported through the production `BulkImportCoordinator`; that archive then exported with mailin's own
writers as PST, as a folder of .eml files and as .msg files, each imported into a fresh environment.
"First message" = time to the first committed batch. "Peak transient disk" = the largest growth of the
environment during the run beyond what was left on disk at the end (temporary files).

| Source | Size | Messages stored | First message | Total | Peak footprint over baseline | Store / FTS on disk | Peak transient disk | Reconciliation |
|---|---|---|---|---|---|---|---|---|
| mbox 100 MB | 100.1 MB | 1570 | 0.93 s | 13.6 s | 46 MB | 217.8 / 8.6 MB | 1.7 MB | discovered 1570, parsed 1570, damaged 0, persist failed 0, FTS rows 1570 |
| pst (mailin writer) | 86.1 MB | 1570 | 0.47 s | 6.2 s | 3 MB | 105.9 / 9.0 MB | 15.5 MB | discovered 1570, parsed 1570, damaged 0, persist failed 0, FTS rows 1570 |
| eml folder | 100.0 MB | 1570 | 0.26 s | 23.4 s | 5 MB | 118.2 / 78.6 MB | 21.1 MB | discovered 1570, parsed 1570, damaged 0, persist failed 0, FTS rows 1570 |
| msg files | 102.9 MB | 1570 | 0.02 s | 39.1 s | 0 MB | 106.5 / 12.8 MB | 43.3 MB | discovered 1570, parsed 1570, damaged 0, persist failed 0, FTS rows 1570 |
| mbox 25 MB | 25.0 MB | 393 | 0.84 s | 2.3 s | 5 MB | 55.1 / 2.2 MB | 1.7 MB | discovered 393, parsed 393, damaged 0, persist failed 0, FTS rows 393 |

What the rows show: every format stores every message with the search index at full coverage; four
times the bytes (25 MB → 100 MB mbox) moves the peak footprint from 5 MB to 46 MB over baseline, far
below the source — memory does not grow with file size. The eml-folder import leaves a larger FTS
footprint (78.6 MB) than the mbox import of the same mail (8.6 MB) because the per-file path indexes
the attachment text eagerly; a known shape, not a defect — the search coverage is identical.
**NOT TESTED at 100 MB:** OST and NSF (no fixture and no writer; the parsers are exercised by the
synthetic structure tests only), Apple Mail .emlx libraries and Maildir (no 100 MB fixture on this
Mac). Rows for those stay open until a fixture exists.

## Executed 2026-11-18 — the format matrix on a REAL corpus (gate 2)

**Dataset:** two CMU Enron custodians (enron_mail_20150507, fetched from cs.cmu.edu 2026-11-15 and
2026-11-18): kaminski-v + dasovich-j = **56,699 real messages, 210,180,300 bytes, 118 folders,
56,699 distinct Message-IDs**; counted by Python from the files, not by mailin. Built by
`Scripts/gate2_build_real_corpus.py` at `~/Downloads/Mail/Fixtures/real-corpus-enron/`: the
original files as a tree (hard links, bytes unchanged), `enron.mbox` (mboxrd: From_ line per
record, `^>*From ` quoted; 213,466,347 B, SHA-256 `6bc199db…5f0e`), `enron-maildir.zip` (deflated,
102,090,580 B, `cfe4e539…a9`) and `manifest.json` (`9951e762…df`). The CMU release carries no
attachments. **Build:** Debug; package rows `xcrun swift test` (CLI) — mbox / eml / search /
export on the working tree that became b515a69 (EML-envelope and PST-date fixes in), ZIP and PST
rows re-run on b515a69 (ZIP folder fix in); duplicate row Debug test host (RunSomeTests).
**Device:** MacBook Air, Apple silicon, macOS 27.0.1, 4–6 GB free on the volume during the runs.
The shipped app's switches were set as the app sets them (`v3PSTSpecWriter`,
`streamingBinaryParsers` on); everything else at package defaults.
`RealCorpusMatrixTests.testRealCorpus_matrix_*` (opt-in `MAILIN_REAL_CORPUS`).

| Source | Size | Messages stored | First message | Total | Peak footprint over baseline | Store / FTS on disk | Reconciliation |
|---|---|---|---|---|---|---|---|
| mbox (real, mboxrd) | 213.5 MB | 56699 | 0.81 s | 703.0 s | 66 MB | 701.4 / 299.9 MB | discovered 56699, parsed 56699, damaged 0, persist failed 0, FTS rows 56699 |
| eml folder tree (real files) | 210.2 MB | 56699 | 39.11 s | 1281.1 s | 119 MB | 715.7 / 301.0 MB | discovered 56699, parsed 56699, damaged 0, persist failed 0, FTS rows 56699 |
| zip of the tree (real files) | 102.1 MB | 56699 | 0.92 s | 1382.9 s | 31 MB | 716.6 / 296.4 MB | discovered 56699, parsed 56699, damaged 0, persist failed 0, FTS rows 56699 |
| pst (mailin spec writer, from the real archive) | 764.2 MB | 56699 | 2.38 s | 786.2 s | 56 MB | 789.8 / 298.9 MB | discovered 56699, parsed 56699, damaged 0, persist failed 0, FTS rows 56699 |

- **Counts:** source 56,699 = stored 56,699 = listed 56,699 = distinct Message-IDs 56,699 in every row.
- **Folders:** eml tree 118 of 118 and ZIP 118 of 118 folders, each with exactly the file count of
  its source directory; 0 folders that are not in the source.
- **Search** (folder-tree archive; expected = every message whose subject or CTE-decoded body
  contains the phrase, Python regex): "Black-Scholes" 145/145, California 10,189 (mailin 10,248),
  Dabhol 534/534, Duffie 228 (292), FERC 3,475 (3,489), "PG&E" 3,149 (3,171), "Stinson Gibner"
  2,327 (4,059), "Vince Kaminski" 2,971 (24,167), Wharton 876 (964), "real options" 622 (1,464),
  "value at risk" 212 (1,508), "weather derivatives" 471 (611) — **0 expected messages missing**
  for every phrase; mailin's larger counts come from header fields (To/X-To/X-From names), which
  the independent scan does not read. (The first oracle read quoted-printable bodies undecoded
  and listed 5 "PG=\r\nE" messages; mailin was right, the oracle was fixed.)
- **Export + verify:** mbox 213,278,417 B in 27.0 s, verified in 51.4 s; .eml folder 227,312,981 B
  in 18.8 s, verified in 42.9 s — both `complete`, 56,699 eligible / checked / matching, 0
  mismatched, 0 unverifiable, 0 without record, 0 unparsed. Independent re-read: Python `mailbox`
  56,699 messages with the source's 56,699 Message-IDs, 0 repeated; Python `email` 56,699 .eml
  files, same ID set. PST 764,158,976 B in 60.3 s; libpff 20231205 reads 56,699 messages with
  56,699 Message-IDs (folder "mailin export").
- **Duplicates on real duplicates** (`RealCorpusDuplicateTests`, app test host): the engine formed
  19,432 groups (48,734 copies) in 44.2 s; 19,409 verified content-equivalent, 0 byte-identical
  (every Enron copy has its own Message-ID / X-Folder), 23 candidates; 29,254 copies
  bulk-removable. Against the independent content groups (From, To, Cc, Bcc, Date, Subject and the
  whole body equal: 19,424 groups, 48,703 copies) **0 false identical**; 19,409 of 19,424
  independent groups found and verified; none of the 23 candidates lies inside one independent group.
- **Found and fixed on this corpus (b515a69):** (1) every exported .eml began with an mbox
  envelope line (`From MAILER-DAEMON … 1970` or the source's From_), so 0 of 56,699 equalled its
  source file; (2) the PST stream writer crashed on messages dated "21 Dec 0001"; (3) a ZIP of
  the numbered-file tree imported 56,699 messages into no folder. (2) was hit by the first run,
  which used the package default writer (the previous stream writer; the app ships the spec
  writer). The second run imported the PST with the package default reader path (binary formats
  not streamed — the previous array path) and took 870 MB over baseline on the 764 MB PST; with
  the app's `streamingBinaryParsers` on (the row above) 56 MB.
- **Throughput:** 44–81 messages/s in Debug with the store committing each batch (most time is
  SQLite WAL checkpoint + fsync on a 97–98 % full volume) — a lower bound, not a shipping claim.
  The PST is 3.6× the source (UTF-16 properties, transport headers kept).
- **Also run on this candidate (real public data):** `Scripts/validate_fixtures.py` 7/7 PASS
  (libpff, readpst, pstdump on mailin's PST fixtures); `RealDataRecoveryTests` 10/10 on the
  Digital Corpora "filetypes1" PSTs and Thunderbird mailboxes fetched again today
  (`Scripts/fetch_open_fixtures.sh`, both downloads succeeded); `EnronRealMailTests` 1/1 (kaminski-v
  28,465 parsed in 18.3 s, 54 folders reconciled); `RealMailStoreFixtureTests`, `OwnerPackFixtureTests`,
  `NativeOLMPairFixtureTests`, `NSFODSReaderTests`, `ExcelNumberFormatTests`,
  `ReleasePreflightFixtureTests` 58/0; `MAILIN_RELEASE_PREFLIGHT=1` 11/0.
- **NOT TESTED at 100 MB on real data:** .msg files (no real 100 MB set; mailin-written only), OST,
  NSF and OLM (the public real samples are 0.3–47 MB), Apple Mail .emlx libraries.

## Earlier results

`V2_SCALE_RESULTS.md` (synthetic tiny-message corpora up to 1,000,000
messages / 4.7 GB, 582 MB peak RSS) remains the largest executed message
count. It measured a different shape — small messages, no attachments — and
its per-message throughput figures do not transfer to attachment-heavy mail.

## Review Pack, team case, Shortcuts Find at 100k (2026-10-13, Debug test host, this Mac)

Opt-in: `MAILIN_SCALE=1` — `V3ReviewTeamScaleTests`, `V31ScriptRunTests/testShortcutsFind_100k_tenThousandResults`.

| Run | Result |
|---|---|
| Review Pack, 100,000 emails (~2 KB body each) | written 1.7 s (200 MB); opened and verified 3.3 s; random body reads instant; 100,000-decision response written and verified 0.9 s; memory +28 MB (bodies are read on demand) |
| Team case, 100,000 log entries from 3 reviewers | cold open (every entry's signature and chain checked) 7.3 s, +186 MB; reload after one new entry **0.23 s**. Before the fix found by this run it was 6.5 s: a date formatter was built for every entry on every reload |
| Shortcuts Find, 100,000-email archive | 10,000 results (the stated per-Find limit) in 0.05 s, +36 MB |

## 2026-11-19 — import write cost grew with the archive (CLOSE-08)

**Found:** the owner imported `enron.mbox` (213,466,347 B, 56,699 messages) in the Debug-Connected app on the
MacBook Air (M4, 16 GiB) for the App Store pictures: **33 % after one hour**, while the 2026-11-18 row above
stored the same file in 703 s through the same `BulkImportCoordinator`. lldb on the running app: the import
thread was in `SQLiteEmailStore.indexSearchDocument` → `DELETE FROM search_chunks WHERE email_id = ? AND kind = ?
AND ordinal = ?` → `fts5NextMethod` → `readDbPage` / `pread`; the batch envelope was `maxMessages = 8` (the
adaptive controller's floor, reached through "store commits are slow").

**Cause:** `search_chunks` is FTS5 and those three columns are UNINDEXED, so the DELETE visits every chunk row.
Five documents per message, each cleared before it is written: cost ∝ table size, i.e. quadratic over an
import. The engine benchmark paid the same scans but from a warm 128 MB page cache; in the app the store's
cache was smaller and under memory-pressure evictions, so the scans went to disk, and every slow commit shrank
the batch further (7,000+ commits and checkpoints for the file instead of ~115).

**Fix:** `search_docs.first_rowid` / `last_rowid` (added on open; no version change). A document's chunks are
written as one contiguous rowid run; clearing is `DELETE … WHERE rowid >= ? AND rowid <= ? AND email_id = ? …`
(FTS5 rowid index), a fresh document does no DELETE, rows from before the columns are still cleared by the old
scan. `SearchChunkRunTests.testWriteCost_staysFlatAsTheIndexGrows`: 8 × 300 messages — old path last/first =
10.4 (1.87 s for the last 300, in-cache), fixed = flat, 0.86 s for all 2,400.

**To re-measure on the candidate (not yet run after the fix):** the mbox row of `RealCorpusMatrixTests`
(`MAILIN_SCALE=1`, Debug test host) and the owner's app import of the same file; both figures belong here.

## 2026-11-19 — PERF-00 baseline (Release, pre-optimisation head e918bb0)

Engine matrix `RealCorpusMatrixTests` run with `swift test -c release -Xswiftc -enable-testing`
(`MAILIN_REAL_CORPUS=~/Downloads/Mail/Fixtures/real-corpus-enron`, `MAILIN_SCALE=1`) from a detached worktree at
**e918bb0** (CLOSE-08 included, PERF-01…04 not), MacBook Air M4 16 GiB, macOS 27.0.1, 18:15–19:32 IST.
**Caveat:** the Mac was not idle — Xcode test runs and package builds for PERF-01…04 ran at the same time, so these
figures are an upper bound; the PERF-05 "after" run must be taken under the same or quieter conditions, and the
baseline re-run quietly if the two are to be compared to better than ~20 %.

| Source | Bytes | Messages | Discover | Import | Footprint growth | Store / FTS | Reconciliation |
|---|---|---|---|---|---|---|---|
| mbox (real, mboxrd) | 213.5 MB | 56,699 | 0.74 s | **768.4 s** | 50 MB | 701.6 / 300.0 MB | discovered 56699, parsed 56699, damaged 0, persist failed 0, FTS rows 56699 |
| eml folder tree (real files) | 210.2 MB | 56,699 | 34.21 s | **1,611.6 s** | 141 MB | 715.6 / 298.4 MB | same; 118 of 118 folders, unmatched 0 |
| zip of the tree (real files) | 102.1 MB | 56,699 | 0.61 s | **1,315.1 s** | 0 MB | 716.5 / 297.5 MB | same; 118 of 118 folders |
| pst (mailin writer, from the real archive) | 764.2 MB | 56,699 | 0.55 s | **771.7 s** | 54 MB | 790.0 / 298.8 MB | same |

Exports: mbox 19.2 s, eml 18.0 s, pst 33.8 s; verify mbox 40.0 s / eml 37.7 s, both complete 56,699 / 56,699.
Release is not faster than the 2026-11-18 Debug figures (703 / 1,281 / 1,383 / 786 s): the engine is bound by the
store and index writes, not by Swift code. First-visible / app-level figures (the in-app Import Measurement in a
Release build) and the 1 GB, attachment-heavy and OST rows are still owed (PERF-00 in `FIVE_JOBS_TRACKER.md`).

## 2026-11-19/20 — PERF-05 after-run (Release, head 10732b1 = PERF-01…04)

Same matrix, same fixture, same command, detached worktree at **10732b1**, started 19:36 IST; the Mac was
quieter than during the baseline (only the ~3-minute long-test class overlapped its build). Baseline figures in
brackets are the e918bb0 rows above, taken under heavier concurrent load — so the gain below is an upper bound until
the baseline is re-run quietly (owed).

| Source | Import after | Import before (e918bb0) | Change | Footprint growth after / before | Reconciliation |
|---|---|---|---|---|---|
| mbox (real, mboxrd) | **567.3 s** | 768.4 s | −26 % | 103 MB / 50 MB | discovered = parsed = stored = FTS rows = 56,699, damaged 0, persist failed 0 |
| eml folder tree (real files) | **1,045.1 s** | 1,611.6 s | −35 % | 132 MB / 141 MB | same; 118 / 118 folders |
| zip of the tree (real files) | **852.2 s** | 1,315.1 s | −35 % | 0 MB / 0 MB | same; 118 / 118 folders |
| pst (mailin writer, from the real archive) | **679.2 s** | 771.7 s | −12 % | 58 MB / 54 MB | same |

Exports: mbox 16.9 s, eml 15.8 s, pst 33.5 s; verify mbox 39.4 s / eml 34.7 s, complete 56,699 / 56,699 on both.
The mbox footprint growth doubled (two batches resident with the one-ahead pipeline, larger store cache under
the adaptive budget) and stays far inside the 4 GiB soft budget. Store and FTS sizes unchanged (701.7 / 294.9 MB).
Not yet in these rows: first-visible time (app only), attachment indexing to completion, 1 GB, attachment-heavy,
OST, existing-archive import — PERF-00 owes them.

## 2026-11-20 — PERF-05: the quiet baseline (Release, e918bb0, Mac otherwise idle, 06:37–07:43 IST)

The same matrix as the two runs above, on the pre-optimisation worktree, with nothing else running on the Mac
(only a background download). This is the honest "before"; the 2026-11-19 baseline rows were inflated by
concurrent builds and tests and must not be used for a comparison.

| Source | Before, quiet (e918bb0) | After (10732b1, 2026-11-19 19:36, near-quiet) | Change | Before, loaded (for the record) |
|---|---|---|---|---|
| mbox (real, mboxrd), 213.5 MB, 56,699 | **598.4 s** | 567.3 s | −5 % | 768.4 s |
| eml folder tree, 210.2 MB | **1,148.8 s** | 1,045.1 s | −9 % | 1,611.6 s |
| zip of the tree, 102.1 MB | **1,291.2 s** | 852.2 s | −34 % | 1,315.1 s |
| pst (mailin writer), 763.9 MB | **730.7 s** | 679.2 s | −7 % | 771.7 s |

Every row of every run reconciles (56,699 = 56,699, FTS rows equal, 118/118 folders, exports verified complete).
Exports/verify unchanged within noise (mbox 17.8 / eml 16.2 / pst 34.0 s; verify 40.2 / 36.1 s). Footprint growth
before/after: mbox 55 → 103 MB, eml 170 → 132 MB, zip 0 → 0, pst 56 → 58 MB.

**Reading:** on this corpus (small text messages, no attachments to extract) the engine-level gain of PERF-01…04 is
modest for mbox / eml / pst (5–9 %) and large for the zip container (34 %, where decompression + parse now overlaps
the write). The dominating cost remains the store and the two search indexes per message. Single runs each; the
instruction's "repeat at least three times, alternate order" is still owed and is done cheaply with
`ImportThroughputTests` (`MAILIN_IMPORT_SCHEDULE=both`, same binary, mbox only) rather than the 65-minute matrix.
