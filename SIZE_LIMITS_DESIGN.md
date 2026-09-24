# Removing size limits — design, grounded in sources

Date: 2026-09-24. Question: can mailin handle a message or a file of **any**
size? Researched rather than assumed, because two of my earlier answers to this
were wrong.

---

## 1. What the sources actually say

### SQLite — the binding storage constraint nobody had checked

| Fact | Value | Source |
|---|---|---|
| Default max string/BLOB length | **1,000,000,000 bytes (1 GB)** | sqlite.org/limits.html |
| Absolute implementation max | 2³¹−3 = 2,147,483,645 bytes | same |
| **Max row size** | the same limit — "during part of SQLite's INSERT and SELECT processing, the complete content of each row in the database is encoded as a single BLOB" | same |
| Raising it | possible via `SQLITE_MAX_LENGTH` / `sqlite3_limit`, but "in security-sensitive applications it is best not to try to increase the maximum string and blob length" | same |
| Max DB size | ~281 TB at 64 KiB pages, **~17.5 TB at the default 4 KiB** | same |

**Consequence for us:** `email_bodies.raw` currently holds the whole raw MIME of
a message in one column. A single message larger than ~1 GB **cannot be stored
that way at all**, and SQLite advises against raising the limit. So "no message
size limit" is not only a parser problem — it is a storage-schema problem, and
no amount of streaming in the parser fixes it.

**The tool for large values:** incremental BLOB I/O —
`sqlite3_blob_open` / `_read` / `_write` / `_bytes` — reads and writes
subsections of a BLOB without materialising it. Constraints that shape the
design: it **cannot resize** a blob (pre-allocate with `zeroblob(n)`), it fails
on `WITHOUT ROWID` tables, it fails for read/write if the column is part of an
index, PRIMARY KEY or UNIQUE constraint, and the handle **expires** if any
column of that row is modified.

### Outlook PST/OST — our 50 GB cap refuses legitimate files

| Fact | Value | Source |
|---|---|---|
| ANSI (pre-2003) PST hard ceiling | **2 GB** — a larger `MaxFileSize` "is ignored and the size is limited to 2 GB to prevent corruption" | Microsoft Learn, *Configure size limit for Outlook data files* |
| Unicode PST/OST default max | `MaxLargeFileSize` = **51,200 MB (50 GB)**; `WarnLargeFileSize` = 48,640 MB (95 %) | same |
| Above the default | Admin-configurable by registry, e.g. 102,400 MB (**100 GB**); Microsoft warns about performance, not impossibility | same |

**Consequence:** PSTs larger than 50 GB exist in the wild wherever an admin
raised the registry value. Our 50 GB refusal is therefore not "the format's
limit" — it is our untested boundary, and it rejects real evidence files.

### Lotus Notes NSF — my earlier answer was wrong

| Fact | Value | Source |
|---|---|---|
| Legacy maximum | 64 GB | HCL Domino admin docs |
| **Domino 10+ at ODS 53 or higher** | **256 GB** on Windows and UNIX | HCL Domino 10/12 admin docs, *Database size quotas* |
| Below ODS 53 | still 64 GB regardless of server version | same |
| Logical vs physical | DAOS moves attachments out of the NSF (logical size can reach ~1 TB); NIFNSF moves view indexes out | HCL docs / Nashcom |

**Correction:** I told you 64 GB was "mostly real, leave it". That is the
pre-ODS-53 limit. A modern ODS 53 NSF can be **256 GB**, so our 64 GB cap
refuses valid databases too.

### Streaming MIME parsing — the established pattern

Apache James **Mime4J** is the reference design: an event-based
`MimeTokenStream`/`MimeStreamParser` that reports entity/body boundaries like a
SAX parser and **deliberately does not decode** base64 or quoted-printable
bodies, with `RecursionMode.M_RAW` to locate a part without parsing it at all.
Its DOM tier "uses temporary files for large attachments" rather than RAM.

