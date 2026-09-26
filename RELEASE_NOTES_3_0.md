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

- ArchiveCore boundary enforced by `Scripts/check_archive_core_boundary.sh` (31 files; no UI import,
  no app-layer type), run on Xcode Cloud. Professional exports moved out of the core file set.
- iCloud Overflow prototype: content-addressed, hash-verified segments with a bounded local cache,
  proven against a local-folder transport; the iCloud transport waits on the container identifier.
- Documents added: `PAGE_WINDOW_MATRIX.md`, `ADAPTIVE_IMPORT_DESIGN.md`, `IMPORT_RECEIPT_SPEC.md`,
  `STORAGE_TIER_FEASIBILITY.md`, `NETWORK_AND_PRIVACY_MATRIX.md`, `MAIL_CLIENT_HANDOFF_TESTS.md`,
  `LIVE_MAIL_PROVIDER_MATRIX.md`, `LIVE_MAIL_MULTI_ACCOUNT_TESTS.md`, `WORKFLOW_INVENTORY.md`,
  `STORE_LISTING_3_0.md`.

## Known limits, stated

- Largest executed import is 1.52 GB of real mail; larger sizes are not tested (`SCALE_RESULTS.md`).
- PST and MSG have their first executed fixtures (Apache Tika) in Phase J; OST and NSF have none.
- The physical SwiftPM extraction of ArchiveCore is deferred to a pass in which tests run between
  steps; the boundary is enforced now.
- Per-source search coverage is archive-wide, not per source.
