# Notes ODS reader (GAP-NSF) — sources and what was checked where

Reader: `Sources/ArchiveCore/NSFODSReader.swift`, `NSFODSParser.swift` (switch `NotesODSPolicy.isEnabled`,
preview, off by default). Tests: `NSFODSReaderTests.swift`. Written 2026-11-07.

## Sources used

| Source | URL | Used for | Licence / use |
|---|---|---|---|
| Joachim Metz, "Notes Storage Facility (NSF) database file format" | https://github.com/libyal/libnsfdb/blob/main/documentation/Notes%20Storage%20Facility%20(NSF)%20database%20file%20format.asciidoc (raw: https://raw.githubusercontent.com/libyal/libnsfdb/main/documentation/Notes%20Storage%20Facility%20(NSF)%20database%20file%20format.asciidoc) | file/database header fields, DBINFO2 superblock and BDB positions, superblock header, bucket descriptor pages, BDB header, RRV buckets and BSID entries, bucket header and back-to-front slot index, note header, note item entry, note class / item class / item type tables, TIMEDATE, CX compression outline | GFDL 1.3 document, read |
| libnsfdb C sources (`libnsfdb_io_handle.c`, `libnsfdb_compression.c`, `libnsfdb_rrv_bucket.c`, `libnsfdb_bucket.c`, `libnsfdb_note.c`, `libnsfdb_unique_name_key_table.c`, `nsfdb_*.h`) | https://github.com/libyal/libnsfdb (archive: https://github.com/libyal/libnsfdb/archive/refs/heads/main.tar.gz) | understanding only: the CX bit order, the 66-byte BDB header, UNK table layout (10-byte entries + 4 bytes, then text), superblock data layout (8,206-byte summary page, 8,198-byte non-summary page, 20-byte bitmap descriptors, then the current RRV bucket) | LGPL-3.0; read for understanding, **no code copied** — the Swift is written from the layout description and checked on the sample |
| HCL Domino C API reference (TIMEDATE, FILEOBJECT, OBJECT_DESCRIPTOR, MIME_PART, RFC822ITEMDESC, CD record signatures SIG_CD_TEXT / SIG_CD_PARAGRAPH, BSIG/WSIG/LSIG) | https://opensource.hcltechsw.com/domino-c-api-docs/ (pages `reference/Data/MIME_PART/`, `…/FILEOBJECT/`, `…/TIMEDATE/`, `…/RFC822ITEMDESC/`, `…/CDTEXT/`) | structure layouts of item values inside notes | public reference; the pages render by script and their text could not be fetched in this session, so these layouts were written from prior knowledge of the C API headers and are trusted only where the sample confirms them byte for byte (RFC822ITEMDESC, MIME_PART, FILEOBJECT and TIMEDATE lengths add up exactly on every mail note; CDTEXT/CDPARAGRAPH are NOT confirmed by the sample) |

## What the public sample showed (and the reader now relies on)

File: `~/Downloads/Mail/Fixtures/opensource/aspose-email-net/SampleNSF.nsf`, 47,448,064 bytes, ODS 43,
SHA-256 `0d71b76912ed8f448394ea9d2f77d93d5e2dc43465425f3b62b677f67340c03b` (pack SHA256SUMS).

- DBINFO2 starts at 0x208 in the 1,024-byte database header (superblocks at 0x400 / 0x8400 / 0x10400 as
  listed there; the third has no signature). Highest write count wins (167 vs 165; BDB 295 vs 294).
- BDB header is 66 bytes; compressed data = 4-byte length + CX stream (as for superblocks).
- The on-disk data RRV bucket at 0xA0B000 is all 0xFF; the current copy lives inside the superblock data
  (first note ID 0x10E6) — without it no document is reachable.
- Note IDs step by 4 within an RRV bucket; four buckets (first IDs 0x106, 0x8F6, 0x10E6, 0x18D6).
- Non-summary record: LSIG 0x0010, 68-byte header, then the non-summary values in item order.
- A value whose type differs from its name key's type carries a 2-byte type word when item flag 0x0008
  is clear (PostedDate: 0x0502 RFC822 text; $FILE: 0x?? 03 object).
- A few items sit on the other side of their ITEM_SUMMARY flag (non-summary-flagged $MessageID/$TUA in
  the slot; summary-flagged x_originating_ip in the non-summary record). The reader places items by the
  exact non-summary length the header states and validates RFC822 (0x000E) / MIME_PART (0x0002) versions.
- Deletion stubs are 64-byte note records (no items).
- The file is damaged in about a dozen single bytes (e.g. "Aspo{e.Cells", "ne~sletter", "newslettar",
  "Documeot", "=?QTF-8?", "Wed, 3!Oct 2018", "Re\x7Furn-Path", "sdmit@jm.ru", "sdmit@km.rr", a 0x0E for a CR,
  a FILEOBJECT name length 0x0108 for "mime.htm", an RFC822 name length 0x0F for "Message-ID", one
  PostedDate TIMEDATE day field). Each was confirmed by searching the raw bytes; the reader reproduces the
  bytes and names the structural ones on the message.

## Independent checks made (no Notes client on this Mac)

Scratch Python scripts (not shipped) scanned the raw bytes without using the ODS structure:
44 "Subject: …\r\n" lines (the 45th is the one with 0x0E for CR), 46 distinct "Message-ID: <…>" lines
(45 in mail notes; the 46th lies in free space of summary bucket 73, outside every slot), 45 "Date:" texts,
76 bucket signatures at 256-byte-aligned offsets. The prototype's reassembled messages were also parsed with
Python's `email` package (MIME tree intact apart from the damaged bytes). The Swift tests repeat the checks
that need no external tool.
