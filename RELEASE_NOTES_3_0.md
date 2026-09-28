# mailin 3.0 — release notes (engineering)

Branch `v3-architecture`, 2026-09-27. Scope decided by the owner: Pages 1–3 ship as 3.0; Live Mail
is built on the `live-mail` feature branch and is not part of this release. Every item below is
**implemented and building**; the Phase J test pass (`MAILIN_3_0_TODO.md`) is what turns
"implemented" into "verified", and `RELEASE_READINESS.md` records which rows have executed numbers.

## Archive (Page 1)

- **Three-pane shell.** Mailboxes / sources / labels / saved searches · list · detail, all paged by
  keyset or ranked cursor; an open archive lands here. Trash is a real mailbox (`trashedOnly`).
- **Search says where it matched** (From / To / Subject / Attachment / Body / Source / Tag) and
  **what the index covered** when it answered; a no-results state never reads as a bare zero.
- **Import sheet with choices**: duplicate policy (incl. re-encoded copies), copy vs reference with
  live space re-planning, attachment-content indexing. Both the sheet and the queue are on by default.
- **Import queue** with pause / resume / stop-this-file / cancel-all / reorder, per-file stage,
  throughput, ETA (labelled as estimate), batch envelope, indexed fraction and the pause reason
  (user, pressure, or archive volume detached).
- **Export pre-flight and resume**: folder layout, collision rule, attachments folder, mbox 2 GB
  split, space estimate against the destination; an interrupted export resumes from its receipt and
  the hash covers the whole artifact. Every export ends in a receipt.
- **Offset import engine is the default** (S4 verdict): equal throughput to the streaming parser on
  the 1.5 GB run, imports single messages over 100 MB, records the byte ranges per-part reads use.
  The streaming parser remains as fallback for one release.
- **Archive relocation**: move the archive to another local volume as a verified copy (byte counts,
  database hash, reopened row count); the copy on this Mac stays until deleted; a detached volume
  falls back to it with a banner. Store, index and semantic index share one root.
- **Mail-client handoff**: import from / export to Apple Mail and Thunderbird with the exact steps;
  exports are read back before the steps are shown; mboxrd quoting on every line ending.
- **Release-safe measurement**: About ▸ Measure an import… runs any file through the production
  import path into a throwaway archive and reports throughput, footprint, disk and reconciliation.
- Idle FTS shards close after 180 s; launch-time jobs run through one inventory (`LaunchJobs`) so a
  disabled page's jobs never start.

## AI Insights (Page 2, off by default)

