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

## Found and fixed by the external source audit (2026-09-28)

An independent source audit of the release candidate (18 findings) was re-checked line by line;
fifteen were confirmed and the ten that affect stored or exported data are fixed in this release,
each with a regression test that reproduces the original defect:

- **Moving the archive could delete it.** Choosing the volume the archive already lived on resolved
  the destination to the archive itself, which was removed before the copy started; a destination
  holding someone else's archive was removed the same way; and the old copy could be deleted before
  the relaunch that switches to the new one. The relocator now refuses the same, nested or aliased
  folder and any folder that already holds an archive, copies into a staging folder that is renamed
  into place only after verification, and offers the old copy for deletion only once the running
  store has opened at the new root.
- **A message above the 100 MiB ceiling could lose its only content reference.** Its locator was
  written after the row committed, with failures only logged, and was skipped entirely when the
  "byte-range reads" switch was off. The locator now commits in the same transaction as the row,
  whenever the offset engine runs.
- **Such a message exported as an empty stub from EML export, production and the sealed case
  bundle**, and the bundle sealed a hash of nothing. All three now read the message's bytes from
  the original file through one shared path, proven byte-identical to what a full parse stores;
  a message whose original is gone fails the export or is withheld with the reason, never sealed.
- **"Copy into the archive" copied nothing.** The import sheet now states what happens: messages up
  to 100 MiB are stored in the archive; larger ones are read from the original file, which must
  stay where it is. A real copy is a 3.1 item.
- **Two attachments with the same filename hydrated as the same file.** The ordinal is now the
  identity; the filename only a cross-check; an ambiguous match returns nothing rather than the
  wrong file.
- **Quoted-printable binary attachments were corrupted** (decoded as text, re-encoded as UTF-8).
  The transfer decode is now byte-level.
- **Production could release withheld documents and count PDFs that were never written.** A
  tag-read failure now stops the run; a document counts as produced only when its PDF exists; the
  manifest carries the PDF's own hash; a stopped run publishes nothing and says so.
- **A malformed ZIP64 archive could crash the app** (unchecked 64-bit conversions). It is now an
  import error naming the field.
- **Resuming an interrupted export could duplicate records.** A kept partial artifact now ends at
  the last reported batch, and a resume is refused when the archive changed in between.
- **The offline verification script accepted a build with the sandbox switched off** (it checked
  the key, not the value). It now checks values, and a self-test runs it against six entitlement
  shapes.
- **The "skip re-encoded duplicates" import choice was silently downgraded** to plain Message-ID
  matching on its way to the store. The chosen policy now arrives unchanged.

The remaining confirmed findings — real defects that did not lose data on the default path — are
also fixed in this release (owner decision, 2026-09-28):

- **Exports did not check that the source file was still the imported file.** Each export run now
  verifies every source it streams from against the digest recorded at import, once per file; a
  changed or swapped file refuses the export instead of producing a fresh, valid-looking hash.
- **The audit chain accepted truncation.** Any valid prefix of the chain, including an empty log,
  verified. The chain now keeps an anchor (count and newest HMAC) in the Keychain; a shorter,
  replaced or missing log is reported as broken, an unreadable log is quarantined rather than
  overwritten, and the next chain opens with an entry recording the loss.
- **A managed hard-off left the page's work running.** A policy change now goes through the same
  teardown as switching the page off: jobs cancelled, feature host released, wiring reapplied.
- **The semantic index never revisited later imports.** A completed walk now clears its cursor,
  the next run embeds only what is missing, and vectors of deleted messages are removed.
- **Summaries and Reports ignored the page scope, and Reports capped before filtering.** Both tabs
  now read the scope shown in the bar; the report applies its date range in the query, states
  exactly how many matching messages it covered, and fails visibly if the read stops early.
- **"Cited evidence (verified)" overstated the check.** The label now says what is true: each
  citation resolves to a retrieved message; the statements themselves are not fact-checked.

### Second audit pass (2026-09-28, against the fixed build)

The auditor re-read the fixed branch and reported nine remaining paths, two of them new defects
introduced by the first fix wave. All nine are fixed in this release:

- The whole-message attachment fallback still returned the first of two same-named attachments;
  it now resolves by ordinal like the located path.
- An export's selection fingerprint was taken when the run stopped, not when it started, and a
  resume without one was allowed; the partial file's length was not checked. A run now binds to
  its selection before writing, a resume without a fingerprint or with a changed or missing partial
  file is refused, and a partial that cannot be cut back cleanly is removed rather than offered.
- Appending to a truncated audit chain re-anchored it. An append now requires the chain to end at
  its anchor; an unreadable anchor or a failed quarantine refuses the append.
- The two legacy EML loops streamed located messages without verifying the source, and the ledger
  cached by path alone. Every located write now verifies; the cache key carries the expected digest
  and the file's size and modification date; unverifiable sources are counted on the receipt.
- PDF, TIFF and MSG exports rendered header-only stubs for messages above the ceiling. Those formats
  now withhold such messages, count them, and report the run as partial.
- The sealed case bundle re-encoded located bytes as UTF-8 before hashing. Format 2 carries the
  exact bytes separately and hashes those; the text is a view.
- The streaming quoter and unquoter lost line-start state on lines above 1 MiB and could add or
  remove a byte mid-line. Both are now a byte state machine with bounded memory, proven equal to
  the whole-text functions for every chunking, including 1.1 MiB lines.
- The relocator still removed a pre-existing destination folder that lacked an archive database.
  Only an empty folder may be replaced; any other content refuses the move.
