# mailin field contract (LIFE-03)

What the archive keeps for every message, where it keeps it, what is normalised for search, and what is
disclosed when a field is absent or transformed. This is the named contract the five-jobs plan asks for
(LIFE-03). It describes the code on branch `v3-architecture` as of 2026-11-05; the tests named at the end
hold it.

Rules the contract follows:

1. **Originals beside normalised forms.** The bytes the message arrived in are kept (inline for messages
   up to 8 MiB, in the content-addressed blob tier `sqlite/blobs/` above that; locator-backed messages
   keep the original source bytes in `sqlite/sources/<sha256>/` in self-contained mode, or a verified
   pointer into the original file in linked mode). Every normalised column below can be re-derived from
   those bytes.
2. **Nothing is invented.** A field the source did not carry is empty, not guessed; the UI says "no
   subject", "no date", "no sender" rather than filling a value in.
3. **Transformations are named.** Where a field is changed for search (lower-casing, address extraction,
   time-zone normalisation) the original string stays in `headers_json` / the raw bytes, and this document
   says so.

## Envelope and headers

| Field | Original kept | Normalised form (store) | Disclosed when absent / transformed |
|---|---|---|---|
| Every header line | `email_bodies.raw` (or blob) — the bytes as parsed, including repeated headers (`Received`, duplicate `X-` headers) | `email_bodies.headers_json`: one value per header name (the **last** occurrence of a repeated name wins; folded lines unfolded) | Repeated headers collapse in the dictionary — the raw source is the record for header forensics; stated here and in SUPPORTED_FORMATS_AND_LIMITS.md |
| From | header string in `headers_json` ("Name <addr>") | `emails.from_addr` (the header string); `email_participants` role `FROM` with `address`, `display_name`, `normalized_address` (lower-cased, angle brackets removed) | missing From → `from_addr` empty, shown as "no sender"; analytics group by `normalized_address` |
| To / Cc / Bcc | header strings in `headers_json` | `emails.to_addr`, `cc_addr`, `bcc_addr` (header strings); `email_participants` rows per address with role `TO` / `CC` / `BCC` | Bcc is kept only when the source carried it (sent mail, PST `PR_DISPLAY_BCC`); recipients filters search all three roles |
| Subject | `headers_json["Subject"]` (RFC 2047 decoded) | `emails.subject`; FTS and chunk index | encoded-word decoding failures keep the raw encoded text (visible as `=?…?=`) |
| Date | `headers_json["Date"]` — the original string **with its time-zone offset** | `emails.date` INTEGER = UTC epoch seconds parsed from the header (fallback: the source's own received/delivery stamp for PST/EMLX; else import time, marked in `anomalies`) | unparseable date → `anomalies` contains `date-unparsed`; the list shows the message under "no date" rather than today; the Advanced Search builder evaluates day bounds in a **named** zone (the sidebar's zone, shown) |
| Message-ID | `headers_json["Message-ID"]` | `emails.message_id` (trimmed, angle brackets kept); `emails.dedup_key` (unique when set) | missing → empty; duplicate detection then falls back to content classes (DUP-03), never to "same subject". Import-time policy (`DedupPolicy`, default `messageID`): a message whose Message-ID is already stored is **skipped at import** and counted on the receipt as "already imported"; `preserveAll` keeps every copy (then the Duplicates tool classifies them) |
| In-Reply-To / References | header strings | `emails.in_reply_to`, `emails.references_ids` (space-joined ids), `thread_keys` (derived thread key) | threads built only from these headers plus subject normalisation; a missing chain means a message threads alone — the thread view says "no reply headers" |
| Transport / other headers (`Received`, `X-Mailer`, `List-Id`, `DKIM-Signature`, …) | raw bytes; `headers_json` (last occurrence) | not indexed for search except where a tool asks (anomaly engine reads `Received`) | — |

## Bodies and MIME

| Field | Original kept | Normalised form | Disclosed |
|---|---|---|---|
| Raw message (RFC 5322 / MIME) | `email_bodies.raw` ≤ 8 MiB inline; otherwise `raw_blob_digest` + `raw_blob_length` → `sqlite/blobs/<xx>/<sha256>`; locator-backed (large PST/mbox messages): `message_locators` / `part_locators` + `sources/` copy or the linked original | — | A blob that is missing throws "unreadable" rather than reading as empty; linked originals that moved are listed in Settings ▸ Health ▸ Original files with Relink |
| Plain-text body | derived from raw at import (`text/plain` part, else HTML stripped) | `email_bodies.plain`; FTS (`fts5/` shards, per year) and chunk index (`search_docs` kind `body`, 48 K-character chunks, no cutoff) | an HTML-only message's plain text is a **derived** rendering; the detail view shows the HTML part |
| HTML body | `email_bodies.html` (sanitised copy for display; scripts/remote loads stripped in the viewer, never at rest) | — | remote images are not fetched unless the user asks (offline-first) |
| MIME tree (parts, boundaries, content-types) | **not stored as a tree**; rebuilt from the raw bytes when a message is opened (`MIMEParser`) | `mime_summary` text in memory only | A message whose raw bytes were not stored (pre-v2 rows) has no tree; `fidelity` backfills re-read the source |
| Inline images (`Content-ID`) | raw bytes | `attachments.content_id`, `attachments.is_inline`; the viewer resolves `cid:` links to them | an inline part the HTML references but the message lacks is shown as a broken image, not fetched from the network |
| Character sets | raw bytes keep the declared charset | bodies decoded to UTF-8 at import; undecodable bytes replaced with U+FFFD and `anomalies` gains `charset-fallback` | — |

## Attachments