- Page shell with a scope bar (source, date) and Ask / Summaries / Reports.
- Citations that reopen: every `[E#]` in an answer maps to the retrieved message with Open.
- Opt-in, resumable **semantic index** (on-device sentence vectors; feeds Ask's retrieval).
- **Per-request cloud consent**: provider, model, bytes and excerpt shown before anything leaves the
  Mac; fails closed; honours the managed hard-off. (Cloud AI is compiled out of this configuration.)

## Professional Workflows (Page 3, off by default)

- Page shell with a working destination handler, studios and tools strip, Work Center.
- `WORKFLOW_INVENTORY.md`: 51 rows, verification stated per row.
- Holds and Bates assignments survive disabling the page; no Professional job or export hook runs
  while it is off.
- **Production window**: Bates-stamped PDF set, SHA-256 manifest, exclusion log with reasons (tag,
  legal hold), attachment families, numbered production record, export receipt.

## Architecture and safety

- **ArchiveCore is a Swift package** (`Packages/ArchiveCore`, 53 files): store, index, parsers,
  import, export, receipts, layout. The compiler is the boundary; `Scripts/check_archive_core_boundary.sh`
  scans the package as the second line, run on Xcode Cloud. The package's own test target runs
  unsandboxed (`swift test`) for the fault-injection rows the sandboxed app cannot host.
- **Private SKU:** bundle id `com.ecosanskriti.mailin.enterprise` (Apple Business Manager Custom App);
  In-App Purchase code compiled out of `ENTERPRISE_EDITION`, kept for the public line.
- iCloud Overflow prototype: content-addressed, hash-verified segments with a bounded local cache,
  proven against a local-folder transport; the iCloud transport waits on the container identifier.
- Documents added: `PAGE_WINDOW_MATRIX.md`, `ADAPTIVE_IMPORT_DESIGN.md`, `IMPORT_RECEIPT_SPEC.md`,
  `STORAGE_TIER_FEASIBILITY.md`, `NETWORK_AND_PRIVACY_MATRIX.md`, `MAIL_CLIENT_HANDOFF_TESTS.md`,
  `LIVE_MAIL_PROVIDER_MATRIX.md`, `LIVE_MAIL_MULTI_ACCOUNT_TESTS.md`, `WORKFLOW_INVENTORY.md`,
  `STORE_LISTING_3_0.md`.

## Found and fixed by the Phase J verification (2026-09-27)

Every claim below was tested against real mail before release; these are the defects the tests
found, all fixed in this release:

- **PST import read zero messages from every real PST** (B-tree pages read by type instead of
  level, private block-page types, no `bCryptMethod` decoding for PST files). The first executed
  PST import (Apache Tika fixture) now reconciles.
- **No folder source had ever imported through the production path** (EML folder, Maildir, Apple
  Mail package, `.emlx` folder): the chain-of-custody hash opened the folder as a file. Folder sources
  now get a digest over their sorted members; all four forms executed at 1 GB, exact reconciliation.
- **A message above the full-parse ceiling exported as a 427-byte stub**: the exporter had no path
  for a message whose bytes are located rather than stored. It now streams them; the executed 1.1 GB
  message exports byte-for-byte.
- **mbox export was not byte-identical on re-import**: the stored envelope line was quoted into the
  body as `>From`, mboxrd `>From ` escaping was never undone on read, partitioned export never split,
  and CRLF mail was invisible to the quoter. The real-mailbox round trip is now 526 of 526 byte-identical.
- **The Release app sat at 100 % CPU at idle**: an observed revision bumped on every UserDefaults
  change re-rendered the main view continuously. Idle is now 0 % CPU, 145 MB footprint.
- **Cancel did not reach a paused import**, and **the disk reserve was a flat 5 GiB** (no volume under
  10 GiB could import). Cancel is universal; the reserve scales with the volume.
- **After an external volume was unplugged and reconnected, every write failed**: handles pointed at
  the old mount. The importer re-opens them and retries the interrupted batch.

## Import speed (2026-09-28)

Profiling the shipping build showed the import was bound by the parser, not
by the database. Six fixes — a byte-level base64 cleanup, one MIME pass per
message instead of two, a byte-level MIME split with compiled-once regexes
and a byte-level quoted-printable decoder, parsing each batch on several
cores, no temp copy of every attachment during import, and a larger
search-index shard budget for folder sources — took the real 95 MB mailbox
from 78.7 s to 1.0 s in Release (86 MiB/s), and the 1 GB format rows 7–19×
faster. Every count, the byte-identical round trip and the full test suite
were unchanged at each step (`SCALE_RESULTS.md`).

## Known limits, stated

- Largest executed import is 1.52 GB of real mail in one file and 1.04 GB per container form;
  larger sizes are not tested (`SCALE_RESULTS.md`).
- PST and MSG have executed fixtures (Apache Tika); the PST fixture yields one message and its true
  count is not independently verified. OST and NSF have no real fixture.
- An unplug that lands DURING a SQLite write terminates the process (WAL's memory-mapped index);
  recovery is WAL + the import checkpoint on relaunch. An unplug between batches pauses and resumes.
- `bCryptMethod` 2 (cyclic) PST/OST files are refused with a message, not decoded.
- Per-file sources (EML folder, Maildir) import ~3.4× slower than a single file of the same bytes.
- Genuine customer v1 / 2.x libraries, a real Apple Mail export and OST/NSF files are still owed by
  the owner; the migration and handoff rows ran on synthetic stand-ins built from real mail.
