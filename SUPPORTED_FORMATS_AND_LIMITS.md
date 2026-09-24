# Supported formats and limits

Owed since S1 of `SIZE_LIMITS_DESIGN.md`. This file states what mailin reads,
how it decides, and where the real ceilings are — separating three things that
kept getting conflated:

- **format limits** — what the file format itself cannot exceed;
- **product limits** — what the tool that wrote the file allows;
- **mailin limits** — what this code does, including what has actually been
  executed against a real file versus what is only expected to work.

Every number below points at the constant or check that enforces it. Where a
claim rests on a measurement, the measurement is named; where it rests on
nothing yet, it says so.

Last updated: 2026-09-24.

---

## 1. How a source is routed

Routing is by **content**, not by filename — `SourceFormatClassifier.classify(url:)`.
The extension is a hint that is reported, never the deciding factor.

Before this, `ParserFactory` switched on `pathExtension`, which produced two
real defects:

- a PST/OST/ZIP/gzip file named `.mbox` reached the MBOX parser, which has no
  signature check, and manufactured junk "messages" from binary — silent
  corruption of an archive;
- a valid mbox named `mail.txt` or `Takeout-1` was rejected as unsupported.

The classifier reads the first **64 KB** (`probeBytes`) and never more. Its
decision carries the evidence for itself, so the import receipt can state why
a file was routed where it was, and a name/content disagreement is surfaced
(`nameContentMismatch`) rather than hidden.

| Detected by | Signature / structure |
|---|---|
| PST / OST | `!BDN` at offset 0 |
| MSG | OLE compound-document signature `D0 CF 11 E0 A1 B1 1A E1` at offset 0 |
| NSF | `1A 00` at offset 0 |
| ZIP | `PK\x03\x04` or `PK\x05\x06` at offset 0 |
| gzip | `1F 8B` at offset 0 |
| EMLX | leading decimal byte count, then an RFC 822 header block |
| mbox | one or more `From ` separators at start of line, with a 4-digit year |
| EML | ≥ 2 recognised RFC 822 header lines and no mbox separator |
| Apple Mail package | directory containing `mbox` and/or `Info.plist` |
| Maildir | directory containing `cur/`, `new/`, `tmp/` |
| `.emlx` folder | directory containing one or more `.emlx` files |
| `.eml` folder | directory containing one or more `.eml` files |

Binary content is rejected as text before any mbox/eml guess: more than 64
control bytes in the first 4 KB and the file is `unknown`, whatever it is
called.

### Directory sources

Apple Mail packages, Maildirs and `.eml` folders are directories — the
messages are in files *inside* them. `SourceFormatClassifier.expand(_:format:)`
resolves them to the files that get parsed, in a stable sorted order, and the
import streams member-by-member so peak memory stays bounded by one member's
batch rather than by the whole mailbox. Maildir `tmp/` is deliberately skipped
(it is delivery scratch space). A folder of `.emlx` is handed to `EMLXParser`
whole, because that parser reads a directory natively.

---

## 2. What each format delivers

| Format | Parser | Streams? | What is extracted | Known caveats |
|---|---|---|---|---|
| mbox | `MBOXParser` | **Yes** — bounded memory, adaptive batches | Headers, MIME tree, bodies, attachments, Gmail labels → tags, thread links | Single messages above 100 MB are reported as damaged, not truncated (see §3) |
| eml | `MBOXParser` | Yes | As mbox; a missing `From ` envelope is synthesised | — |
| emlx | `EMLXParser` | No | Per-file parse with a damaged-file report (`ParseResult.summary`) | Whole set materialises before draining |
| msg | `MSGParser` | No | OLE2 → MAPI properties (sender, recipients, subject, bodies, attachments) | Refuses above 2 GB; one message per file |
| pst / ost | `PSTParser` | No | In-house NDB reader: node + block B-trees, MAPI property contexts, attachment subnodes, OST `permute`/`cyclic` decode | Not executed above 50 GB (see §4); WIP-protected content is reported, not silently dropped |
| nsf | `NSFParser` | No | Structured note records with LZSS decompression and LMBCS strings, attachments by item | Falls back to a **heuristic text scan** when the structured parse finds nothing — fidelity is lower on that path and it is not byte-exact |
| Apple Mail package | `MBOXParser` per member | Yes | As mbox | Reports "nothing to import" when no `mbox` file is inside |
| Maildir | `MBOXParser` per member | Yes | As eml, one message per file | `tmp/` skipped by design |
| ZIP | — | — | **Refused** with advice to unzip first | No bounded extraction ships yet; mis-parsing the archive as mbox would be worse |
| gzip | — | — | **Refused** with advice to decompress first | Same |

Non-streaming parsers (`pst`, `ost`, `nsf`, `msg`, `emlx`) materialise the whole
result before draining it in bounded chunks. The adaptive batch envelope's
*message* bound is honoured on that path; its *byte* bound is not, because the
messages already exist by then. Wiring those parsers to the envelope is tracked
as P3.2.

---

## 3. mailin's own limits

| Limit | Value | Where | Consequence |
|---|---|---|---|
| Single message on the non-streaming path | 100 MB | `MBOXParser.maxMessageBytes` | Counted as damaged (`oversized_message`) and skipped with a clean report — never truncated, never an OOM. **Removing this is task S4.** |
| Indexed text per message | 4 MiB | `FTSSearchIndex.indexedTextBudgetBytes` | Text beyond the budget is **searchable only up to the budget**. Coverage is recorded per message (`indexed_text_bytes` / `total_text_bytes`) and reported, replacing a silent 50,000-character truncation. |
| Inline blob threshold | 8 MiB | `BlobStore.inlineThresholdBytes` | Above it, content goes to the content-addressed store instead of a row |
| Source file size | **none** | — | The streaming path is bounded by the batch envelope, not by file size |
| Message count | **none** | — | No count cap anywhere in the import path |
| Attachment size | **none** beyond the format's own | — | Attachments are re-extracted from `rawSource` on demand (`AttachmentHydrator`) |