| Field | Original kept | Normalised form | Disclosed |
|---|---|---|---|
| Bytes | inside the raw message (base64 / binary) or `part_locators` into the source | not duplicated as separate files; extracted on demand (Save Attachments, Attachments folder on export) | — |
| Original filename | `attachments.filename` (RFC 2231 / 2047 decoded; the decoded form is the value, the encoded form is in the raw part headers) | file-system-safe name only when written to disk (Export, Save); the inventory keeps the original | collisions on export follow the chosen rule (overwrite / skip / keep both) |
| MIME type, size | `attachments.mime_type`, `size_bytes`, `position` | — | a declared type that does not match the bytes is not "corrected"; the text extractor sniffs the bytes and records its finding in `attachment-coverage.sqlite` |
| Content hash | `attachments.content_hash` (SHA-256 of the decoded bytes) | duplicate classes compare attachment bytes by this hash | — |
| Extracted text | not an original | `search_docs` kinds `attachmentText` (PDF, Office Open XML, OpenDocument, iWork, Office 97–2003, files inside ZIPs, RTF/HTML/text — each with its sheet/slide/header/ZIP-member label), `ocrText` (scanned pages and images) and `speechText` (audio and video, on-device recognition, language named); per-attachment state in `attachment-coverage.sqlite` (extracted / truncated / noText / unsupported / locked / failed / partial, extractor version 4) | search coverage line and evidence chips name the state and kind ("Recognised text", "Recognised speech"); an attachment with no text is never silently "no match" |

## Location, memberships, flags, user data

| Field | Original kept | Normalised form | Disclosed |
|---|---|---|---|
| Source file | `sources` (sha256, filename, byte_size, parser, parser_version, imported_at, source_kind); `emails.source_id`, `source_ordinal` | — | a source whose bytes changed since import is detected before resume (checkpoint bound to SHA-256/size/parser) |
| Folder path | `RawEmail.folderPath` → `folders(path, name, parent_id, declared)` per source; immutable | `email_folders` memberships; `email_tags` (dual-written, legacy) | PST declares its tree (empty folders kept); Apple Mail / Maildir / EML folders stamp the mailbox; Maildir++ sub-folders and nested EML folders flatten to the root name — stated in SUPPORTED_FORMATS_AND_LIMITS.md |
| Labels (Gmail `X-Gmail-Labels`) | header string | memberships of the one message (FOLD-03); a label with `/` nests | occurrence counts shown per folder, unique count for the archive; the sidebar header says so |
| Flags | Apple Mail emlx plist flags → `Read`, `Deleted`, `Answered`, `Flagged`, `Draft` (`RawEmail.flags`, also in `email_tags`) | never folders; excluded from `folders` | PST `PR_MESSAGE_FLAGS` is read only for "has attachments"; read/unread and categories from PST are **not** imported in this release — stated |
| User tags | — (user data) | `email_user_tags` — separate from source tags, never written back into `email_tags` or `folders` (FOLD-04) | — |
| Annotations, legal holds, review state, evidence seals, custody | — (user data) | `email_annotations`, `legal_holds`, `email_review_state`, `evidence_seals`, `custody_events`, `custodian_assignments` | holds block deletion in every path, including duplicate removal and when the Professional interface is off |
| Deletions | — | Trash = `emails.trashed` soft state (restorable); permanent delete writes `deletion_tombstones` (identity kept) so a re-import does not resurrect silently | — |

## Jobs that run together

Every tool streams the store in bounded batches on its own connection statement; writes go through the
single actor connection. Consistency rules the LIFE-03 test holds:

- An **import** running during **search**: counts and pages never fail; a count taken later is never
  smaller than one taken earlier (append-only during import).
- An **import** running during **duplicate review**: the Message-ID groups are read once; verification
  loads the members in chunks; a group whose members changed under it is reported as a candidate, never
  removed.
- An **import** running during **export**: the export's query scope is frozen at its start
  (`EmailQuery.snapshotMaxRowID`, OUT-02), so the inventory lists exactly the messages selected then.
- **Two exports** at once write to two folders with two manifests; each inventory verifies clean.

## Tests that hold this contract

- `V2CutoverTests.testLIFE03_importDuringSearchDuplicateReviewAndExport_staysConsistent`
- `V2CutoverTests.testFOLD02_*` (folders, labels, flags), `testFOLD03_*`, `testFOLD04_*`
- `V2CutoverTests.testOUT02_*` (frozen selections), `testOUT07_*` (inventory)
- `V2CutoverTests.testFIND03_*` (attachment states), `testFIND05_*` (evidence names the real place)
- `V2VerificationTests.testArchiveDataService_matchesArrayOracle` (headers / participants / dates round-trip)

## Raw source of messages read from binary mail files (added 2026-11-07, §13.8 step 6)

A message read from a PST, OST, MSG, OFT or NSF file has no RFC 5322 bytes of its own. Until
2026-11-07 such a message was stored with an empty raw source, and because the archive keeps
attachment BYTES only inside the raw source (`AttachmentHydrator` re-extracts them from it), every
attachment of such a message was lost when the import ended — not openable, not searchable, not
exported, not comparable for duplicates. `testCOMP15_theSameMailInFourFormats_*` found it.

**Rule now:** the parser renders the message as RFC 5322 (`RFC822Renderer`, the same rendering
the OLM reader always used) and stores that as the raw source, with the header
`X-Mailin-Rendered: <source format>` as the first line so the provenance is never hidden. The
original record fields (headers, bodies, attachment metadata) are unchanged; the rendering is
derived from them and from the attachment bytes the parser produced. Real source bytes (mbox,
.eml, .emlx) are never replaced. Duplicate verification therefore classifies four renderings of
one message as **content-equivalent** (never byte-identical: the rendered boundaries differ).
