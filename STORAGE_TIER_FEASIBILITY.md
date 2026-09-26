# Storage tier feasibility (3.0 §5.2 / P8)

Written 2026-09-27. Status per tier is what has been executed, not what is designed.

## Tiers

| Tier | Active DB / WAL / FTS | Originals / blobs | 3.0 status |
|---|---|---|---|
| Mac internal (default) | `<Application Support>/com.ecosanskriti.mailin/{sqlite,fts5,embeddings}` | managed copy or bookmarked reference | **ships** — measured to 1.52 GB source (`SCALE_RESULTS.md`) |
| Local external APFS volume | same layout under `<volume>/mailin-archive/` after a verified move (`ArchiveRelocator`) | same volume | **ships (code)**; executed on an hdiutil APFS image in J-3, not yet on a physical SSD (owner decision: disk image stands in) |
| Blob tier (large bodies) | rows > 8 MiB stored beside the database, content-addressed | — | **ships, default on** (S4 verdict); executed proof of a > 1 GB message is `LargeMessageBlobTests` (J-3) |
| iCloud Overflow | never — hot files stay local | immutable content-addressed **segments** uploaded, hash-verified on fetch, bounded local cache | **prototype, local half built** (`OverflowSegmentStore`, `LocalFolderTransport`, 4 tests); iCloud transport waits on the container identifier |
| Network share for the active store | — | — | **refused** (unreliable locking) — `ArchiveLocationPolicy` |
| Cloud-synced folder (iCloud Drive, Dropbox, OneDrive, Google Drive) for the active store | — | — | **refused** (DB and WAL sync independently) |

## Preflight budget

`StoragePlanner.requirement` sums: source bytes, original copy (if copying), store growth (1.3×
planning, 1.08× measured), index (0.2× planning, 0.03× measured), WAL, spool, hard floor.
`StoragePlan` is `ok` / `tight` / `insufficient` with the missing bytes named; the guided import sheet
disables Start on `insufficient`; the coordinator refuses to start when `enforceStoragePreflight` is on.

## The 250 GB Mac case (directive)

A 250 GB internal disk with 45 GB free (this machine, 2026-09-27) can hold an archive of roughly
30 GB of source before the planner's comfort margin refuses more. The external tier is the answer:
the move copies `sqlite/`, `fts5/` and `embeddings/`, verifies byte counts, the `emails.db` SHA-256 and
the reopened row count, records the new root, and leaves the copy on this Mac until the user deletes
it from the Storage screen. If the external volume is detached, the app falls back to that copy and
says so; it never shows an empty archive.

## iCloud Overflow — feasibility verdict so far

| Question | Answer | Evidence |
|---|---|---|
| Can blobs be packed into immutable, hash-named segments and read back by offset? | yes | `OverflowSegmentStoreTests.testBlobsRoundTripThroughSegmentsAndSurviveLocalEviction` |
| Is a tampered or partial remote segment ever used? | no — hash mismatch is refused and the file discarded | `testTamperedRemoteSegmentIsRefused` |
| Does the manifest survive relaunch? | yes | `testManifestPersistsAcrossReopen` |
| Does the local cache stay bounded? | yes — LRU trim to `cacheLimitBytes`, only for segments confirmed remote | code; measured in J |
| Does the design keep the hot database off the cloud? | yes by construction — only the blob tier is segmented | `OverflowSegmentStore` |
| Can iCloud Documents host the segments? | **untested** — needs `iCloud.com.ecosanskriti.mailin` and the ubiquity container | owner |

**Recommendation (unchanged):** iCloud Documents (ubiquity container) rather than CloudKit — the
segments are files, verified by hash, counted against the user's own quota, with no server schema.
The entitlement ships only when the transport row above is PASS with measurements.

## Not doing

- Raising `SQLITE_MAX_LENGTH` (SQLite advises against; the blob tier removes the need).
- Chunking bodies across rows.
- Any tier that puts `emails.db`, its WAL or the FTS shards on a synced or network volume.
