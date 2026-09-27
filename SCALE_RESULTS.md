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

## Earlier results

`V2_SCALE_RESULTS.md` (synthetic tiny-message corpora up to 1,000,000
messages / 4.7 GB, 582 MB peak RSS) remains the largest executed message
count. It measured a different shape — small messages, no attachments — and
its per-message throughput figures do not transfer to attachment-heavy mail.