The documented offset pattern: **run a raw pass that records the byte offsets of
each part boundary, persist those offsets, then later re-open the backing file
and stream only the byte range you need through a decoder.**

The cautionary counter-example is Python's `email.parser.BytesFeedParser`:
incremental *feed* does not mean low memory — it "buffers everything in memory,
including large file uploads". Our current MBOX parser has exactly this shape
(`currentLines: [String]` → `joined()`), which is why the 100 MB per-message cap
exists at all.

---

## 2. Where our limits come from, and what each one really is

| Limit | Value | Nature | Verdict |
|---|---|---|---|
| `MBOXParser.maxMessageBytes` | 100 MB per message | **ours** — the parser holds the whole message in RAM several times over | remove, after offset-based parsing |
| PST/OST file size | 50 GB | **ours** — untested boundary, not a format limit (Unicode PSTs go beyond it by registry) | raise; keep a *tested-to* statement instead of a refusal |
| NSF file size | 64 GB | **stale** — correct only below ODS 53; ODS 53+ allows 256 GB | raise to 256 GB for ODS 53+, keep 64 GB below it |
| ANSI PST | 2 GB | **format** — Microsoft caps it to prevent corruption | keep, and report a larger "ANSI" file as corrupt |
| `email_bodies.raw` single column | ~1 GB | **SQLite** — max value *and* max row | cannot be raised safely; needs chunked or external storage |
| FTS index size | disk | **physical** | index a bounded prefix per message and *say so* |
| Free disk | disk | **physical** | preflight; never start an import that cannot finish |

---

## 3. The design

### 3.1 Parse by offsets, never by accumulation

Replace "accumulate the message, then parse the string" with a scanning pass
that records structure and keeps only a bounded window in memory:

```swift
struct MessageLocator: Codable, Sendable {
    var sourceDigest: String      // SHA-256 of the container file
    var offset: Int64             // start of this message in the container
    var length: Int64
}

struct PartLocator: Codable, Sendable {
    var offset: Int64             // relative to the message
    var length: Int64
    var contentType: String
    var transferEncoding: String  // base64 / quoted-printable / 7bit …
    var filename: String?
    var contentID: String?
    var isAttachment: Bool
}
```

- Headers are parsed from a bounded window (a header block is small; RFC 5322
  lines are ≤ 998 chars).
- MIME boundaries are found by scanning bytes, not by splitting into `[String]`.
- Bodies are **never** decoded during import. Text parts are decoded lazily for
  indexing, up to the indexing budget (§3.3).
- Peak memory becomes O(window + batch metadata) instead of O(largest message).

This is the Mime4J `M_RAW` + offset-index approach, and it is also what finally
addresses the measured import peak (P3.5): the churn was per-message String and
Array allocation, not any retained structure.

### 3.2 Two-tier body storage, because 1 GB is a hard wall

| Message raw size | Storage | Read path |
|---|---|---|
| ≤ 8 MB (tunable) | inline BLOB in `email_bodies.raw`, as today | one read |
| > 8 MB | **content-addressed external blob** in the library (`blobs/<sha256>`), with the row holding digest + length + part locators | `FileHandle.seek` + range read |
| any size, when the user chose "keep source by reference" | no copy at all: the container file + `MessageLocator` | seek into the original |

Why external files rather than chunk rows: it side-steps the 1 GB value limit
entirely, keeps `emails`/`email_bodies` rows small (so the whole-row-as-BLOB
encoding stays cheap), makes attachment range reads a plain `pread`, and is
exactly the immutable content-addressed segment shape §9's iCloud Overflow
needs. Incremental BLOB I/O remains the fallback for the inline tier if we ever
want mid-size values without full materialisation — with its
`zeroblob`-preallocation and no-`WITHOUT ROWID` constraints respected.

Durability rule unchanged: the blob is written and fsynced, *then* the row
referencing it is committed, so a crash leaves an orphan blob (collectable)
rather than a row pointing at nothing.