- Report and digest date pickers replaced the page's date bounds instead of narrowing them. They
  now intersect.

### Third review (2026-09-29, against the second fix wave)

Six remaining paths, all in export resume and source verification, all fixed:

- A resume without a recorded selection fingerprint was bound to the current archive and accepted.
  A resume is now validated before anything is written and is never re-bound.
- A partial single-file export was checked by length only. It is now checked by length and hash.
  Folder exports keep a manifest of every produced file with its hash; a resume requires the
  manifest, verifies every file, and refuses a missing or changed file or a deleted folder.
- Skipped or withheld messages shifted the resume position. Progress now reports the input
  position; the produced count travels separately, so a resume skips exactly what was consumed.
- Source verification was cached process-wide by file metadata. It is now scoped to one export
  operation, keyed by path and expected digest, and re-checks the file's size and date before and
  after every read that depends on it.
- The streaming quoter stopped recognising a line as `From` after 65,536 leading `>`. It now
  counts the run instead of buffering it, with no limit.
- The relocator treated a destination folder it could not list as empty. It now refuses.

### Fourth review (2026-09-29, against the third fix wave)

Six remaining paths, all in export resume, all fixed:

- The MBOX stream verified a located source once and then read it without the before/after change
  check the per-file path had. The verified locator now travels with the stream plan and the
  source is checked before the first byte and after the last; a change cuts the output back.
- A resume with a smaller batch replayed the already-written prefix and reported each replay batch
  as progress, so a failure during replay could move the checkpoint backward and a later resume
  wrote those messages twice. Progress is now seeded from the checkpoint and never reported or
  committed below it; replay-only batches write no boundary.
- A folder export that withheld a message before an interruption forgot it after the resume and
  could report "complete". The manifest boundary now carries the cumulative withheld and skipped
  counts; the resumed run restores them and the receipt says partial.
- The manifest was trusted: a stray entry named `../x` would have been deleted outside the export
  folder. Every name is now validated (relative, no `..`, resolves inside the folder through any
  symlinked parent, not itself a symlink, no duplicates) before anything is touched; a bad entry
  refuses the resume.
- "Skip files that already exist" counted the accepted file as produced without listing it, so the
  manifest could never verify. Accepted files are now fingerprinted into the manifest (marked as
  existing) and are never created or removed by the export.
- Entries past the last boundary were tolerated but left in the manifest, so the next run counted
  them. Verification now cuts the manifest back to its last boundary (tolerating one torn trailing
  line) and refuses if it cannot.

Also from this review: the ledger takes its size/date baseline before hashing a source and
confirms it afterwards, so an edit that lands during the hash cannot become the baseline; and a
fix found by the new regression, not by the review — fetching a page of messages by id returned
them in SQLite's order rather than the requested order, so the stream order depended on batch
size. Rows now come back in the order asked for, which positional resume relies on.

### Fifth review (2026-09-29, against the fourth fix wave)

Two remaining manifest-recovery paths, both fixed:

- The manifest file's own identity was never checked: a symlink placed at its path would have
  redirected the cut-back and later appends to a file outside the export folder. The manifest is
  now opened by descriptor without following symlinks, must be a plain regular file with a single
  link, and every read, cut-back and append goes through a descriptor checked that way. A fresh run
  replaces whatever sits at the path and creates its manifest exclusively. The control filename is
  reserved and refused as an output entry.
- A stray file past the last boundary that could not be removed was forgotten: its entry was cut
  from the manifest and the resume reported success with the file left behind. Committed output is
  now verified before anything is removed; a stray that cannot be inspected or removed refuses the
  resume and keeps its entry, so the next attempt sees it again. The writer's own stop-time cleanup
  cuts the manifest back only when every past-boundary file is really gone.

### Sixth review (2026-09-29, against the fifth fix wave)

Two narrower manifest paths, both fixed:

- The writer's stop-time cleanup treated any failure to inspect a past-boundary file as "gone".
  Only a definite absence counts now; a file whose state cannot be established (permission or I/O
  error) keeps its manifest entry for the next verification.
- A fresh run claimed the manifest path with a recursive remove, which would have deleted a
  directory placed at that name together with its contents. The path is now claimed with a
  non-recursive unlink that removes a single directory entry (a stale file, or a symlink itself)
  and can never remove a directory or its contents; a directory there refuses the export.

### Seventh review (2026-09-29)

No defect found; both sixth-review items confirmed closed at source level. Two precision notes
acted on: the wording above narrowed to what the unlink actually refuses (a directory), and the
permission regression skips cleanly before it can record a failure in an environment that does not
enforce mode bits. Native test logs for the reviewed commit are kept under `Verification/`.

## Known limits, stated

- The streaming `From`-line filter keeps a leading-`>` run as a count, but emits the run as one
  buffer when the line is decided, so a single run of `>` bytes costs its own length in memory
  once. This is a resource bound, not a correctness defect.

- A source file replaced by one of equal size with its modification date restored, between the
  verification at the start of an export and the read, is not detected within that run. Every new
  run re-hashes the file and would refuse it.
- Originals are referenced, not copied: a message above the 100 MiB full-parse ceiling is read from
  the file it was imported from whenever it is opened or exported. Move or delete that file and the
  message's content is unavailable (the app says so; it never substitutes an empty message).
- Production (Bates PDF) withholds such messages with the reason in `excluded.csv`; export them as
  MBOX or EML, which stream them byte for byte.

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
