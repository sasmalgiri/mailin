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
| gzip | `1F 8B` at offset 0 (`.tgz` / `.tar.gz` included — the payload is then classified on its own bytes) |
| tar | `ustar` magic at offset 257, or a pre-POSIX header block whose checksum verifies (checked before the text rules, because a tar of mbox files begins with a header followed by mail text) |
| OLM (Outlook for Mac) | ZIP signature **and** a central directory holding `com.microsoft.__Messages/` records — decided from the directory, so a renamed `.olm` is still an OLM and a plain ZIP named `.olm` is still a ZIP |
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

**Executed 2026-09-25** (`DirectorySourceImportTests`, synthetic layouts built
to the structures above): Maildir with `cur`/`new`/`tmp` → 3 of 4 messages
(the `tmp` one skipped); folder of four `.eml` plus a `README.txt` → 4; Apple
Mail package with `mbox` + `mbox.toc` → 2; a Maildir with empty `cur`/`new`
is refused rather than imported as zero. Each layout ran through BOTH parser
entry points and both agreed. Running this found that the streaming path had
never produced a message from a bare `.eml` (see the `eml` row below). A real
client export (Apple Mail, Dovecot) has still not been run.

**Executed 2026-09-27 at 1 GB per form** (`FormatMatrixScaleTests`, real
messages replicated from the owner's mailbox — `SCALE_RESULTS.md`): EML folder,
Maildir, Apple Mail package and `.emlx` folder each import 5,786 of 5,786 and
reconcile exactly; the mixed row (mbox + EML folder + ZIP + Maildir) imports
4,208 with zero duplicates. **This run found that no folder source had ever
imported through the production path**: `BulkImportCoordinator` hashed every
source through a file handle for chain of custody, which fails on a directory,
so every folder import ended with "the file doesn't exist" and zero messages
before a parser was reached. Directory sources now get a digest over their
sorted members. Per-file sources are ~3.4× slower than a single file of the
same bytes (FTS shard eviction thrash between members) — a 3.1 tuning item.

---

## 1a. Format registry (generated — do not edit by hand)

One machine-readable list, `FormatCapabilityRegistry` (ArchiveCore), is the source of this table, of
Settings ▸ Health ▸ Formats and of the acceptance rows in the tracker. `testWP4_formatRegistryCoversEveryKind_*`
fails when this table and the registry differ. Evidence is kept apart from implementation: "spec-built
fixtures" is not "real files", and "not implemented" is said plainly.

<!-- format-registry:begin -->
| Family | Format | Extensions | What is read | Evidence | Limitation | Still needed |
|---|---|---|---|---|---|---|
| Mail source | mbox | mbox | every message, MIME tree, attachments, Gmail labels, thread links; offset engine streams any size | real files | — | — |
| Mail source | RFC 822 message | eml | single messages and folders of them, with the folder as mailbox; sub-folders of a folder are kept as folder paths (Clients/Acme) | real files | — | — |
| Mail source | Apple Mail message / library | emlx | messages with flags, the mailbox chain from the library layout; a file of any size is read by range (one above the full-parse ceiling by a byte locator, its text and attachments streamed after import) | real files | — | — |
| Mail source | Apple Mail mailbox package | mbox (package) | the mbox inside, mailbox chain | spec-built fixtures | — | a real Apple Mail export (owner) |
| Mail source | Maildir / Thunderbird folder | cur, new | one message per file; the root as the inbox (the folder's own name), Maildir++ sub-mailboxes (.Sent, .Archive.2024 → Sent, Archive/2024) and nested mailboxes (Lists/Swift/cur) as their own folders, empty ones declared | spec-built fixtures | tmp/ (deliveries in progress) skipped and counted; cur/new/tmp are never folder names | a real Dovecot/Courier Maildir++ export |
| Mail source | Outlook message / template | msg, oft | MAPI properties: sender, recipients, subject, bodies (plain, HTML, RTF), attachments; embedded messages expanded as attached messages (three levels); .oft templates read as messages; a file of any size is read through a file handle (one above the full-parse ceiling is rendered to RFC 5322 inside the archive with bodies and attachments streamed, then imported by range) | real files | 17 Outlook-written messages from the Apache Tika and POI corpora (Unicode, Cyrillic, Chinese, HTML bodies, attached PDF/DOC, an embedded message) read with subject, body and attachments; .oft verified on Microsoft's official template (22 inline images byte-exact with their Content-IDs) | — |
| Mail source | Outlook data file | pst | ANSI and Unicode; folders including empty ones, recipients, bodies, attachments by the MS-PST layers; non-mail items counted out | real files | bCryptMethod 0 (none), 1 (compressible / permutation) and 2 (high / cyclic) decoded on read (spec-written files of each kind read back through both entry points); 0x10 (Windows Information Protection) refused by name — those blocks are encrypted with a key held by Windows; the Outlook password (PidTagPstPassword) is a CRC, not encryption: such files are read in full and the import receipt says so | small real PSTs with empty/deep/Unicode folders for the candidate run |
| Mail source | Outlook offline store | ost | shares the PST reader; the 4 KiB-page OST of Outlook 2013 and later (wVer 36) is read by its own page geometry (4096-byte B-tree pages, 24-byte trailers, 512-byte block alignment) with its zlib-compressed blocks inflated (BBTENTRY cbInflated); OLE attachments (ATTACH_OLE) read from their subnode stream | real files | executed 2026-11-07 on two real files: Aspose SampleOstFile.ost (wVer 23, permute-encoded) — 87 of 87 mail items, 5 calendar items counted out, folders and Message-IDs equal to readpst's, all 36 readpst attachment payloads byte-identical; java-libpst example-2013.ost (wVer 36, 62 compressed blocks) — 3 of 3 messages with subjects, Message-IDs, dates and folders equal to readpst's. Outlook 2013 places the DList/AMap pages elsewhere than the spec writer's ost4K layout does (reader unaffected). No encrypted 4 KiB-page OST has been seen | an encrypted (bCryptMethod 1/2) version-36 OST |
| Mail source | Lotus Notes database | nsf | default (switch off): the old heuristic — scans the file for item records in mailin's own synthetic layout, then for 'Form: Memo' text lines. Preview Notes ODS reader (NotesODSPolicy, off by default): database header, the newest CX-compressed superblock (every summary and non-summary bucket descriptor page it declares) and bucket descriptor block, every RRV bucket, note headers, summary and non-summary item values; mail notes (Memo/Reply, or no Form with From/SendTo) rebuilt as RFC 5322 — native-MIME mail from its RFC822 header items and MIME parts in order, with parts kept in attachment objects restored byte for byte; Notes rich-text mail as plain text with header fields from From/SendTo/CopyTo/BlindCopyTo/Subject/PostedDate/$MessageID and $FILE attachments; attachment objects stored plain or Huffman-compressed (checksum-checked); folder membership from every folder's $FolderIDTable (nested by \, a message in several folders keeps them all; folders declared, empty ones included; hidden helper folders only when they hold mail); sealed (encrypted) messages keep their unsealed items, the sealed ones named; design notes, deletion stubs, profiles and other documents counted by class and form, never imported; what a message could not give back is named on it | spec-built fixtures | default heuristic: executed 2026-11-07 on the public Aspose SampleNSF.nsf (47 MB, ODS 43) — 0 notes read; not verified, do not claim NSF import with the switch off. Preview ODS reader, executed 2026-11-07 on the same file (no Notes client available; checks made against the file itself): 1,626 RRV entries accounted for (1,412 note records + 203 objects + 11 entries whose slot carries another note ID); 1,030 design notes, 323 deletion stubs, 3 empty and 11 non-mail documents counted out; 45 of 45 mail notes read (all native MIME), 42 of 42 attachment objects decoded; every From and Message-ID line, and every Subject line, found verbatim in the database bytes; 43 of 45 Date headers equal the TIMEDATE stored beside them (the other two are damaged in the file); the one MIME attachment (7,655-byte PNG) byte-identical to the file. The sample has no Notes rich-text mail, so rich-text bodies (text runs and paragraphs only — no tables, fonts, links or embedded images) are verified on synthetic CD records only. Folders (R6, executed 2026-11-09 on the same file): 11 folders read, 0 unread; all 45 mail notes in Inbox (the Inbox ID table's 343 IDs in 6 runs equal its stated count, and each of the 45 is also in the Inbox's $FolderObject records with its own UNID); folders declared: Inbox, Junk Mail, Trash, Drafts, Sent, Parus; the sample's three Huffman objects (design-note bitmaps) decode to their stated sizes with matching checksums and BMP headers. The sample has one bucket descriptor page, no LZ1 object, no multi-record object, no sealed mail and no nested folder, so those are verified on a synthetic database only (two descriptor pages, nested folder, Huffman attachment, sealed mail). Not read: LZ1-compressed attachment objects (no public description, no sample) and objects longer than their one record (continuation layout not described anywhere, none in the sample) — named on the message, bytes not returned; sealed (encrypted) items — they need the recipient's Notes ID file, named on the message; folders without a $FolderIDTable (membership only in the folder collection, not decoded) — named in the inventory; databases whose descriptor pages do not all point at buckets are refused with that reason. Preview, off by default until the owner verifies a database of their own | the owner's own Notes mail database (with folders, rich-text mail and attachments) and an independent inventory of it from Notes or Domino |
| Mail source | Outlook for Mac archive | olm | every message record rebuilt as RFC 5322 with folder, read/flag state, categories, priority, sent and received times, attachments' bytes with Content-IDs; contacts, contact groups, calendar, tasks and notes counted per record, never imported | real files | executed 2026-11-07 on two real archives against an independent XML inventory: Aspose SampleOLM.olm — 22 of 22 mail records, 38 of 38 attachment occurrences byte-identical (24 with Content-ID), 11 folder paths, 3 contacts counted; Outlook 16 outlook_example.olm (teverett/OLMReader) — 7 of 7 records, 9 of 9 attachments, 5 contacts / 2 groups / 8 appointments / 5 tasks / 1 note counted. Times are read as UTC (Outlook writes no zone). Native pair (2026-11-09, the owner's supplied pack): one mail exported by Outlook for Mac 16.112.4 (Legacy mode) as OLM and by Apple Mail 16.0 as MBOX (plus the EML derived from it), imported, searched and exported as .eml by mailin — subject, From, To, HTML, both attachments' bytes/SHA-256 and the inline CID equal the pack's oracle across all three; the MBOX has no Date or Message-ID and none is claimed equal to the OLM's; the OLM's declared attachment sizes are not used, the real bytes are. One message only, not an identical-mailbox set: no native PST/OST/NSF of it exists | a native OLM of a larger, controlled mailbox exported by the same clients (optional; the one-message pair is run) |
| Mail source | ZIP / gzip / tar of mailboxes | zip, z01…zNN (spanned), gz, tgz, tar | each member classified on its bytes and imported; an archive inside it (ZIP, gzip, tar, 7z, RAR) is opened at every level, with folders from every level; a spanned ZIP set (archive.z01 … archive.zip) is read with the volumes in the same folder, a member on a missing volume refused and counted; an interrupted import resumes after the last finished member | spec-built fixtures | encrypted members, other compression methods and unsafe member paths (absolute, drive letter, ..) refused and counted with their reasons; an archive that contains itself, or one more than 32 archives deep, is skipped and counted; spanned sets verified on Info-ZIP (zip -s) output written at test time, nesting on spec-built archives and bsdtar/gzip output | — |
| Mail source | 7z / RAR of mailboxes | 7z, 7z.001…, rar, part1.rar…, r00… | 7z: each member decoded (Copy, LZMA, LZMA2, BCJ x86, Delta, Deflate) and classified on its bytes, a split .7z.001 set read with the volumes beside it; RAR: stored members copied and compressed members decoded (RAR 2.9–4.x, RAR 5.0 and RAR 7.0, solid archives included, through the vendored libarchive 3.8.11 reader, patched; RAR 1.5 and 2.0 by mailin's own decoder; CRC-32/BLAKE2 checked), a multi-volume set (name.part1.rar … or name.rar + name.r00 …) read with the volumes beside it | spec-built fixtures | 7z members in BZip2/PPMd/BCJ2/ARM…, encrypted members (no password on import) and members on a missing volume are refused and counted; RAR: encrypted members and headers (no password is asked for on import), RAR 1.5/2.0 solid members after the first and RAR 1.5/2.0 encryption, a RAR 5.0/7.0 member whose decoding window exceeds the device limit (a quarter of its memory, at most 4 GiB) or whose header records no unpacked size, and members running into a missing volume are refused and counted; RAR 4 solid decoding verified only on libarchive's encrypted solid file and its decrypted form (libarchive's suite has no other RAR 4 solid archive); the RAR source path (member extraction, preflight, a four-volume set opened from its second volume) run on WinRAR-written archives from libarchive's test suite, which hold no mail — a mailbox imported from a compressed RAR has not been run; the 7z import on spec-built archives and the 7z reader on bsdtar/7-Zip files | a real 7z / RAR mail export (owner) |
| Attachment | Word, Excel, PowerPoint (Office Open XML) | docx, docm, dotx, xlsx, xlsm, xltx, pptx, pptm, ppsx, potx | body, tables, text boxes, headers/footers, footnotes, endnotes, comments; tracked changes labelled inline with author and date — insertions, deletions, moved text ({moved from} / {moved to}, never counted as insertion or deletion), formatting changes ({formatting changed}), revised paragraph marks and table rows — in the body, headers, footers, footnotes, endnotes, comments and text boxes, each also listed with its part and paragraph; every sheet (hidden and very hidden ones marked) with cell addresses, the stored result and the formula text (shared formulas re-based on the cell), number-formatted cells rendered as Excel displays them (dates, times, elapsed time, percentages, currencies, fractions, scientific, thousands and scaling, conditional sections, literal text; the 1900 system with its 29 February 1900 and the 1904 system), the stored serial or value kept beside the rendered text, hidden rows and columns labelled, defined names (hidden ones marked), external workbook references listed and never refreshed, comments, the 1904 date system stated; slides (hidden marked), notes, comments; chart titles, labels and values; embedded documents as child documents; Transitional and Strict namespaces | real files | number formats are rendered in en-US whatever the author's locale (built-in 14 shows m/d/yyyy, English month and day names), without column-width effects (no * fill, no ####), native digits ([DBNum]) or era years (b, e, g); checked row by row against Excel's cached TEXT() results in Apache POI's format workbooks (number, General, date, elapsed, condition and text tests); a shared-formula reference that would leave the sheet is named, not shifted; Tika's Office files cover charts, comments, embedded objects, text boxes, Strict, real moves (testWORD_features) and shared formulas / date formats (testEXCEL, testEXCEL_dateFormats); tracked changes verified against the public pack's structured record (W05: two insertions, one deletion with author and date; W01/W06/W07 none) | — |
| Attachment | Word, Excel, PowerPoint 97–2003 | doc, dot, xls, xlt, ppt, pps, pot | Word text through the piece table; Excel cells with addresses, formula results, comments, hidden sheets; PowerPoint slide text | spec-built fixtures | .doc verified on a real file; .xls/.ppt on spec-built records; number formats not applied | real .xls / .ppt files |
| Attachment | OpenDocument | odt, ott, ods, ots, odp, otp | body, headings, lists, tables (numbers and dates), sheets by name, slides and their notes, headers/footers (text, sheets, presentation master pages), footnotes, comments with their author, embedded objects as their own section; encrypted packages locked, or opened with a password (Blowfish CFB, AES-CBC, AES-256-GCM; PBKDF2 or Argon2id over a SHA-1/SHA-256 start key), per entry or as LibreOffice 24.2's single encrypted-package | real files | verified on 21 OpenOffice.org 2/3, NeoOffice and LibreOffice files from Apache Tika (incl. the LibreOffice-encrypted one, password known), asserting Tika's own phrases; Argon2id (RFC 9106, checked on its test vectors) verified on two files encrypted with LibreOffice's parameters by the reference libargon2 and OpenSSL — no LibreOffice-written Argon2id file yet; Argon2id over 1 GiB of memory or 1,000 passes is reported by name; AES-128/192-GCM not read; macros listed and never run; formula (.odf) and drawing (.odg) documents are not read | — |
| Attachment | Pages, Numbers, Keynote | pages, numbers, key | iWork '09 XML (plain or gzip): paragraphs, table cells row by row with numbers, formula results, dates and pop-up menus, table and chart names with their labels, Pages headers/footers per page with the auto page number in the document's style, footnotes, comments, text boxes, Keynote slides, notes and master slides, Numbers sheets; IWA 2013+ (snappy + protobuf): text storages, slides, tables row by row from their tiles with numbers, dates, durations, booleans, formula results, text and rich text, named with their sheet; the 2018 zipped bundle with its inner Index.zip; password-protected '09 documents (Apple ZIP methods 25451/25452) locked, or opened with the password (PBKDF2-SHA1 + AES-128-CBC); password-protected 2013+ documents (.iwpv2 verifier, encrypted Index/*.iwa — single file or bundle with Index.zip) locked, or opened with the password (PBKDF2-SHA1 with the document's salt and iterations + AES-128-CBC) | real files | verified on 22 Pages/Numbers/Keynote '09, 2013 and 2018 files from Apache Tika, asserting Tika's phrases, and the IWA cell values against the '09 version of the same workbook; the 2013 files use the older (pre-Numbers 5) cell storage; the newer one is read on a current Numbers file's text cells, its numbers (decimal128), dates, booleans and durations checked on records built from the published layout only; number formats (decimal places, currency symbols, percentages, custom formats) and pop-up menu choices are not applied — the stored value is shown; placeholder (ghost) text excluded; protected '09 unlock verified on Tika's Pages file (password known) only — Keynote/Numbers '09 use the same scheme but no protected sample; protected 2013+ unlock verified on Pages, Numbers and Keynote 14.4 files saved with a password through AppleScript (synthetic content, single file; Pages also as a zipped package bundle), each giving the same text as its unprotected twin — no Numbers/Keynote bundle sample, no document from an older 2013+ app version; each member's 20-byte trailer is not checked (its keying is not public), so the decrypted content's integrity is not cryptographically verified and every reading opened this way says so — the verifier checks only the password, and the padding and IWA framing catch only damage they can see (a damaged member is named: bad padding fails the document, garbled framing lists the member as not read; tested by flipped bytes in the Pages file); the unlock streams member by member through scratch files, so memory does not grow with the member count (checked on a 400-member synthetic document built from the scheme), and a cancellation or a full disk stops it with nothing half-written left; the password hint (.iwph) is not shown | — |
| Attachment | PDF | pdf | text layer; scanned or mixed pages recognised page by page (OCR on); locked files reported | real files | no password entry for locked PDFs | — |
| Attachment | Images | png, jpg, jpeg, tiff, heic, gif, bmp, webp | recognised text (OCR on), failures named per image | real files | — | — |
| Attachment | Audio and video | m4a, mp3, wav, aiff, mp4, mov | speech recognised on the device, language named | not executed | the end-to-end test skips until Speech Recognition is allowed for the app | owner: allow Speech Recognition |
| Attachment | Rich Text | rtf | decoded text | spec-built fixtures | — | — |
| Attachment | HTML | html, htm | text with tags removed | spec-built fixtures | — | — |
| Attachment | Plain text families | txt, csv, log, md, json, xml, ics, vcf, yml, yaml | the text, UTF-8 or Latin-1 | spec-built fixtures | — | — |
| Attachment | Attached message | eml, msg, oft, message/rfc822 | decoded headers and body (MIME for .eml, MAPI for .msg/.oft), its own attachments as children (three levels) | spec-built fixtures | each attachment of the message is its own child document (name, hash, state) | — |
| Attachment | Excel Binary Workbook | xlsb | every sheet (hidden and very hidden ones marked) with cell addresses, cached values, booleans, errors; formula text decoded from the BIFF12 token stream (references, 3-D references, names, external names, operators, every documented worksheet and macro-sheet function by name, newer _xlfn. functions and add-in functions by name, table (structured) references as Excel shows them — Table1[Column], Table1[[#Headers],[Column]], Table1[#All], [@Column] — shared and array formulas re-based on the cell), number-formatted cells rendered as Excel displays them (dates, times, elapsed time, percentages, currencies, fractions, scientific, thousands and scaling, conditional sections, literal text; the 1900 system with its 29 February 1900 and the 1904 system), the stored serial or value kept beside the rendered text, hidden rows and columns labelled, defined names (hidden ones marked), external workbook references listed and never refreshed; cell comments with their author, beside the sheet as in .xlsx; shared strings; the 1904 date system stated | real files | number formats are rendered in en-US whatever the author's locale, without column-width effects, native digits or era years (the same renderer as Office Open XML); a token the decoder does not know ends the formula with '(formula not decoded: token 0xNN)'; extra spacing Excel keeps in a formula (PtgAttrSpace) is not reproduced; a PivotTable calculated-field reference is named by its index; .xlsb has no natural-language formula tokens; threaded comments (Excel 365) are not read, only the legacy comment text Excel keeps beside them; verified on three Excel-written .xlsb from Apache Tika (testEXCEL_various: =C13*2, =COS(NA), =1/C13, a date, a percentage, a currency, a hidden name) and three from Apache POI (comments with authors in comments.xlsb and testVarious.xlsb, shared and array formulas in bug66682.xlsb); table references checked on spec-built bytes only — no public .xlsb with a table formula was found | — |
| Attachment | Visio drawing (VSDX), Project XML | vsdx, vsdm, vstx, xml (MSPDI) | Visio: every page's shape text under its page name; Project XML: project name, tasks (id, name, start, finish, notes), resources, assignments | real files | Visio-written .vsdx/.vsdm from Apache Tika; MSPDI plans from the MPXJ corpus | — |
| Attachment | TNEF (winmail.dat) | winmail.dat, ms-tnef | subject, sender, date and body (plain, HTML, compressed RTF); every file inside as a child document with its name and type; a message embedded in the TNEF (ATTACH_EMBEDDED_MSG, or a winmail.dat inside) expanded as an attached message with its own files as children, as many levels as the run's limit allows (three by default; Resume opens one more) | real files | files verified on an Exchange-written winmail.dat from Apache Tika (five files out); embedded-message expansion verified on spec-built TNEF streams only — no real nested winmail.dat fixture; a message deeper than the level ceiling is kept as a winmail.dat child and said to be unexpanded | — |
| Attachment | Publisher | pub | the text of every text box in reading order (the Quill CONTENTS stream), hyperlink targets under [Links]; Publisher 2000 and later | real files | Publisher 97/98 files (no Quill storage) are refused with the reason; pictures and drawing records listed as not text — verified on Publisher-written files from Apache Tika and POI (every line of POI's Sample.txt record) | — |
| Attachment | OneNote section / notebook package | one, onepkg | every page's text from its latest revision (titles, outlines, hyperlinks as label <url>), then the text of earlier revisions and objects no page reaches under its own label; Office 365 / FSSHTTPB-packaged sections grouped by page the same way (storage manifest → cells → newest revision → page series); .onepkg cabinets (stored and MSZIP folders) with each section labelled; embedded files counted | real files | page headings are numbered ("Page N"), the title is the page's own text line; an FSSHTTPB section whose page tree cannot be followed is read in storage order (the output says so); a section whose structure cannot be followed falls back to a labelled string scan; password-protected sections reported locked; LZX/Quantum cabinet folders named and not opened; OneNote 2003 and .onetoc2 not read — verified on 15 OneNote 2010–2016, Office 365 and 2007 files from Apache Tika | — |
| Attachment | Visio drawing (binary) | vsd, vss, vst | every shape's text through the pointer tree and Visio's LZW, one line per paragraph, grouped by page under the page's name in the drawing's page order (background pages marked), then stencil masters' text under the master's name; Visio 5 – 2010 | real files | Visio 5 page names are not read (pages labelled Page 1, Page 2…); text reached through no page or master is listed under Shapes; VBA listed as not text and never executed — verified on Visio 2000/2003 files from Apache Tika and POI, including POI's damaged regression files | — |
| Attachment | Project plan (binary) | mpp, mpt | document properties (title, subject, author, manager, company, category, keywords, comments); tasks as ID, name, start, finish, duration (as Project shows it, e.g. "1 wk", "8.88 days") and notes (RTF to plain text); resources as ID, name and notes; resource assignments (task → resource, units, work); Project 2000–2019 (MPP9/12/14) | real files | not read: baselines, costs, predecessors, calendars, custom fields, the estimated-duration "?" mark and the project summary task's own assignments; a task whose fixed data is missing is listed without dates and said so; Project 98 (MPP8) and Project 4 give their properties and say their tasks are not read; a read password locks the file, a write-reservation password is decoded and noted — verified on Project 2003/2007/2013 files from Apache Tika and MPXJ, including MPXJ's password files; dates, durations and assignments checked against MPXJ's test assertions and an MSPDI twin, each project saved as MPP9, MPP12 and MPP14 | — |
| Attachment | Access database | mdb, accdb, mde, accde | every user table's rows as column=value: text, memo, numbers, currency, dates, Yes/No; Jet 3 (Access 97), Jet 4 (2000–2003) and ACE (2007–2019); OLE, binary, GUID and attachment columns listed as not text | real files | encrypted databases (RC4 or the Office cipher) reported locked, no password entry; Microsoft Money (MSISAM) not read; system tables not dumped; a table that cannot be decoded is recorded by name — verified on Access 97/2000/2002–2003/2007 files from Apache Tika | — |
| Archive attachment | ZIP, tar, gzip attachments | zip, z01…zNN (spanned), tar, tgz, gz, gzip | every child accounted for: documents, text, PDFs/images/recordings through the same readers; unread children listed; three levels; 1 GiB per attachment; a spanned ZIP read with its sibling volumes (the message's other attachments) | spec-built fixtures | each member is its own child document with path, hash and state, searchable and openable on its own; a member on a missing volume is "not opened: volume N missing" and the rest read; spanned sets verified on Info-ZIP output | — |
| Archive attachment | 7z | 7z, 7z.001… | every member as a child document: Copy, LZMA, LZMA2, BCJ x86, Delta and Deflate decoded; 7zAES (AES-256) members and encrypted headers opened with Unlock…; solid blocks decoded once in order; split .7z.001 sets read with the sibling volumes | real files | BZip2, PPMd, BCJ2, the ARM/ARM64/PowerPC/SPARC/IA-64/RISC-V filters and Zstandard/Brotli/LZ4 are named per member as "compression method X not opened"; a block whose LZMA dictionary exceeds the run's per-part ceiling is stopped with the ceiling named (Resume opens it); verified on bsdtar/libarchive 3.7.4 archives (Copy, LZMA, LZMA2, Deflate, BZip2, PPMd) and on official 7-Zip 26.05 AES-256 encrypted-header and libarchive's encrypted 7z corpus, every member's SHA-256 equal to the pack's oracle | — |
| Archive attachment | RAR | rar, r00…rNN, part1.rar… | RAR 5.0 and RAR 1.5–4.x headers exact: every member's name, sizes, CRC-32, method, dictionary, encryption, solid and split flags; every member a child document — stored members copied, compressed members decoded by the vendored libarchive 3.8.11 reader (BSD-2-Clause, patched to carry a RAR 4 solid stream from member to member and to read RAR 7.0): the RAR 2.9–4.x algorithm (LZSS, PPMd, the standard filters), the RAR 5.0 algorithm (x86/ARM/delta filters) and the RAR 7.0 algorithm (compression version 1: 80 distance codes, dictionaries up to 1 TB incl. non-power-of-two sizes), any declared dictionary — the decoding window is sized to the data (the smallest power of two of at least 8 MiB holding the stream up to the member's end, so a 5 GiB dictionary on a small member needs 8 MiB) — solid archives decoded in order; the RAR 1.5 and RAR 2.0 algorithms (unpack versions 15, 20, 26, incl. RAR 2.0 multimedia audio compression) by mailin's own Swift decoder, streamed through a 4 MiB window; each member's CRC-32 or BLAKE2sp checked; with the password given through Unlock…, encrypted members and encrypted headers opened — RAR 3.x/4.x AES-128 (SHA-1 key derivation) and RAR 5.0 AES-256 (PBKDF2-HMAC-SHA256, the archive's password check value, checksums keyed to the password verified); a wrong password is "the password did not open it"; the password is never kept; a multi-volume set read as one archive with the other volumes attached to the same message handed over | real files | without a password, encrypted members and encrypted headers stay locked; named per member as not opened: RAR 1.5/2.0 solid members after the first (no real solid RAR 1.5/2.0 archive found to verify on), RAR 1.5/2.0 members split across volumes, RAR 1.5/2.0 encryption, RAR 1.3 and other unknown unpack versions, RAR 5.0/7.0 compression versions above 1, a RAR 5.0/7.0 member whose decoding window would exceed the device limit (a quarter of its memory, at most 4 GiB, named as the window it needs), a RAR 5.0/7.0 member whose header records no unpacked size (written from a pipe into volumes), an encrypted member (or encrypted solid stream) split across volumes; RAR 3/4 stores no password check, so under a wrong password a member is named "the password did not open it" when it fails to decode or its CRC-32 differs; a member running into a missing volume is "not opened: volume N (name) missing"; a damaged member is named with the decoder's reason (in a solid stream, the members after it too); the per-part ceiling and the 1 GiB per attachment stop a member with the ceiling named (Resume opens it); verified on WinRAR-written RAR 4 and RAR 5 archives from libarchive's test suite (normal and best compression, PPMd, the E8 and ARM filters, solid, BLAKE2, multi-volume, damaged; encrypted: RAR 4 and RAR 5 data, file names and solid streams under libarchive's published passwords, and RAR 4 data/header encryption opened with "12345678"), the decoded bytes checked against what libarchive's own tests assert (exact bytes, sizes, tails, CRC-32s) and against WinRAR's header CRC-32; RAR 4 solid verified on libarchive's one RAR 4 solid file (encrypted) and its decrypted form; RAR 7.0 verified on archives written by RARLAB rar 7.23 for macOS (version 1 with 5 GiB and 4.5 GiB dictionaries, a version 1 member followed by version 0 members in one solid stream, a solid three-volume version 1 set, encrypted data and headers; RAR 5.0 with a 1 GiB dictionary), every member's CRC-32 and the SHA-256 of the generated text — no fixture holds a match more than 4 GiB back (it would need over 4 GiB of data), so the longest distance codes are decoded by no file; RAR 1.5 and 2.0 verified on real archives from junrar's and rarfile's public test suites (RAR 1.5x DOS and Windows, RAR 2.x normal and multimedia-audio), every member's CRC-32 and the WAV byte-identical to libarchive's decode of the RAR 2.9 archive of the same recording; RAR 3 key derivation for passwords over 28 characters follows unrar's SHA-1 variant but no such file has been run; a two-volume set attached to one message verified on a spec-built set | the owner's own WinRAR mail archive |
| Archive attachment | bz2, xz | bz2, xz | — | **not implemented** | kept as files, stated | — |
| Protected content | Password-protected PDF / Office / archive members |  | detected and recorded as locked; Unlock… on the attachment takes a password once — PDF (PDFKit), Office Open XML Standard and Agile encryption, ZIP members (ZipCrypto and WinZip AES), RAR members and RAR encrypted headers (RAR 3/4 AES-128, RAR 5.0 AES-256; see the rar row), encrypted OpenDocument and protected iWork ('09 and 2013+) — and either shows the text for this view or stores it for search, as the person chooses; passwords are never kept | real files | Office Standard and Agile verified on Word/Excel/PowerPoint-written files from Apache Tika and POI (incl. Excel's default password) and a protected PDF; ZipCrypto and AES-256 verified on archives made with official 7-Zip 26.05, AES-128/256 (deflated and stored) on libarchive's WinZip fixtures; RAR verified on libarchive's WinRAR-written encrypted files; encrypted OpenDocument opened by the odf row's rules (verified on Tika's LibreOffice file; Argon2id on independently built files); protected iWork documents by the iwork row's ('09 verified on Tika's Pages file; 2013+ on Pages/Numbers/Keynote 14.4 files made for the purpose); PST/OST are not password-encrypted (see the pst row); one file, one password | — |
| Protected content | S/MIME |  | originals kept; signatures verified where present (Mac: CMSDecoder; iPhone and iPad, and as the Mac's fallback: mailin's portable CMS reader — RSA PKCS#1 v1.5 and PSS, ECDSA P-256/384/521, SHA-1/256/384/512, opaque and detached, signer certificate from the message, trust judged by the system); with the module on, encrypted S/MIME parts (EnvelopedData and AuthEnvelopedData) are decrypted with a private key in this device's keychain — used in place, never exported — by RSA PKCS#1 v1.5 or RSA-OAEP key transport or ECDH P-256/384/521 key agreement (X9.63 KDF, AES key wrap), content in AES-128/192/256-CBC, AES-GCM or 3DES-CBC; the message inside is read with its attachments as children; on iPhone and iPad the identity is one imported as .p12 in Settings ▸ Health (password typed once, never kept) | real files | off by default (preview); verified on envelopes and signatures written by OpenSSL 3.5.1 (RSA v1.5/OAEP, ECDH with SHA-1/256/384 KDFs, AES-CBC/GCM, 3DES, BER streaming, subject-key-identifier recipients; RSA, RSA-PSS and ECDSA signatures, opaque and detached) and on OpenSSL decrypting and verifying mailin-written ones, with throwaway identities made by the test, and the Mac CMSDecoder path on a disposable keychain identity; not read: KEK and password recipients, RC2/DES content, GCM tags under 16 bytes, SHA-224, DSA; identities installed by a configuration profile stay in the system keychain, which iOS does not open to other apps — import the .p12 instead; mail written by Outlook or Apple Mail with a production identity has not been run, and the iPhone/iPad keychain path has not been run on a device | S/MIME mail from Outlook or Apple Mail with its identity (owner); a device run of the .p12 import |
| Protected content | OpenPGP | gpg, pgp, asc, sig | detected and described: PGP/MIME (multipart/encrypted, multipart/signed), inline armor, .gpg/.pgp/.asc/.sig attachments; recipient key IDs (or v6 fingerprints) and algorithms, passphrase sessions, compression, literal data, MDC or AEAD protection; ASCII armor checked by its CRC-24; clearsigned and inline-signed text is read. Signatures VERIFIED against public keys the person imports into the archive's on-device keyring (.asc or binary; v4 and v6 keys; self-signatures, subkey bindings, expiry and revocation checked): good (key, user ID, time, whether the key had expired or been revoked by then), BAD, unknown key (issuer named), or cannot verify (reason) — for cleartext, inline (incl. ZIP/ZLIB-compressed), detached .sig/.asc beside the file it signs, and PGP/MIME signed mail; RSA, ECDSA P-256/P-384/P-521, EdDSA Ed25519 (legacy and v6), with SHA-1 and SHA2-256/384/512 | real files | never decrypted — public keys only, no secret keys or passphrases, no key server; encrypted content is recorded locked with the recipient key IDs; DSA, Elgamal, Ed448, Brainpool/secp256k1 curves, SHA-224, SHA-3, v5 keys and BZip2-compressed signed data are “cannot verify”, never “bad”; no web of trust (third-party certifications are not judged); verified on RFC 9580 Appendix A samples, PGPy 0.6.0-written keys and signatures (RSA 3072 + subkey, Ed25519, P-256/384/521, expired, revoked, PGP/MIME), and GnuPG's own release keys and a GnuPG-made signature from gnupg.org; no GnuPG on the build Mac, so GnuPG-written PGP/MIME mail has not been run | GnuPG/Thunderbird-written PGP/MIME mail (owner) |
| Protected content | Rights-managed files, cloud references |  | — | **not implemented** | no rights-aware access; references are kept as references | — |
<!-- format-registry:end -->

## 2. What each format delivers

| Format | Parser | Streams? | What is extracted | Known caveats |
|---|---|---|---|---|
| mbox | `MBOXParser` (streaming fallback) / `OffsetImportEngine` (3.0 default) | **Yes** — bounded memory, adaptive batches | Headers, MIME tree, bodies, attachments, Gmail labels → tags, thread links; mboxrd `>From ` escaping undone on read (parser/engine version 2, 2026-09-27) | With the offset engine (default since 3.0) a single message above the full-parse ceiling is imported from its headers with a byte locator, read back and **exported byte-for-byte by streaming from the source** (executed: 1,153,445,255-byte message, `LargeMessageBlobTests`). The streaming fallback still reports such a message as damaged rather than truncating it (see §3) |
| eml | `MBOXParser` | Yes | As mbox; a missing `From ` envelope is synthesised. **Fixed 2026-09-26:** an envelope line INSIDE the header block (real Gmail exports put it a dozen headers down) is no longer a separator, in both engines | **Fixed 2026-09-25:** the streaming path (the one imports use) began a message only on a `From ` line, so a bare `.eml` imported as ZERO messages with no failure reported. A first line that is a header field now starts one bare message. Pinned by `singleEMLStreams`; the reverse case (mbox preamble) by `mboxPreambleIsNotAMessage` |
| emlx | `EMLXParser` | No | Per-file parse with a damaged-file report (`ParseResult.summary`) | Whole set materialises before draining |
| msg | `MSGParser` | No | OLE2 → MAPI properties (sender, recipients, subject, bodies, attachments) | Any size (CLOSE-01): read through a file handle; above the full-parse ceiling rendered to RFC 5322 in bounded memory and imported by range; one message per file |
| pst / ost | `PSTSpecReader` (switch **Outlook PST reader (MS-PST)**, on); earlier `PSTParser` reader when off | No | Reads by the published [MS-PST] layers: NDB (node + block B-trees, XBLOCK/XXBLOCK data trees, SLBLOCK/SIBLOCK subnode trees), LTP (heap-on-node, BTH, property context, table context) and the messaging layer (folder hierarchy, contents, recipient and attachment tables). ANSI (Outlook 97–2002) and Unicode files; `bCryptMethod` 0, 1 (permute) and 2 (cyclic). Only mail items (`IPM.Note…`, reports, meeting mail) are imported — contacts, calendar, tasks, notes, journal, RSS and hidden folder-configuration items are not. PSTs written by mailin itself, which use an earlier layout, still go to the earlier reader. The 4 KiB-page OST of Outlook 2013 and later (`wVer` 36) is read through the same entry points by its own page geometry (`PSTPageGeometry.fourK`: 4096-byte B-tree pages with two-byte entry counts, 24-byte page and block trailers, 512-byte block alignment, the Unicode header and entry layouts) and its **zlib-compressed blocks are inflated** (`PSTBlockInflate`: the 4 KiB BBTENTRY is `bid, ib, cb, cbInflated, cRef, pad`; a block is compressed when cbInflated > cb — found on the real file, where the synthetic fixture had shown nothing) — **evidence: the real `example-2013.ost`** (java-libpst, 2026-11-07, `RealMailStoreFixtureTests`): 3 of 3 messages with subjects, Message-IDs, dates and folders equal to readpst's, 62 of 310 blocks compressed; the spec-built `OST4KPageTests` fixture still covers the uncompressed layout. OLE attachments (`PidTagAttachMethod` 6) are read from the subnode their PtypObject cell names — the Aspose `SampleOstFile.ost` (wVer 23) had shown the 8-byte cell stored as the attachment; now all 36 readpst payloads of that file are byte-identical | **Executed 2026-10-13 on 15 real Outlook PSTs** (Digital Corpora filetypes1, ANSI and Unicode): same mail items, Message-IDs, subjects and senders as `readpst` (libpff/libpst); the reader before that day read 0–1 items from these files. Attachments: content, count and total bytes equal readpst's on all 15 files (2026-10-14; found then that the new reader had kept names and sizes only — fixed); an attached email (embedded message) is rebuilt as an `.eml` attachment marked `X-Mailin-Reconstructed`; attachment objects a damaged file's attachment table no longer lists are still read. Cyclic: no public file exists, so all 15 were re-encoded block by block with CryptCyclic and read back identically. Not executed above 50 GB (see §4) |
| nsf | `NSFParser` | No | Structured note records with LZSS decompression and LMBCS strings, attachments by item | Falls back to a **heuristic text scan** when the structured parse finds nothing — fidelity is lower on that path and it is not byte-exact |
| Apple Mail package | `MBOXParser` per member | Yes | As mbox | Reports "nothing to import" when no `mbox` file is inside |
| Maildir | `MBOXParser` per member | Yes | As eml, one message per file. Folders from the layout (2026-11-07, `DirectoryFolderLayoutTests`): the root is the inbox under the folder's own name; Maildir++ sub-mailboxes `.Sent`, `.Archive.2024` become `Sent`, `Archive/2024`; nested plain mailboxes (`Lists/Swift/cur`) keep their path; empty sub-mailboxes are declared | `tmp/` (deliveries in progress) skipped and counted in the report (`maildir_tmp_skipped`); `cur`/`new`/`tmp` are never folder names. A folder of `.eml` files is walked whole, each file's directory below the root being its folder |
| ZIP | `ZIPArchiveReader` → member's own parser | Yes | **Container (2.1):** each member streams to a scratch file (64 KiB window), is classified on its own bytes, parsed, and deleted before the next member is touched. Stored and deflate methods; ZIP64 records and extra fields honoured (Google Takeout > 4 GB). Size and CRC-32 verified per member | The only ceiling is the scratch volume's free space (+64 MiB margin) — there is no arbitrary member cap. Refused and counted, never imported: encrypted members, other compression methods, a member whose output exceeds or falls short of its declared size, CRC mismatch. Skipped and counted: non-mail members, nested archives, `__MACOSX/` and dot-files. Executed: `ContainerImportTests` (9) |
| gzip | `ZIPArchiveReader.gunzip` → payload's parser | Yes | **Container (2.1):** RFC 1952 header parsed (FEXTRA/FNAME/FCOMMENT/FHCRC), raw deflate streamed, trailer CRC-32 and size verified | Single payload; name taken from the archive's own name minus `.gz`. A `.tgz` is gzip → tar → members (TYPE-06) |
| tar, tgz | `TARReader` → member's own parser (TYPE-06, 2026-11-06) | Yes | **Container:** POSIX ustar headers, GNU long names (`L` records), PAX `path=` / `size=` records, base-256 sizes; every header checksum verified; regular files only (directories, links and `__MACOSX/` / dot-files are not extracted). Each member streams to scratch, is classified on its bytes, parsed, deleted | The only ceiling is the scratch volume's free space (+64 MiB margin). A member whose declared size runs past the end of the file is refused as truncated and the archive is named as damaged in preflight. **One level of nesting is followed** (gzip → tar, ZIP holding `.mbox.gz`); a container inside that inner container is skipped and counted (`container_nested_skipped`). Executed: `ContainerImportTests.tarOfMailboxesImports_everyHeaderForm`, `tgzIsFollowedOneLevel_deeperIsCounted`, `truncatedTarIsNamed` — fixtures written from the format description; no real tarball from a mail client has been run |
| olm (Outlook for Mac) | `OLMParser` (TYPE-06, 2026-11-06) | Yes — one record at a time out of the ZIP, batches to the store | Every `message_NNNNN.xml` record under `com.microsoft.__Messages/`: addresses (display names kept), subject, sent/received times, Message-ID, In-Reply-To, References, Thread-Topic/Index, priority, plain and HTML bodies, attachments **with their bytes** (the member `OPFAttachmentURL` names; `Local/` root and suffix fallbacks), read and flagged states as flags, primary category as a tag. The folder path is the record's place in the tree (`Local/` dropped, `Accounts/<name>` kept); empty folders are declared (FOLD-02). Each record is rebuilt as an RFC 5322 message marked `X-Mailin-Reconstructed: rebuilt from an Outlook for Mac (OLM) record, <member>` and parsed by the .eml path, so export and search treat it like any other message | Contacts, calendar items, tasks and notes are **counted on the receipt and left in the file** (`olm_contacts_not_imported`, `olm_calendar_not_imported`, `olm_tasks_not_imported`, `olm_notes_not_imported`, `olm_other_objects_not_imported`); an attachment whose member is missing is listed in `X-Mailin-Attachments-Missing` and counted (`olm_attachment_bytes_missing`); a record that is not XML or holds no `<email>` is counted as failed with its category. **Executed 2026-11-07 on two real archives** (`RealMailStoreFixtureTests`, independent inventory = ditto + own XML walk): Aspose `SampleOLM.olm` — 22 of 22 mail records, 38 of 38 attachment occurrences byte-identical (24 with Content-ID), 11 real folder paths, sent/received times, 3 contacts counted; Outlook 16 `outlook_example.olm` (teverett/OLMReader) — 7 of 7 records, 9 of 9 attachments, 5 contacts / 2 groups / 8 appointments / 5 tasks / 1 note counted, category "Blue Category", follow-up flag, unread state, priority 2/4. The first reader (written from the XML shape) had read none of: `OPFMessageGetIsRead` "1E0", `OPFMessageCopyGetFlagStatus`, the nested category markup, priority 2/4, "7.39E3" sizes, and counted non-mail per file under the wrong tree names — all fixed on the real files. Contact groups are counted as `olm_contact_groups_not_imported`; `Categories.xml` (the colour table) is not an object. Still pending: the owner's own export with the same-message MBOX/EML set |

With "Streaming PST and NSF import" on (default since five jobs OPEN-02, 2026-11-05),
`pst`, `ost` and `nsf` hand messages out in batches as they are read; only one
batch is resident. With it off, and always for `msg` and `emlx`, the parser
materialises the whole result before draining it in bounded chunks. The adaptive
batch envelope's *message* bound is honoured on every path; its *byte* bound only
on the streaming ones (`msg` is one message per file, so a whole message is the
smallest unit anyway).

### Memory behaviour by format (audit F16, stated rather than implied)

| Format | Import memory | Measured |
|---|---|---|
| mbox, eml, gzip/ZIP of those | **Bounded**: peak does not grow with the file. Offset engine: headers per batch, bodies parsed per batch; streaming parser: one batch resident | 1.5 GB mbox: peak Δ 450–790 MiB (`SCALE_RESULTS.md` rows 1–3); 1 GB format rows executed |
| EML folder, Maildir, Apple Mail package, `.emlx` folder | **Bounded per file**; the member list (paths only) is resident | 1 GB rows executed |
| pst, ost | **Bounded** with "Streaming PST and NSF import" on (default, five jobs OPEN-02, 2026-11-05): messages leave the node tree in batches, one batch resident; the node table (≈ 32 bytes per node) and the mmap'd file pages are the only per-file residents. Off: the previous path, proportional to the file | 100 MB PST, 2,000 messages, batches of 100: footprint grew by less than half the file (`V2CutoverTests.testOPEN02_pst*`); 1 GB PST row executed earlier on the array path; larger files are **not tested** and are not claimed |
| nsf | **Bounded** with the same switch: note records are read one at a time from the mapped file and handed out in batches; no note cap on this path (the previous path stops at 500,000 notes). The text-scan fallback (no structured record found) still reads the file as one string, bounded to 200 MB by its own guard | 100 MB synthetic NSF, 2,000 memos, batches of 100: footprint grew by less than half the file (`V2CutoverTests.testOPEN02_nsf*`); **executed 2026-11-07 on the public Aspose `SampleNSF.nsf`** (47 MB Notes mail database): **0 notes read** — the "structured" path looks for mailin's own synthetic item layout, not the Notes ODS buckets, and the text fallback finds no "Form: Memo" lines in a binary file. The give-up after 100,000 bytes without a record (a hidden cap: the real file's first megabytes are design notes) was removed; the whole file is scanned. NSF import is **not verified** and must not be claimed until an ODS reader exists and an independent Notes inventory is obtained |
| msg | **Proportional to the message** at or under the full-parse ceiling (read through a file handle); **bounded** above it (CLOSE-01: a sparse 2.0 GB .msg streamed in 3 MiB, rendered in 12 MiB over baseline) | 1 GB MSG row executed; 2.0 GB sparse rows (`LargeSingleMessageTests`) |
| ZIP container itself | Central directory resident (≈ 80 bytes per member); each member streams to a scratch file | `ContainerImportTests` |

"Bounded memory" in this document therefore means the first two rows. A
terabyte claim exists for none of them: the largest executed import is in
`SCALE_RESULTS.md`, and anything larger is stated as untested.

---

## 3. mailin's own limits

| Limit | Value | Where | Consequence |
|---|---|---|---|
| Single message on the non-streaming path | 100 MB | `MBOXParser.maxMessageBytes` | Counted as damaged (`oversized_message`) and skipped with a clean report — never truncated, never an OOM. **Removing this is task S4.** |
| Single message on the offset engine (3.0 default) | 100 MiB full-parse ceiling | `OffsetImportEngine.fullParseCeilingBytes` | Imported from its headers with a byte locator that **commits in the same transaction as the row** (audit F02). Its content is **read from the file the locator points at** when opened or exported — MBOX and EML exports stream it byte-identically to a full parse (`DeferredMessageIntegrityTests`); production withholds it with the reason; its text is not searchable. **Self-contained archive (five jobs LIFE-01, on by default since 2026-11-05):** each single-file source is copied into `<archive>/sources/<sha256>/`, verified against the import hash, and imported from the copy, so the locator points inside the archive and the original may be moved or deleted (`V2CutoverTests.testLIFE01_*`). Switched off (linked mode): the original is referenced where it was imported from; Settings ▸ Health lists missing originals with how many messages depend on each and relinks a moved file only after its SHA-256 matches. A missing original is an error the app states, never an empty message (audit F05) |
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

No size refusal (CLOSE-01, 2026-11-09). The former 2 GB refusal existed because
the whole file was read into memory; the compound file is now read through a
file handle (sectors, FAT, mini FAT and mini stream on demand, every chain
checked for loops and out-of-range sectors). A file above the offset engine's
full-parse ceiling is rendered to RFC 5322 inside the archive with its bodies
and attachments streamed in slices, then imported by range like a large `.eml`.
The same applies to `.emlx` (formerly refused above 500 MB): the message part
is located by its byte count and imported by range.

---

## 5. Export

| Target | Status |
|---|---|
| mbox | Round-trip verified: 526 messages exported → 526 re-parsed → 526, 94,929,888 bytes. Writes a real `From_` envelope (`MBOXRecordBuilder.envelopeLine(for:)`) and includes attachments as base64 MIME parts, marked `X-Mailin-Reconstructed` when the record was synthesised rather than byte-copied. |
| mbox, partitioned | `ArchiveExportService.exportMBOXPartitions(...)` splits on a byte budget, never mid-message — for destinations such as FAT32 with its 4 GiB single-file limit (exFAT has none; audit 2026-11-06 A11) |
| PDF (Bates) | Stamp verified by PDFKit read-back (`GoldCaseClosureTests`) — **executed 2026-09-25, pass** |

Export of a *reconstructed* message is not byte-identical to the source and is
labelled as such. Byte-exact export requires the original bytes, which is what
the offset-index work (S4/S5) exists to preserve.

---

## 6. What is NOT supported

- **Encrypted ZIP members, and ZIP compression methods other than stored /
  deflate** — refused by name and counted; the rest of the archive still
  imports. One level of nesting is followed (`.tgz`, a `.mbox.gz` inside a
  ZIP or tar); an archive inside that inner archive is skipped and counted.
- **Other wrappers** — `.7z`, `.rar`, `.bz2`, `.xz` are not opened as sources
  (and are kept as files when they are attachments).
- **Non-mail Outlook items** — contacts, calendar entries, tasks, notes, journal
  and RSS items in a PST/OST, and contacts / calendar / tasks / notes in an
  OLM, are counted out, not imported.
- **Encrypted PST/OST beyond that obfuscation** — password-protected files are
  not decrypted.
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
| Zero network activity | **Measured and verified 2026-09-27** — 0 network sockets at idle in the Release build; `Scripts/verify-no-network.sh` on the signed Release app PASS 8/8 (sandbox on, no network entitlement, `NO_NETWORK_BUILD` marker present, no direct Network/CFNetwork link, no ATS exceptions) |
| Format classification | Unit-tested (`SourceFormatClassifierTests`) |
| Size policy verdicts | Unit-tested (`SourceSizePolicyTests`) |
| Directory-source import (Apple Mail package, Maildir, `.eml` folder, `.emlx` folder) | **Executed 2026-09-27 at 1 GB each** through the production coordinator, exact reconciliation (`SCALE_RESULTS.md`). Real content, synthetic layout: a genuine Apple Mail / Dovecot export has still not been run |
| PST / MSG import | **Executed** — 2026-09-27 on the Apache Tika fixtures (`testPST.pst` and three `.msg` files, `RealBinaryFixtureTests`); 2026-10-13 on 15 real Outlook PSTs from Digital Corpora through the production importer: 587 mail items stored, 33 in deleted-items folders, both equal to `readpst` (`RealDataRecoveryTests`, opt-in with `MAILIN_REAL_FIXTURES`, files fetched by `Scripts/fetch_open_fixtures.sh`). Thunderbird: 828 messages, 35 deleted-but-unpurged, equal to an independent scan |
| Format matrix at 100 MB (mbox, PST, `.eml` folder, `.msg` files) | **Executed 2026-11-06** through the production importer on synthetic fixtures (`HundredMegabyteFormatMatrixTests`): every message stored, search coverage complete; peak footprint 0–46 MB over baseline at 100 MB vs 5 MB at 25 MB — tested at 100 MB; memory does not grow with file size. Rows in `SCALE_RESULTS.md`. Larger files are covered by the bounded-memory design, not by a measurement |
| OST / NSF import | **OST executed on two real files 2026-11-07** (`RealMailStoreFixtureTests`): Aspose `SampleOstFile.ost` (wVer 23) 87 of 87 mail items + 5 calendar items counted out, folders/Message-IDs/36 attachment payloads equal to readpst's; java-libpst `example-2013.ost` (wVer 36, 4 KiB pages, zlib-compressed blocks) 3 of 3 messages equal to readpst's. The spec-built `OST4KPageTests` fixture (uncompressed) is kept. **NSF executed on the public Aspose `SampleNSF.nsf`: 0 notes read** — the reader does not parse the ODS layout; not verified, not claimed |
| PST above 50 GB, NSF above 64 GB | **Never executed.** The warnings say so. |

## Tool scope (3.0 engines, 2026-10-10)

Each tool has two engines for the whole of 3.0: the previous engine and the 3.0 engine, chosen per tool in
Settings ▸ Modules ▸ 3.0 engines (on by default; switch one off for the previous engine).

| | Previous engine | 3.0 engine |
|---|---|---|
| Legal and forensic actions (hold, seal, verify, Bates, custodians, privilege, rules, batch tags, review batches, PII, IOC, keywords, duplicates, investigation report) | Newest 2,000 emails of the scope (5,000 for duplicates), stated on screen | **Every email in scope**, in batches, with progress, Cancel and resume; a receipt records the scope and a fingerprint of the exact emails |
| Counts and statistics (dashboards, IT figures, composition, sentiment, PII / priority counts, cleanup, overview cards) | The loaded window | **Exact over the whole archive** |
| Analyses that read message text through a model or a pattern finder (trends, communication patterns, languages, topics learned, AI enhancement) | The loaded window | An **evenly spaced sample** of up to 5,000 emails across the whole archive (500 for AI enhancement), always stated as "based on N of M"; topics are then **assigned to every email** |
| Meaning-based (semantic) search | Not available | Exact search over on-device sentence vectors; time per query grows with archive size (about 2 KB read per indexed email). No result is cut. See `SEMANTIC_SEARCH_DECISION.md` |
| AI answers about emails you chose (one email, a case, a person, a selection) | The emails given | **Always the emails you chose.** Only a tool's capped window is replaced by an even spread of the whole archive |
| Thread stories | First 200 messages | **Every message**, read in parts that fit the on-device model (4,096 tokens) |
| Near-duplicates | Newest 10,000, pairwise | Whole archive: MinHash candidates, exact Jaccard verification; covers the emails the analysis index has reached (shown) |
| PST export | One file; error at 50 GB | Parts below 45 GB and below the destination's maximum file size (FAT32: 4 GB) |
| PST export layout (switch "Outlook PST writer (MS-PST)", on by default) | Earlier writer: read by mailin, not guaranteed in Outlook | Outlook's own [MS-PST] layout; read back exactly by mailin, libpff and libpst on 1,000 emails with attachments. Not yet confirmed in Outlook itself, so still experimental |

Real limits that remain, by design:
- Lists show a page at a time with "N of M" and Load more; nothing is dropped.
- Per-type PII findings shown on screen: 200 per type; Export CSV writes every finding.
- The analysis index (needed by near-duplicates, analysis queries) builds in the background and pauses on low battery, heat or Safe Mode; coverage is shown in Settings ▸ Health.

## Deleted-email recovery (on by default; a switch in Settings ▸ Modules)

With **Settings ▸ Modules ▸ Recovery** on, imports mark mail the files show as deleted; recovered mail appears under **Recovered** in the sidebar and with `is:recovered` / `recovery:<kind>`, and each recovered email shows how it was found.

| Source | What is recovered | Limit |
|---|---|---|
| Thunderbird mbox | `X-Mozilla-Status` bit 0x0008 (deleted, not yet purged) | Compacting the folder removes such mail for good |
| mbox (mutt / pine) | `X-Status` containing `D` | — |
| Gmail Takeout | Trash / Bin labels | Mail emptied from Trash is not in Takeout |
| Apple Mail EMLX | Deleted flag (0x02); Deleted Messages / Trash mailboxes. Mail's own library folder (V10, an account or a mailbox) can be chosen directly; checked 2026-10-14 on a 1,000-message library in Mail's layout through both import engines | — |
| PST / OST | Deleted Items, Recoverable Items and other deleted-items folders; messages in no folder (orphans) | Outlook 2016 and later rarely leave orphans |
| PST deep recovery (separate switch) | Property contexts found in unallocated space, marked carved and partial, with byte offsets. Checked 2026-10-14 on real Outlook PSTs with their Deleted Items emptied (entries removed from both B-trees, as Outlook does): 31 of 31 emptied messages carved back | Best effort; overwritten space cannot be read. Files with cyclic encoding cannot be carved (the decoding key is the block ID, which freed space no longer has) |
| Any file (carving, deep recovery switch) | RFC 5322 messages with a sender and a date or Message-ID | Best effort; candidates that do not verify are counted as rejected, never imported |
| Lotus Notes NSF | **Deletion stubs listed** (recovery on), marked partial: identity only — UNID, note ID, sequence, dates; the document's content is not in the database | Recognised by the public facts: a note ID with RRV_DELETED (0x80000000), or a note that keeps only its identity. **Verified on mailin's own synthetic NSF files only** (two databases, 37 and 121 deleted documents among 1,000 each: counts exact, no live email marked or lost; recovery off imports exactly as before). The on-disk stub layout is not publicly documented and **no database written by HCL Notes has been checked**, so real files may list fewer stubs than they hold |

Measured (2026-10-13, Release, this Mac): carving 1 GB of random data with 100 planted messages found all 100 and nothing else in about 1 s, peak memory +37 MB. Golden fixtures (Thunderbird, mutt, Gmail Takeout, PST folders, orphans, freed PST space) are imported through the real importer — both engines and header-only messages — and must equal their manifest.

Mail files do not record when a message was deleted, so deletion analysis counts recovered emails against legal-hold dates only.

## Scripts, Shortcuts and team review (on by default; switches in Settings ▸ Modules)

**Recipes (no code).** Conditions on from, to/cc, subject, body, attachment names and count, size, date, the body's SHA-256, the IPv4 addresses in Received headers, or any named header; operators contains / does not contain / equals / greater / less / matches pattern / is one of a list / is in an IPv4 range (CIDR). Actions: add tag, add note, set column (a fixed value or a computed one: `{sha1}` `{sha256}` `{sha512}` `{received_ips}` `{from_domain}`), set aside. Checked 2026-10-14 on 1,000 emails: recipes make exactly the changes of the bundled Hash columns, Domain filter, Date filter, Hash list exclude and Privilege screen scripts, and the private-hop part of IP addresses. Scripts that compute (entity catalogue, attachment risk score, keyword proximity, card-number checks) stay scripts; each bundled script has a "How it works" page.

| Feature | Real limit | Why |
|---|---|---|
| Scripts | A script is stopped when one email takes more than 5 s, or the app's memory passes 2 GB | JavaScriptCore has no public time limit; every loop is guarded instead |
| Scripts | Arrays, strings and buffers up to 50,000,000 items per native call; tags, notes and column values up to 64 KB | Stops runaway allocation before it reaches the system |
| Scripts | No network, no timers, no `eval` and no code built from any function constructor (plain, async, generator) | Offline-first; scripts may only tag, untag, note, add columns, set aside (Trash) and report |
| Shortcuts Find Emails | 10,000 emails per Find | A Shortcuts list is held in memory; Count Emails gives the exact total |
| Review Pack | Text and attachment names only (no attachment bytes) | The reviewer codes, they do not produce |
| Team case | One log file per reviewer device; any folder the devices can all reach (file server, NAS, external drive) | No server; nothing goes online |
| Team case | Responses and log entries are signed by the device key; they prove integrity, not who held the device | Identity is the device; MDM-managed roles are recorded with each entry |
| DKIM / ARC | Checked against keys you import; the ARC-Seal chain is not checked, only ARC message signatures | No DNS lookups (offline) |
| Hidden timestamps | Thread-Index, Outlook and JavaMail boundaries, Unix times in Message-IDs; other Message-ID formats (e.g. historical Gmail) are not decoded | Only documented encodings are decoded |

## OCR and DEVONthink (on by default; switches in Settings ▸ Modules)

**Text in scanned attachments (OCR)** — switch "Text in scanned attachments (OCR)".
- Reads scanned PDFs (a PDF whose own text layer holds fewer than 20 characters per page) and image
  attachments (PNG, JPEG, TIFF, HEIC, GIF, BMP, WebP) with Apple Vision, on this device. No network.
- Each image or PDF page is read at most 3,000 pixels on its longest side; one page in memory at a time.
  Very small print in a large scan may not be recognised at that size.
- Recognised text joins the attachment search (`in:attachments`); per attachment, the first 500,000
  characters are indexed (the same limit as other attachment text).
- Mail already indexed before OCR was switched on is read in a second pass, each email once, resuming
  after an interruption. Progress shows in Settings ▸ Modules ▸ Running now as "scanned text: X of Y
  emails". The pass's own state is a file beside the archive (`attachment-ocr.sqlite`); the archive
  itself is not changed in format, so an earlier build still opens it.
- Handwriting and low-contrast photos are recognised poorly or not at all.

**Every document kind is read for search (2026-11-06, owner directive "all types").** Attachment text
comes from: PDF (text layer, OCR when scanned); DOCX / XLSX / PPTX; **OpenDocument** .odt / .ods / .odp
(sheets, slides, notes, headers and footers labelled; an encrypted manifest → "locked"); **iWork**
.pages / .numbers / .key — the modern IWA format (snappy + protobuf; body text, table cells with sheet
names, slides without template placeholders) and iWork '09 XML, verified on real files made by Pages,
Numbers and Keynote (`maxmailinTests/Fixtures/iwork`); **Office 97–2003** .doc (piece table), .xls (sheet
names, shared strings across CONTINUE records, inline labels; FILEPASS → "locked") and .ppt (text atoms per
slide; the Word reader verified on a real textutil .doc, the Excel and PowerPoint readers on spec-built
streams — real files welcome); **ZIP attachments** one level down (each file inside read by its kind, nested
archives and oversize members listed as not read, media listed as not text); RTF, HTML and plain-text
kinds. Still not read, and said so per attachment: password-protected files ("locked"), images without
OCR on, 7z/rar/bz2/xz archives (kept as files — ZIP, tar and gzip attachments are opened, audit 2026-11-06 A04), and files with no text.
**Archive attachments (A04):** every child is accounted for — documents through the document readers, text files directly, PDFs / images / recordings through the same reader a top-level attachment gets (text layer, OCR, speech); a child nothing can read is listed by name and the attachment is *partial*, never silently complete; archives nest three levels (what lies deeper is listed); one attachment's archives are bounded to 1 GiB of extracted bytes across levels, each bound that bites named in the state. Children are read into the parent attachment's text with "ZIP: outer.zip › inner.pdf" labels; a condition on an attachment's type or name still addresses the parent file, not the child.

**Speech in audio and video attachments** — switch "Speech in audio and video attachments" (on by default).
- The words spoken in m4a, mp3, wav, aiff, caf, aac, flac, mov, mp4, m4v and 3gp attachments are recognised
  on this device with Apple's Speech framework (`requiresOnDeviceRecognition`); nothing is sent anywhere.
  The first recognition asks the person once (System Settings ▸ Privacy & Security ▸ Speech Recognition).
- Recognised speech is its own document kind (`speechText`): search finds it anywhere and per attachment, and
  the evidence chip says "Recognised speech: file". The text is prefixed with the language used
  ("[Recognised speech (en-US)]").
- Language: the person's language when an on-device model is installed for it, else English, else any
  installed on-device model; a recording in a language with no on-device model is recorded as "failed" with
  that reason, never as "no match". Quality follows Apple's dictation model: clean speech is good, crosstalk,
  music and poor phone audio are not.
- Verified: `testTYPE05_*` recognises two recordings made with the system voice (fixtures under
  `maxmailinTests/Fixtures/media`); the test skips with the reason when the test host has not been allowed
  speech recognition on this Mac.

**Send to DEVONthink and email links** — switch "Send to DEVONthink and email links" (Mac).
- Export ▸ Send to DEVONthink: the emails (count shown first) are written as standard .eml files through
  the normal export run — pre-flight, receipt, Resume, the Free plan's 500-email limit — then opened with
  DEVONthink, which imports them by its own Import setting (Global Inbox or a chosen group). Without
  DEVONthink the files are shown in Finder; the receipt says which happened.
- DEVONthink 3 and 4 are looked for by identifier. Tested here without DEVONthink installed (the Finder
  fallback and the file set); the import itself is to be confirmed on a Mac with DEVONthink.
- Export ▸ Copy Link to Email (open email): a `mailin://email/<id>` link that DEVONthink, Notes or any app
  can keep. Opening it selects the email; a link to an email not in this archive says so.
