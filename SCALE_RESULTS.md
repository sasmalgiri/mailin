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

## Earlier results

`V2_SCALE_RESULTS.md` (synthetic tiny-message corpora up to 1,000,000
messages / 4.7 GB, 582 MB peak RSS) remains the largest executed message
count. It measured a different shape — small messages, no attachments — and
its per-message throughput figures do not transfer to attachment-heavy mail.