### 3.3 Search coverage must stay honest

A 400 MB text body cannot be fully FTS5-indexed on a laptop. So:

- index a bounded prefix per message (proposal: 4 MB of extracted text),
- record `indexedTextBytes` and `totalTextBytes` per message,
- surface it: the message shows "indexed to 4 MB of 380 MB", and a search that
  could have matched beyond the cap says so rather than implying completeness.

This follows the directive's rule that a partial index may never produce an
unqualified zero result.

### 3.4 Replace refusals with preflight + tested-to statements

- **Per-message:** no cap. A huge message imports; its body lives external.
- **PST:** drop the 50 GB refusal. Detect ANSI vs Unicode from the header; an
  "ANSI" file above 2 GB is reported as corrupt (Microsoft's own rule). Above
  our tested ceiling, warn — "not tested above N GB" — and proceed.
- **NSF:** read the ODS version; allow 256 GB at ODS 53+, 64 GB below, and say
  which rule applied.
- **Everything:** `StoragePlanner` preflight — source bytes + blob copies + DB
  growth + WAL + FTS + temp spool + OS margin — refuses only when the numbers
  genuinely do not fit, and says exactly how many bytes are missing.

---

## 4. Sequencing (each step independently shippable)

| Step | Work | Unlocks | Risk |
|---|---|---|---|
| **S1** | External content-addressed blob tier + reference-by-locator reads | messages above ~1 GB become storable at all | medium — new storage path, needs orphan GC |
| **S2** | Offset-based scanning parser for mbox/eml (Mime4J shape) | removes `maxMessageBytes`; cuts import peak | **high — safety-critical parser rewrite** |
| **S3** | Bounded-prefix indexing + coverage reporting | honest search on huge bodies | low |
| **S4** | PST ANSI/Unicode detection; NSF ODS detection; caps replaced by warnings | stops refusing legitimate large files | low code, needs fixtures |
| **S5** | Executed large-file tests (a >2 GB single message; a >50 GB PST if obtainable) | lets us state a tested ceiling instead of a guess | hardware/corpus bound |

Guard rails for S2, non-negotiable: the round-trip test, the source-scoped
recovery report, "I/O error throws, never fake EOF", and force-quit checkpoint
reconciliation all stay green, and the 526-message fixture keeps reconciling
exactly.

---

## 5. The honest headline

**"No limit" is achievable for the limits we invented, and not achievable as an
absolute.** After S1–S4 the constraints are: free disk, the FTS budget (with
coverage stated), ANSI PST's 2 GB, NSF's ODS-dependent ceiling, and SQLite's
~17.5 TB database size. Nothing else in mailin should refuse a file for being
big — and where we have not tested at a size, the app should **say "not tested
above N"** rather than pretend either capability or impossibility.

---

## Sources

- [SQLite — Limits In SQLite](https://www.sqlite.org/limits.html)
- [SQLite — Open A BLOB For Incremental I/O](https://sqlite.org/c3ref/blob_open.html)
- [SQLite — A Handle To An Open BLOB](https://sqlite.org/c3ref/blob.html)
- [Microsoft Learn — Configure size limit for Outlook data files](https://learn.microsoft.com/en-us/microsoft-365-apps/outlook/data-files/configure-size-limit-outlook-data-files)
- [HCL Domino — Database size quotas](https://help.hcl-software.com/domino/12.0.0/admin/tune_databasesizequotas_c.html)
- [HCL Domino — ODS 53 supports larger databases and folders](https://help.hcl-software.com/domino/10.0.1/admin/wn_ods_53_supports_larger_databases_and_folders.html)
- [Apache James Mime4J](https://james.apache.org/mime4j/)
- [Mime4J — MimeTokenStream API](https://james.apache.org/mime4j/apidocs/org/apache/james/mime4j/stream/MimeTokenStream.html)
- [Python — email.parser](https://docs.python.org/3/library/email.parser.html)
- [multipart_bench — on BytesFeedParser buffering everything in memory](https://github.com/defnull/multipart_bench)

---

## 6. Compared with what we already have

Audited in the codebase rather than assumed. Several design elements are
already half-built, which changes the order of work.

| Design element | What exists today | Gap |
|---|---|---|
| Bodies out of the main row | **Done.** `email_bodies(id, plain, html, raw, headers_json)` is a separate table — "bounded memory by construction" (`SQLiteEmailStore.swift:524`), so the `emails` row stays small | `raw` is still one BLOB value → the 1 GB value/row ceiling applies to it |
| Bounded text indexing | **Partly done, and silently.** `insertWithHandle` indexes `String(body.prefix(50_000))` (`FTSSearchIndex.swift:1054`) | The truncation is **never reported**. A 380 MB body is indexed to 50 K chars and search implies completeness |
| Honest truncation pattern | **Already established elsewhere.** `BoundedRegexSearch` returns `truncated: true` whenever its scan cap cut results, with the comment "silent truncation is not acceptable" | FTS indexing must follow the same precedent |
| Source identity for reference-by-locator | **Partly done.** `sources(sha256, filename, byte_size, parser, parser_version, source_kind)` records container identity | No per-message byte offsets, and no security-scoped bookmark to re-open the original later |
| Resume position | Ordinal-based checkpoints (message index), identity-bound to source SHA-256 + parser version | Ordinals are not byte offsets; an offset-based parser wants both |
| Chunking | `EmailChunker.swift` is **semantic** chunking for AI (header / body / signature / quotedReply / attachment) | Name collision only — nothing there helps byte-level blob storage |
| Large-file reads | PST/NSF already use `Data(contentsOf:.mappedIfSafe)`, so RSS tracks the working set, not file size | mbox/eml path accumulates `[String]` then `joined()` — the opposite |
| Attachment re-extraction | **Done today** (`AttachmentHydrator`), but it re-parses the whole message to find one part | Should be a seek + range read once `PartLocator`s exist |
| Storage preflight | Not built (`StoragePlanner` is still a plan item) | Needed before any "proceed anyway" replaces a refusal |

Two conclusions from the audit:

1. **The cheapest, highest-value fix is not the parser.** The 50 K indexing
   truncation is a live silent-truncation defect on exactly the large messages
   this whole thread is about, and the codebase already contains the honest
   pattern to copy.
2. **`AttachmentHydrator` is a stopgap by design.** It restored a broken
   capability, but its whole-message re-parse is what `PartLocator` replaces.

---

## 7. Finalized implementation plan

Ordered by value-per-risk, not by the order the design was written.

### S0 — Report the indexing budget — **DONE 2026-09-24**

- Record per message: `indexedTextBytes`, `totalTextBytes`, `indexTruncated`.
- Surface it where a user could otherwise be misled: the message detail, the
  search-results coverage badge, and the import receipt's coverage section.
- Raise the 50 K char cap to a byte budget (proposal 4 MB) now that it is
  reported; keep it configurable.
- **Delivered:** the bound is now a **byte** budget of 4 MiB (it was 50,000
  *characters*, a different quantity for non-ASCII mail), truncation lands on a
  valid UTF-8 boundary, and `indexed_text_bytes` / `total_text_bytes` are
  written to `indexed_message` **in the same transaction as the FTS row** so the
  two cannot drift. Additive `ALTER TABLE` migration for existing shards.
- **API:** `FTSSearchIndex.indexableText(_:)` → `TextCoverage` (with a
  user-facing `summary`), `coverage(for:)` per message,
  `partiallyIndexedCount()` for a coverage badge, and a nonisolated
  `partiallyIndexedCountSnapshot()` for view code.
- **Surfaced:** the import receipt's Coverage section now states how many
  messages exceed the budget and that search covers only their first part.
- **Exit met:** 7 tests — a body over budget reports the shortfall, a body
  exactly at the budget is not mislabelled, the budget is bytes not characters
  (verified with 4-byte scalars), truncation never emits U+FFFD, coverage
  persists and reads back, the partial count is queryable, and a truncated
  message is still findable by text inside the budget.
- Still open in S0's spirit: the **search-results coverage badge** (the receipt
  and per-message data exist; the results-list badge is not wired yet).

### S1 — Correct the format caps — **DONE 2026-09-24**

- PST: read the header's format flag; ANSI above 2 GB → report corrupt
  (Microsoft's own rule). Unicode: drop the 50 GB refusal.
- NSF: read the ODS version; 256 GB at ODS 53+, 64 GB below, and say which rule
  applied.
- Replace every remaining "file too large" refusal with the directive's
  language: **"not tested above N GB"** plus proceed, gated by S2's preflight
  once it exists.
- **Delivered** in `SourceSizePolicy.swift`, as pure functions so the
  decisions are testable without fabricating 50 GB fixtures:
  - PST `wVer` is read from **offset 10** per MS-PST (14/15 = ANSI, ≥23 =
    Unicode, 37 = possible Windows Information Protection). An **ANSI PST above
    2 GB is now refused as corrupt** — a real format limit that was previously
    not checked at all.
  - The **50 GB PST refusal is gone.** A 60 GB Unicode PST warns ("not been
    tested above 50 GB … will not be refused") and proceeds.
  - A WIP-marked PST warns that some content may be encrypted and that anything
    undecodable is reported rather than skipped silently.
  - **NSF's ceiling is now HCL's documented 256 GB**, not 64 GB. Between the
    two the warning states plainly that Domino allows it only at ODS 53+ and
    that **mailin cannot yet read the ODS version from the header** — the
    field's offset is not documented in the sources consulted, and guessing a
    byte offset inside a forensic tool is not acceptable. `libnsfdb` and
    `sherlock-nsf-parser` are the references to mine for it.
  - The classifier attaches the verdict **before** import, so the pre-import
    sheet can warn rather than failing partway.
- Stale messages corrected: `PSTError.fileTooLarge("Maximum supported size is
  50 GB")` is replaced by `formatViolation(reason)`; the NSF message no longer
  claims 64 GB is the maximum.
- Also documented, not changed: `MBOXParser.parse` (the **non-streaming**
  array path) refuses above 500 MB because it materialises the file as a
  `String`. That is not an mbox import limit — `parseStreamingCallback`, which
  the importer uses, has no file-size ceiling.
- **Exit met:** 13 tests. Still owed: `SUPPORTED_FORMATS_AND_LIMITS.md` rewritten
  per format (format limit / tested ceiling / behaviour above it).

### S2 — Storage preflight — **DONE 2026-09-24**

- `StoragePlanner`: source bytes + blob copies + DB growth + WAL + FTS + temp
  spool + OS margin, measured per destination volume.
- Refuse only when the numbers genuinely do not fit, and say how many bytes
  are missing.
- **Delivered** in `StoragePlanner.swift`, wired into `BulkImportCoordinator`
  before any parsing begins. Refusal throws with the shortfall; a tight fit
  proceeds and lands in the run's warnings; the plan is observable so the
  import UI can show the itemised requirement.
- **Coefficients are measured, not guessed.** Importing the 94,915,160-byte
  fixture produced store 117,969,840 B (**1.243×**) and FTS 4,132,864 B
  (**0.044×**), total **1.286×**. The planner uses 1.30 for the store and
  deliberately **0.20** for the index — ~4× the measurement — because that
  corpus is attachment-heavy and the S0 budget bounds indexed text; text-heavy
  mail indexes far more. Both are P9 re-derivation targets.
- **Two bugs the preflight found in itself**, both of which would have hit
  production and not just tests:
  1. *Every import was refused.* The destination directory does not exist yet
     on a first import, `resourceValues` on a missing path reports 0 free, and
     the (correct) "unknown free space is insufficient" rule then refused
     everything. Fixed by resolving to the nearest existing ancestor — a
     missing subdirectory is not an unreadable volume.
  2. *A 95 MB import claimed it needed 10 GiB.* Overheads were flat (512 MiB
     WAL + 1 GiB spool) and the safety margin was 2 % of the volume, so the
     requirement scaled with the size of the user's **disk** rather than the
     work. Now WAL and spool scale with the source under those caps, and
     refusal uses a small 1 GiB hard floor while the volume-proportional
     margin (2 %, clamped 2–20 GiB) only decides the `tight` **warning**.
     Refusing a 95 MB import because a 500 GB disk is low was not mailin's
     call to make.
- **Exit met:** 16 tests, including the directive's own case — a 1 TB import on
  a 250 GB Mac is refused with the shortfall stated and the requirement
  itemised — and the real fixture import still succeeds through the new gate.

### S3 — External content-addressed blob tier (5–8 d, medium risk)

- `blobs/<sha256>` under the library; `email_bodies` gains
  `raw_blob_digest`, `raw_blob_length`; rows above ~8 MB store the reference
  instead of the value.
- Write-and-fsync the blob, **then** commit the row, so a crash leaves a
  collectable orphan rather than a row pointing at nothing. Add orphan GC.
- Existing inline bodies stay inline — read path handles both tiers, so no
  migration of user data.
- **Exit:** a 1.5 GB message stores and reads back byte-identical (this is the
  case that is impossible today); `ArchivePageCapabilityTests` still green;
  crash-between-blob-and-row leaves no dangling reference.

### S4 — Offset-based mbox/eml parser (8–12 d, **high risk**)

- `MessageLocator` / `PartLocator`; scan bytes with a bounded window; parse
  headers only; **never decode bodies at import**.
- Delete `MBOXParser.maxMessageBytes`.
- Guard rails that must stay green, non-negotiable: MBOX round-trip,
  source-scoped recovery report, "I/O error throws — never fake EOF",
  force-quit checkpoint reconciliation, and the 526-message fixture
  reconciling exactly.
- **Exit:** a 150 MB single message **imports** instead of being skipped as
  damaged; peak RSS during that import stays within the batch envelope; the
  fixture's numbers are unchanged.

### S5 — Locator-backed attachment and export reads (3–5 d, low risk)

- `AttachmentHydrator` switches from whole-message re-parse to seek + range
  read via `PartLocator`.
- Export streams parts from locators rather than materialising messages.
- **Exit:** attachment read cost becomes O(part), not O(message); the
  298,901-byte recovery test still passes byte-for-byte.

### S6 — Executed size tests (hardware/corpus bound)

- A synthetic single message above 2 GB (proves the S3 path and the SQLite
  ceiling argument).
- A PST above 50 GB if one can be obtained or generated.
- Record in `SCALE_RESULTS.md` with the exact host, and mark anything
  unobtainable as **NOT TESTED** rather than inferred.

### Explicitly not doing

- **Not raising `SQLITE_MAX_LENGTH`.** SQLite advises against it, and the
  external blob tier removes the need.
- **Not chunking bodies across rows.** External files are simpler, make range
  reads a plain `pread`, and are the shape iCloud Overflow already needs.
- **Not keeping whole-message re-parse** as the attachment read path beyond S5.
- **Not claiming "unlimited".** After S0–S5 the honest statement is: limited by
  free disk, the stated index budget, ANSI PST's 2 GB, NSF's ODS-dependent
  ceiling, and SQLite's ~17.5 TB database size.

### Order and why

S0 → S1 → S2 first: three low-risk steps that remove *dishonesty* (silent
truncation, wrong caps, refusals without numbers) before touching architecture.
S3 next because it is what makes >1 GB messages possible at all. S4 last among
the code steps because it is the risky rewrite, and by then S0–S3 have removed
every reason to rush it. S5 is cleanup that pays for itself in read cost. S6
converts claims into evidence.