### Storage preflight

An import is refused before it starts if the destination cannot hold the
result. `StoragePlanner` estimates from **measured** coefficients:

- store ≈ **1.30 ×** source bytes,
- FTS index ≈ **0.20 ×** source bytes,
- plus WAL and spool scaled to the source, not flat.

Refusal needs a genuine shortfall (hard floor 1 GiB); a *tight* result is a
warning, not a refusal (comfort margin 2 % of the volume, clamped to
2–20 GiB). Measured on the 95 MB reference import: store 1.243 ×, FTS 0.044 ×,
total **1.286 ×** of source — i.e. the planner's estimate is conservative
against the one case that has been measured.

---

## 4. Format and product ceilings mailin enforces

`SourceSizePolicy` decides from documented limits rather than from a number we
picked. Three verdicts: `ok`, `warn` (proceed, having told the user something
true), `refuse` (a documented limit says the file cannot be what it claims).

### PST / OST

`wVer` is read from MS-PST `HEADER` offset `0x0A`: 14–15 = ANSI, ≥ 23 =
Unicode, 37 additionally flags possible Windows Information Protection.

| Condition | Verdict |
|---|---|
| ANSI (`wVer` 14/15) and > **2 GiB** | **Refuse** — Microsoft caps ANSI at 2 GB "to prevent corruption", so the file is corrupt, truncated or mislabelled |
| `wVer` == 37 | Warn — may contain WIP-encrypted content; anything undecodable is reported, not skipped silently |
| > **50 GB** | Warn — that is Outlook's *default* `MaxLargeFileSize` (51,200 MB), registry-configurable upward, and mailin has not been executed above it. **Not refused.** |
| Header unreadable | `ok` — let the parser report the structural problem; size is not the interesting fact |

The previous code refused everything above 50 GB as though that were a format
limit. It is not, and that refusal rejected real evidence files.

### NSF

| Condition | Verdict |
|---|---|
| > **256 GiB** | **Refuse** — HCL documents 256 GB as the maximum database size (ODS 53+), so no supported Domino configuration produces this |
| 64 GiB – 256 GiB | Warn — valid only at ODS 53 or later; below that the maximum is 64 GB |
| ≤ 64 GiB | `ok` |

**Recorded limitation:** mailin cannot yet read the NSF **ODS version** from
the header. The field's offset is not documented in the sources consulted
(libyal `libnsfdb`, the `sherlock-nsf-parser` crate), and guessing a byte
offset inside a forensic tool is not acceptable. So a file between the two
ceilings is accepted **with a warning that says exactly this**, rather than
pretending to either capability or certainty.

The previous code refused above 64 GB, which is the *pre*-ODS-53 limit.

### MSG

Refused above 2 GB (`MSGParser.MSGError.fileTooLarge`). This is a mailin limit
— the whole file is read into memory — not a format limit.

---

## 5. Export

| Target | Status |
|---|---|
| mbox | Round-trip verified: 526 messages exported → 526 re-parsed → 526, 94,929,888 bytes. Writes a real `From_` envelope (`MBOXRecordBuilder.envelopeLine(for:)`) and includes attachments as base64 MIME parts, marked `X-Mailin-Reconstructed` when the record was synthesised rather than byte-copied. |
| mbox, partitioned | `ArchiveExportService.exportMBOXPartitions(...)` splits on a byte budget, never mid-message — for destinations such as exFAT with a 4 GB single-file limit |
| PDF (Bates) | Stamp verified by PDFKit read-back in `BatesPDFReadBackTests` — **written, not yet executed** |

Export of a *reconstructed* message is not byte-identical to the source and is
labelled as such. Byte-exact export requires the original bytes, which is what
the offset-index work (S4/S5) exists to preserve.

---

## 6. What is NOT supported

- **ZIP / gzip containers** — refused with instructions, not silently
  mis-parsed.
- **Encrypted PST/OST beyond the documented permute/cyclic obfuscation** —
  password-protected files are not decrypted.
- **Live mail accounts** — Page 4 ships default-off and its features are
  `.notInThisBuild` in this release.
- **Anything hosted in iCloud as the active store** — Apple's rule is explicit
  that a SQLite store file must never be stored in iCloud; WAL separation
  causes corruption. Not a mailin choice.

---

## 7. Verification status

Honest split, because "supported" and "tested" are different claims:

| Claim | Evidence |
|---|---|
| mbox import, search, export | **Executed** — 526-message archive: attachment 298,901/298,901 bytes recovered, 50 of 526 search hits, 526 → 526 → 526 export round-trip |
| Growth coefficients | **Measured** on that archive (1.243 × / 0.044 × / 1.286 ×) |
| Zero network activity | **Measured** — 0 network sockets in a Release run; `OFFLINE_MODE` in both configurations and no network entitlement |
| Format classification | Unit-tested (`SourceFormatClassifierTests`) |
| Size policy verdicts | Unit-tested (`SourceSizePolicyTests`) |
| Directory-source import (Apple Mail package, Maildir, `.eml` folder) | **Implemented, not yet executed against a real export** |
| PST / OST / NSF / MSG import | Code paths exist; **no executed fixture run is recorded** |
| PST above 50 GB, NSF above 64 GB | **Never executed.** The warnings say so. |
