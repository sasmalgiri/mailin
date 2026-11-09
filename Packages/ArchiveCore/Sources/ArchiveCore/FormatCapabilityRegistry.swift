//
//  FormatCapabilityRegistry.swift
//  ArchiveCore
//
//  Handoff 7481852, work package 4: ONE machine-readable statement of what
//  mailin reads, how far, and on what evidence — the same list feeds
//  Settings ▸ Health ▸ Formats, the public support table in
//  SUPPORTED_FORMATS_AND_LIMITS.md (a test holds the two together) and the
//  acceptance rows in FIVE_JOBS_TRACKER.md. No handwritten format claim
//  elsewhere may say more than this file.
//
//  Evidence is kept apart from implementation: "implemented, tested on
//  spec-built fixtures" is not "verified on real files", and "not
//  implemented" is said plainly instead of the name appearing in a matrix.
//

import Foundation

struct FormatCapability: Identifiable, Sendable, Equatable {
    enum Family: String, CaseIterable, Sendable {
        case mailSource          // files and folders the import opens
        case attachmentDocument  // attachment kinds read for search
        case archiveAttachment   // containers whose children are read
        case protectedContent    // encryption, signatures, rights
    }

    enum Evidence: String, Sendable {
        /// Run on files produced by the originating program.
        case realFixtures
        /// Run on fixtures written from the format description.
        case syntheticFixtures
        /// Code exists; no test has run it on a file of this kind.
        case notExecuted
        /// No reader; the file is kept and listed as unsupported.
        case notImplemented

        var isSupported: Bool { self != .notImplemented }
    }

    let id: String
    let family: Family
    /// The format's name as people know it (proper nouns and acronyms; not translated).
    let name: String
    let extensions: [String]
    /// What is read from it, for the public table.
    let whatIsRead: String
    let evidence: Evidence
    /// What is not read, or not read whole — the honest half of the row.
    let limitation: String?
    /// What only the owner or an environment can supply before the row can advance.
    let externalDependency: String?

    init(_ id: String, _ family: Family, _ name: String, _ extensions: [String], reads: String,
         evidence: Evidence, limitation: String? = nil, dependency: String? = nil) {
        self.id = id; self.family = family; self.name = name; self.extensions = extensions
        self.whatIsRead = reads; self.evidence = evidence; self.limitation = limitation; self.externalDependency = dependency
    }
}

enum FormatCapabilityRegistry {

    static let all: [FormatCapability] = [
        // MARK: Mail sources
        .init("mbox", .mailSource, "mbox", ["mbox"], reads: "every message, MIME tree, attachments, Gmail labels, thread links; offset engine streams any size",
              evidence: .realFixtures),
        .init("eml", .mailSource, "RFC 822 message", ["eml"], reads: "single messages and folders of them, with the folder as mailbox; sub-folders of a folder are kept as folder paths (Clients/Acme)", evidence: .realFixtures),
        .init("emlx", .mailSource, "Apple Mail message / library", ["emlx"], reads: "messages with flags, the mailbox chain from the library layout", evidence: .realFixtures),
        .init("applemail", .mailSource, "Apple Mail mailbox package", ["mbox (package)"], reads: "the mbox inside, mailbox chain", evidence: .syntheticFixtures,
              dependency: "a real Apple Mail export (owner)"),
        .init("maildir", .mailSource, "Maildir / Thunderbird folder", ["cur, new"],
              reads: "one message per file; the root as the inbox (the folder's own name), Maildir++ sub-mailboxes (.Sent, .Archive.2024 → Sent, Archive/2024) and nested mailboxes (Lists/Swift/cur) as their own folders, empty ones declared",
              evidence: .syntheticFixtures,
              limitation: "tmp/ (deliveries in progress) skipped and counted; cur/new/tmp are never folder names", dependency: "a real Dovecot/Courier Maildir++ export"),
        .init("msg", .mailSource, "Outlook message / template", ["msg", "oft"],
              reads: "MAPI properties: sender, recipients, subject, bodies (plain, HTML, RTF), attachments; embedded messages expanded as attached messages (three levels); .oft templates read as messages",
              evidence: .realFixtures,
              limitation: "17 Outlook-written messages from the Apache Tika and POI corpora (Unicode, Cyrillic, Chinese, HTML bodies, attached PDF/DOC, an embedded message) read with subject, body and attachments; .oft verified on Microsoft's official template (22 inline images byte-exact with their Content-IDs)"),
        .init("pst", .mailSource, "Outlook data file", ["pst"], reads: "ANSI and Unicode; folders including empty ones, recipients, bodies, attachments by the MS-PST layers; non-mail items counted out",
              evidence: .realFixtures,
              limitation: "bCryptMethod 0 (none), 1 (compressible / permutation) and 2 (high / cyclic) decoded on read (spec-written files of each kind read back through both entry points); 0x10 (Windows Information Protection) refused by name — those blocks are encrypted with a key held by Windows; the Outlook password (PidTagPstPassword) is a CRC, not encryption: such files are read in full and the import receipt says so",
              dependency: "small real PSTs with empty/deep/Unicode folders for the candidate run"),
        .init("ost", .mailSource, "Outlook offline store", ["ost"],
              reads: "shares the PST reader; the 4 KiB-page OST of Outlook 2013 and later (wVer 36) is read by its own page geometry (4096-byte B-tree pages, 24-byte trailers, 512-byte block alignment) with its zlib-compressed blocks inflated (BBTENTRY cbInflated); OLE attachments (ATTACH_OLE) read from their subnode stream",
              evidence: .realFixtures,
              limitation: "executed 2026-11-07 on two real files: Aspose SampleOstFile.ost (wVer 23, permute-encoded) — 87 of 87 mail items, 5 calendar items counted out, folders and Message-IDs equal to readpst's, all 36 readpst attachment payloads byte-identical; java-libpst example-2013.ost (wVer 36, 62 compressed blocks) — 3 of 3 messages with subjects, Message-IDs, dates and folders equal to readpst's. Outlook 2013 places the DList/AMap pages elsewhere than the spec writer's ost4K layout does (reader unaffected). No encrypted 4 KiB-page OST has been seen",
              dependency: "an encrypted (bCryptMethod 1/2) version-36 OST"),
        .init("nsf", .mailSource, "Lotus Notes database", ["nsf"],
              reads: "default (switch off): the old heuristic — scans the file for item records in mailin's own synthetic layout, then for 'Form: Memo' text lines. Preview Notes ODS reader (NotesODSPolicy, off by default): database header, the newest CX-compressed superblock (every summary and non-summary bucket descriptor page it declares) and bucket descriptor block, every RRV bucket, note headers, summary and non-summary item values; mail notes (Memo/Reply, or no Form with From/SendTo) rebuilt as RFC 5322 — native-MIME mail from its RFC822 header items and MIME parts in order, with parts kept in attachment objects restored byte for byte; Notes rich-text mail as plain text with header fields from From/SendTo/CopyTo/BlindCopyTo/Subject/PostedDate/$MessageID and $FILE attachments; attachment objects stored plain or Huffman-compressed (checksum-checked); folder membership from every folder's $FolderIDTable (nested by \\, a message in several folders keeps them all; folders declared, empty ones included; hidden helper folders only when they hold mail); sealed (encrypted) messages keep their unsealed items, the sealed ones named; design notes, deletion stubs, profiles and other documents counted by class and form, never imported; what a message could not give back is named on it",
              evidence: .syntheticFixtures,
              limitation: "default heuristic: executed 2026-11-07 on the public Aspose SampleNSF.nsf (47 MB, ODS 43) — 0 notes read; not verified, do not claim NSF import with the switch off. Preview ODS reader, executed 2026-11-07 on the same file (no Notes client available; checks made against the file itself): 1,626 RRV entries accounted for (1,412 note records + 203 objects + 11 entries whose slot carries another note ID); 1,030 design notes, 323 deletion stubs, 3 empty and 11 non-mail documents counted out; 45 of 45 mail notes read (all native MIME), 42 of 42 attachment objects decoded; every From and Message-ID line, and every Subject line, found verbatim in the database bytes; 43 of 45 Date headers equal the TIMEDATE stored beside them (the other two are damaged in the file); the one MIME attachment (7,655-byte PNG) byte-identical to the file. The sample has no Notes rich-text mail, so rich-text bodies (text runs and paragraphs only — no tables, fonts, links or embedded images) are verified on synthetic CD records only. Folders (R6, executed 2026-11-09 on the same file): 11 folders read, 0 unread; all 45 mail notes in Inbox (the Inbox ID table's 343 IDs in 6 runs equal its stated count, and each of the 45 is also in the Inbox's $FolderObject records with its own UNID); folders declared: Inbox, Junk Mail, Trash, Drafts, Sent, Parus; the sample's three Huffman objects (design-note bitmaps) decode to their stated sizes with matching checksums and BMP headers. The sample has one bucket descriptor page, no LZ1 object, no multi-record object, no sealed mail and no nested folder, so those are verified on a synthetic database only (two descriptor pages, nested folder, Huffman attachment, sealed mail). Not read: LZ1-compressed attachment objects (no public description, no sample) and objects longer than their one record (continuation layout not described anywhere, none in the sample) — named on the message, bytes not returned; sealed (encrypted) items — they need the recipient's Notes ID file, named on the message; folders without a $FolderIDTable (membership only in the folder collection, not decoded) — named in the inventory; databases whose descriptor pages do not all point at buckets are refused with that reason. Preview, off by default until the owner verifies a database of their own",
              dependency: "the owner's own Notes mail database (with folders, rich-text mail and attachments) and an independent inventory of it from Notes or Domino"),
        .init("olm", .mailSource, "Outlook for Mac archive", ["olm"], reads: "every message record rebuilt as RFC 5322 with folder, read/flag state, categories, priority, sent and received times, attachments' bytes with Content-IDs; contacts, contact groups, calendar, tasks and notes counted per record, never imported",
              evidence: .realFixtures,
              limitation: "executed 2026-11-07 on two real archives against an independent XML inventory: Aspose SampleOLM.olm — 22 of 22 mail records, 38 of 38 attachment occurrences byte-identical (24 with Content-ID), 11 folder paths, 3 contacts counted; Outlook 16 outlook_example.olm (teverett/OLMReader) — 7 of 7 records, 9 of 9 attachments, 5 contacts / 2 groups / 8 appointments / 5 tasks / 1 note counted. Times are read as UTC (Outlook writes no zone). Native pair (2026-11-09, the owner's supplied pack): one mail exported by Outlook for Mac 16.112.4 (Legacy mode) as OLM and by Apple Mail 16.0 as MBOX (plus the EML derived from it), imported, searched and exported as .eml by mailin — subject, From, To, HTML, both attachments' bytes/SHA-256 and the inline CID equal the pack's oracle across all three; the MBOX has no Date or Message-ID and none is claimed equal to the OLM's; the OLM's declared attachment sizes are not used, the real bytes are. One message only, not an identical-mailbox set: no native PST/OST/NSF of it exists",
              dependency: "a native OLM of a larger, controlled mailbox exported by the same clients (optional; the one-message pair is run)"),
        .init("zip-source", .mailSource, "ZIP / gzip / tar of mailboxes", ["zip", "z01…zNN (spanned)", "gz", "tgz", "tar"],
              reads: "each member classified on its bytes and imported; one level of nesting followed; a spanned ZIP set (archive.z01 … archive.zip) is read with the volumes in the same folder, a member on a missing volume refused and counted",
              evidence: .syntheticFixtures, limitation: "encrypted members and other compression methods refused and counted; spanned sets verified on Info-ZIP (zip -s) output written at test time"),
        .init("7z-rar-source", .mailSource, "7z / RAR of mailboxes", ["7z", "7z.001…", "rar", "part1.rar…", "r00…"],
              reads: "7z: each member decoded (Copy, LZMA, LZMA2, BCJ x86, Delta, Deflate) and classified on its bytes, a split .7z.001 set read with the volumes beside it; RAR: stored members copied and compressed members decoded (RAR 2.9–4.x, RAR 5.0 and RAR 7.0, solid archives included, through the vendored libarchive 3.8.11 reader, patched; RAR 1.5 and 2.0 by mailin's own decoder; CRC-32/BLAKE2 checked), a multi-volume set (name.part1.rar … or name.rar + name.r00 …) read with the volumes beside it",
              evidence: .syntheticFixtures,
              limitation: "7z members in BZip2/PPMd/BCJ2/ARM…, encrypted members (no password on import) and members on a missing volume are refused and counted; RAR: encrypted members and headers (no password is asked for on import), RAR 1.5/2.0 solid members after the first and RAR 1.5/2.0 encryption, a RAR 5.0/7.0 member whose decoding window exceeds the device limit (a quarter of its memory, at most 4 GiB) or whose header records no unpacked size, and members running into a missing volume are refused and counted; RAR 4 solid decoding verified only on libarchive's encrypted solid file and its decrypted form (libarchive's suite has no other RAR 4 solid archive); the RAR source path (member extraction, preflight, a four-volume set opened from its second volume) run on WinRAR-written archives from libarchive's test suite, which hold no mail — a mailbox imported from a compressed RAR has not been run; the 7z import on spec-built archives and the 7z reader on bsdtar/7-Zip files",
              dependency: "a real 7z / RAR mail export (owner)"),

        // MARK: Attachment documents
        .init("ooxml", .attachmentDocument, "Word, Excel, PowerPoint (Office Open XML)", ["docx", "docm", "dotx", "xlsx", "xlsm", "xltx", "pptx", "pptm", "ppsx", "potx"],
              reads: "body, tables, text boxes, headers/footers, footnotes, endnotes, comments; tracked changes labelled inline with author and date — insertions, deletions, moved text ({moved from} / {moved to}, never counted as insertion or deletion), formatting changes ({formatting changed}), revised paragraph marks and table rows — in the body, headers, footers, footnotes, endnotes, comments and text boxes, each also listed with its part and paragraph; every sheet (hidden and very hidden ones marked) with cell addresses, the stored result and the formula text (shared formulas re-based on the cell), number-formatted cells rendered as Excel displays them (dates, times, elapsed time, percentages, currencies, fractions, scientific, thousands and scaling, conditional sections, literal text; the 1900 system with its 29 February 1900 and the 1904 system), the stored serial or value kept beside the rendered text, hidden rows and columns labelled, defined names (hidden ones marked), external workbook references listed and never refreshed, comments, the 1904 date system stated; slides (hidden marked), notes, comments; chart titles, labels and values; embedded documents as child documents; Transitional and Strict namespaces",
              evidence: .realFixtures, limitation: "number formats are rendered in en-US whatever the author's locale (built-in 14 shows m/d/yyyy, English month and day names), without column-width effects (no * fill, no ####), native digits ([DBNum]) or era years (b, e, g); checked row by row against Excel's cached TEXT() results in Apache POI's format workbooks (number, General, date, elapsed, condition and text tests); a shared-formula reference that would leave the sheet is named, not shifted; Tika's Office files cover charts, comments, embedded objects, text boxes, Strict, real moves (testWORD_features) and shared formulas / date formats (testEXCEL, testEXCEL_dateFormats); tracked changes verified against the public pack's structured record (W05: two insertions, one deletion with author and date; W01/W06/W07 none)"),
        .init("ole", .attachmentDocument, "Word, Excel, PowerPoint 97–2003", ["doc", "dot", "xls", "xlt", "ppt", "pps", "pot"],
              reads: "Word text through the piece table; Excel cells with addresses, formula results, comments, hidden sheets; PowerPoint slide text",
              evidence: .syntheticFixtures, limitation: ".doc verified on a real file; .xls/.ppt on spec-built records; number formats not applied",
              dependency: "real .xls / .ppt files"),
        .init("odf", .attachmentDocument, "OpenDocument", ["odt", "ott", "ods", "ots", "odp", "otp"],
              reads: "body, headings, lists, tables (numbers and dates), sheets by name, slides and their notes, headers/footers (text, sheets, presentation master pages), footnotes, comments with their author, embedded objects as their own section; encrypted packages locked, or opened with a password (Blowfish CFB, AES-CBC, AES-256-GCM; PBKDF2 or Argon2id over a SHA-1/SHA-256 start key), per entry or as LibreOffice 24.2's single encrypted-package",
              evidence: .realFixtures,
              limitation: "verified on 21 OpenOffice.org 2/3, NeoOffice and LibreOffice files from Apache Tika (incl. the LibreOffice-encrypted one, password known), asserting Tika's own phrases; Argon2id (RFC 9106, checked on its test vectors) verified on two files encrypted with LibreOffice's parameters by the reference libargon2 and OpenSSL — no LibreOffice-written Argon2id file yet; Argon2id over 1 GiB of memory or 1,000 passes is reported by name; AES-128/192-GCM not read; macros listed and never run; formula (.odf) and drawing (.odg) documents are not read"),
        .init("iwork", .attachmentDocument, "Pages, Numbers, Keynote", ["pages", "numbers", "key"],
              reads: "iWork '09 XML (plain or gzip): paragraphs, table cells row by row with numbers, formula results, dates and pop-up menus, table and chart names with their labels, Pages headers/footers per page with the auto page number in the document's style, footnotes, comments, text boxes, Keynote slides, notes and master slides, Numbers sheets; IWA 2013+ (snappy + protobuf): text storages, slides, tables row by row from their tiles with numbers, dates, durations, booleans, formula results, text and rich text, named with their sheet; the 2018 zipped bundle with its inner Index.zip; password-protected '09 documents (Apple ZIP methods 25451/25452) locked, or opened with the password (PBKDF2-SHA1 + AES-128-CBC); password-protected 2013+ documents (.iwpv2 verifier, encrypted Index/*.iwa — single file or bundle with Index.zip) locked, or opened with the password (PBKDF2-SHA1 with the document's salt and iterations + AES-128-CBC)",
              evidence: .realFixtures,
              limitation: "verified on 22 Pages/Numbers/Keynote '09, 2013 and 2018 files from Apache Tika, asserting Tika's phrases, and the IWA cell values against the '09 version of the same workbook; the 2013 files use the older (pre-Numbers 5) cell storage; the newer one is read on a current Numbers file's text cells, its numbers (decimal128), dates, booleans and durations checked on records built from the published layout only; number formats (decimal places, currency symbols, percentages, custom formats) and pop-up menu choices are not applied — the stored value is shown; placeholder (ghost) text excluded; protected '09 unlock verified on Tika's Pages file (password known) only — Keynote/Numbers '09 use the same scheme but no protected sample; protected 2013+ unlock verified on Pages, Numbers and Keynote 14.4 files saved with a password through AppleScript (synthetic content, single file; Pages also as a zipped package bundle), each giving the same text as its unprotected twin — no Numbers/Keynote bundle sample, no document from an older 2013+ app version; each member's 20-byte trailer is not checked (its keying is not public), so the decrypted content's integrity is not cryptographically verified and every reading opened this way says so — the verifier checks only the password, and the padding and IWA framing catch only damage they can see (a damaged member is named: bad padding fails the document, garbled framing lists the member as not read; tested by flipped bytes in the Pages file); the unlock streams member by member through scratch files, so memory does not grow with the member count (checked on a 400-member synthetic document built from the scheme), and a cancellation or a full disk stops it with nothing half-written left; the password hint (.iwph) is not shown"),
        .init("pdf", .attachmentDocument, "PDF", ["pdf"], reads: "text layer; scanned or mixed pages recognised page by page (OCR on); locked files reported",
              evidence: .realFixtures, limitation: "no password entry for locked PDFs"),
        .init("image", .attachmentDocument, "Images", ["png", "jpg", "jpeg", "tiff", "heic", "gif", "bmp", "webp"], reads: "recognised text (OCR on), failures named per image",
              evidence: .realFixtures),
        .init("media", .attachmentDocument, "Audio and video", ["m4a", "mp3", "wav", "aiff", "mp4", "mov"], reads: "speech recognised on the device, language named",
              evidence: .notExecuted, limitation: "the end-to-end test skips until Speech Recognition is allowed for the app", dependency: "owner: allow Speech Recognition"),
        .init("rtf", .attachmentDocument, "Rich Text", ["rtf"], reads: "decoded text", evidence: .syntheticFixtures),
        .init("html", .attachmentDocument, "HTML", ["html", "htm"], reads: "text with tags removed", evidence: .syntheticFixtures),
        .init("text", .attachmentDocument, "Plain text families", ["txt", "csv", "log", "md", "json", "xml", "ics", "vcf", "yml", "yaml"], reads: "the text, UTF-8 or Latin-1",
              evidence: .syntheticFixtures),
        .init("eml-attached", .attachmentDocument, "Attached message", ["eml", "msg", "oft", "message/rfc822"],
              reads: "decoded headers and body (MIME for .eml, MAPI for .msg/.oft), its own attachments as children (three levels)",
              evidence: .syntheticFixtures, limitation: "each attachment of the message is its own child document (name, hash, state)"),
        .init("xlsb", .attachmentDocument, "Excel Binary Workbook", ["xlsb"],
              reads: "every sheet (hidden and very hidden ones marked) with cell addresses, cached values, booleans, errors; formula text decoded from the BIFF12 token stream (references, 3-D references, names, external names, operators, every documented worksheet and macro-sheet function by name, newer _xlfn. functions and add-in functions by name, table (structured) references as Excel shows them — Table1[Column], Table1[[#Headers],[Column]], Table1[#All], [@Column] — shared and array formulas re-based on the cell), number-formatted cells rendered as Excel displays them (dates, times, elapsed time, percentages, currencies, fractions, scientific, thousands and scaling, conditional sections, literal text; the 1900 system with its 29 February 1900 and the 1904 system), the stored serial or value kept beside the rendered text, hidden rows and columns labelled, defined names (hidden ones marked), external workbook references listed and never refreshed; cell comments with their author, beside the sheet as in .xlsx; shared strings; the 1904 date system stated",
              evidence: .realFixtures, limitation: "number formats are rendered in en-US whatever the author's locale, without column-width effects, native digits or era years (the same renderer as Office Open XML); a token the decoder does not know ends the formula with '(formula not decoded: token 0xNN)'; extra spacing Excel keeps in a formula (PtgAttrSpace) is not reproduced; a PivotTable calculated-field reference is named by its index; .xlsb has no natural-language formula tokens; threaded comments (Excel 365) are not read, only the legacy comment text Excel keeps beside them; verified on three Excel-written .xlsb from Apache Tika (testEXCEL_various: =C13*2, =COS(NA), =1/C13, a date, a percentage, a currency, a hidden name) and three from Apache POI (comments with authors in comments.xlsb and testVarious.xlsb, shared and array formulas in bug66682.xlsb); table references checked on spec-built bytes only — no public .xlsb with a table formula was found"),
        .init("visio-project", .attachmentDocument, "Visio drawing (VSDX), Project XML", ["vsdx", "vsdm", "vstx", "xml (MSPDI)"],
              reads: "Visio: every page's shape text under its page name; Project XML: project name, tasks (id, name, start, finish, notes), resources, assignments",
              evidence: .realFixtures, limitation: "Visio-written .vsdx/.vsdm from Apache Tika; MSPDI plans from the MPXJ corpus"),
        .init("tnef", .attachmentDocument, "TNEF (winmail.dat)", ["winmail.dat", "ms-tnef"],
              reads: "subject, sender, date and body (plain, HTML, compressed RTF); every file inside as a child document with its name and type; a message embedded in the TNEF (ATTACH_EMBEDDED_MSG, or a winmail.dat inside) expanded as an attached message with its own files as children, as many levels as the run's limit allows (three by default; Resume opens one more)",
              evidence: .realFixtures, limitation: "files verified on an Exchange-written winmail.dat from Apache Tika (five files out); embedded-message expansion verified on spec-built TNEF streams only — no real nested winmail.dat fixture; a message deeper than the level ceiling is kept as a winmail.dat child and said to be unexpanded"),
        // Directive 2026-11-07 §6 "Other business formats": one reader per family, each verified on files written by the program.
        .init("publisher", .attachmentDocument, "Publisher", ["pub"],
              reads: "the text of every text box in reading order (the Quill CONTENTS stream), hyperlink targets under [Links]; Publisher 2000 and later",
              evidence: .realFixtures, limitation: "Publisher 97/98 files (no Quill storage) are refused with the reason; pictures and drawing records listed as not text — verified on Publisher-written files from Apache Tika and POI (every line of POI's Sample.txt record)"),
        .init("onenote", .attachmentDocument, "OneNote section / notebook package", ["one", "onepkg"],
              reads: "every page's text from its latest revision (titles, outlines, hyperlinks as label <url>), then the text of earlier revisions and objects no page reaches under its own label; Office 365 / FSSHTTPB-packaged sections grouped by page the same way (storage manifest → cells → newest revision → page series); .onepkg cabinets (stored and MSZIP folders) with each section labelled; embedded files counted",
              evidence: .realFixtures, limitation: "page headings are numbered (\"Page N\"), the title is the page's own text line; an FSSHTTPB section whose page tree cannot be followed is read in storage order (the output says so); a section whose structure cannot be followed falls back to a labelled string scan; password-protected sections reported locked; LZX/Quantum cabinet folders named and not opened; OneNote 2003 and .onetoc2 not read — verified on 15 OneNote 2010–2016, Office 365 and 2007 files from Apache Tika"),
        .init("visio-binary", .attachmentDocument, "Visio drawing (binary)", ["vsd", "vss", "vst"],
              reads: "every shape's text through the pointer tree and Visio's LZW, one line per paragraph, grouped by page under the page's name in the drawing's page order (background pages marked), then stencil masters' text under the master's name; Visio 5 – 2010",
              evidence: .realFixtures, limitation: "Visio 5 page names are not read (pages labelled Page 1, Page 2…); text reached through no page or master is listed under Shapes; VBA listed as not text and never executed — verified on Visio 2000/2003 files from Apache Tika and POI, including POI's damaged regression files"),
        .init("project-binary", .attachmentDocument, "Project plan (binary)", ["mpp", "mpt"],
              reads: "document properties (title, subject, author, manager, company, category, keywords, comments); tasks as ID, name, start, finish, duration (as Project shows it, e.g. \"1 wk\", \"8.88 days\") and notes (RTF to plain text); resources as ID, name and notes; resource assignments (task → resource, units, work); Project 2000–2019 (MPP9/12/14)",
              evidence: .realFixtures, limitation: "not read: baselines, costs, predecessors, calendars, custom fields, the estimated-duration \"?\" mark and the project summary task's own assignments; a task whose fixed data is missing is listed without dates and said so; Project 98 (MPP8) and Project 4 give their properties and say their tasks are not read; a read password locks the file, a write-reservation password is decoded and noted — verified on Project 2003/2007/2013 files from Apache Tika and MPXJ, including MPXJ's password files; dates, durations and assignments checked against MPXJ's test assertions and an MSPDI twin, each project saved as MPP9, MPP12 and MPP14"),
        .init("access", .attachmentDocument, "Access database", ["mdb", "accdb", "mde", "accde"],
              reads: "every user table's rows as column=value: text, memo, numbers, currency, dates, Yes/No; Jet 3 (Access 97), Jet 4 (2000–2003) and ACE (2007–2019); OLE, binary, GUID and attachment columns listed as not text",
              evidence: .realFixtures, limitation: "encrypted databases (RC4 or the Office cipher) reported locked, no password entry; Microsoft Money (MSISAM) not read; system tables not dumped; a table that cannot be decoded is recorded by name — verified on Access 97/2000/2002–2003/2007 files from Apache Tika"),

        // MARK: Archive attachments
        .init("zip-attached", .archiveAttachment, "ZIP, tar, gzip attachments", ["zip", "z01…zNN (spanned)", "tar", "tgz", "gz", "gzip"],
              reads: "every child accounted for: documents, text, PDFs/images/recordings through the same readers; unread children listed; three levels; 1 GiB per attachment; a spanned ZIP read with its sibling volumes (the message's other attachments)",
              evidence: .syntheticFixtures, limitation: "each member is its own child document with path, hash and state, searchable and openable on its own; a member on a missing volume is \"not opened: volume N missing\" and the rest read; spanned sets verified on Info-ZIP output"),
        .init("7z", .archiveAttachment, "7z", ["7z", "7z.001…"],
              reads: "every member as a child document: Copy, LZMA, LZMA2, BCJ x86, Delta and Deflate decoded; 7zAES (AES-256) members and encrypted headers opened with Unlock…; solid blocks decoded once in order; split .7z.001 sets read with the sibling volumes",
              evidence: .realFixtures,
              limitation: "BZip2, PPMd, BCJ2, the ARM/ARM64/PowerPC/SPARC/IA-64/RISC-V filters and Zstandard/Brotli/LZ4 are named per member as \"compression method X not opened\"; a block whose LZMA dictionary exceeds the run's per-part ceiling is stopped with the ceiling named (Resume opens it); verified on bsdtar/libarchive 3.7.4 archives (Copy, LZMA, LZMA2, Deflate, BZip2, PPMd) and on official 7-Zip 26.05 AES-256 encrypted-header and libarchive's encrypted 7z corpus, every member's SHA-256 equal to the pack's oracle"),
        .init("rar", .archiveAttachment, "RAR", ["rar", "r00…rNN", "part1.rar…"],
              reads: "RAR 5.0 and RAR 1.5–4.x headers exact: every member's name, sizes, CRC-32, method, dictionary, encryption, solid and split flags; every member a child document — stored members copied, compressed members decoded by the vendored libarchive 3.8.11 reader (BSD-2-Clause, patched to carry a RAR 4 solid stream from member to member and to read RAR 7.0): the RAR 2.9–4.x algorithm (LZSS, PPMd, the standard filters), the RAR 5.0 algorithm (x86/ARM/delta filters) and the RAR 7.0 algorithm (compression version 1: 80 distance codes, dictionaries up to 1 TB incl. non-power-of-two sizes), any declared dictionary — the decoding window is sized to the data (the smallest power of two of at least 8 MiB holding the stream up to the member's end, so a 5 GiB dictionary on a small member needs 8 MiB) — solid archives decoded in order; the RAR 1.5 and RAR 2.0 algorithms (unpack versions 15, 20, 26, incl. RAR 2.0 multimedia audio compression) by mailin's own Swift decoder, streamed through a 4 MiB window; each member's CRC-32 or BLAKE2sp checked; with the password given through Unlock…, encrypted members and encrypted headers opened — RAR 3.x/4.x AES-128 (SHA-1 key derivation) and RAR 5.0 AES-256 (PBKDF2-HMAC-SHA256, the archive's password check value, checksums keyed to the password verified); a wrong password is \"the password did not open it\"; the password is never kept; a multi-volume set read as one archive with the other volumes attached to the same message handed over",
              evidence: .realFixtures,
              limitation: "without a password, encrypted members and encrypted headers stay locked; named per member as not opened: RAR 1.5/2.0 solid members after the first (no real solid RAR 1.5/2.0 archive found to verify on), RAR 1.5/2.0 members split across volumes, RAR 1.5/2.0 encryption, RAR 1.3 and other unknown unpack versions, RAR 5.0/7.0 compression versions above 1, a RAR 5.0/7.0 member whose decoding window would exceed the device limit (a quarter of its memory, at most 4 GiB, named as the window it needs), a RAR 5.0/7.0 member whose header records no unpacked size (written from a pipe into volumes), an encrypted member (or encrypted solid stream) split across volumes; RAR 3/4 stores no password check, so under a wrong password a member is named \"the password did not open it\" when it fails to decode or its CRC-32 differs; a member running into a missing volume is \"not opened: volume N (name) missing\"; a damaged member is named with the decoder's reason (in a solid stream, the members after it too); the per-part ceiling and the 1 GiB per attachment stop a member with the ceiling named (Resume opens it); verified on WinRAR-written RAR 4 and RAR 5 archives from libarchive's test suite (normal and best compression, PPMd, the E8 and ARM filters, solid, BLAKE2, multi-volume, damaged; encrypted: RAR 4 and RAR 5 data, file names and solid streams under libarchive's published passwords, and RAR 4 data/header encryption opened with \"12345678\"), the decoded bytes checked against what libarchive's own tests assert (exact bytes, sizes, tails, CRC-32s) and against WinRAR's header CRC-32; RAR 4 solid verified on libarchive's one RAR 4 solid file (encrypted) and its decrypted form; RAR 7.0 verified on archives written by RARLAB rar 7.23 for macOS (version 1 with 5 GiB and 4.5 GiB dictionaries, a version 1 member followed by version 0 members in one solid stream, a solid three-volume version 1 set, encrypted data and headers; RAR 5.0 with a 1 GiB dictionary), every member's CRC-32 and the SHA-256 of the generated text — no fixture holds a match more than 4 GiB back (it would need over 4 GiB of data), so the longest distance codes are decoded by no file; RAR 1.5 and 2.0 verified on real archives from junrar's and rarfile's public test suites (RAR 1.5x DOS and Windows, RAR 2.x normal and multimedia-audio), every member's CRC-32 and the WAV byte-identical to libarchive's decode of the RAR 2.9 archive of the same recording; RAR 3 key derivation for passwords over 28 characters follows unrar's SHA-1 variant but no such file has been run; a two-volume set attached to one message verified on a spec-built set",
              dependency: "the owner's own WinRAR mail archive"),
        .init("bz2-xz", .archiveAttachment, "bz2, xz", ["bz2", "xz"], reads: "—", evidence: .notImplemented, limitation: "kept as files, stated"),

        // MARK: Protected content
        .init("locked", .protectedContent, "Password-protected PDF / Office / archive members", [],
              reads: "detected and recorded as locked; Unlock… on the attachment takes a password once — PDF (PDFKit), Office Open XML Standard and Agile encryption, ZIP members (ZipCrypto and WinZip AES), RAR members and RAR encrypted headers (RAR 3/4 AES-128, RAR 5.0 AES-256; see the rar row), encrypted OpenDocument and protected iWork ('09 and 2013+) — and either shows the text for this view or stores it for search, as the person chooses; passwords are never kept",
              evidence: .realFixtures, limitation: "Office Standard and Agile verified on Word/Excel/PowerPoint-written files from Apache Tika and POI (incl. Excel's default password) and a protected PDF; ZipCrypto and AES-256 verified on archives made with official 7-Zip 26.05, AES-128/256 (deflated and stored) on libarchive's WinZip fixtures; RAR verified on libarchive's WinRAR-written encrypted files; encrypted OpenDocument opened by the odf row's rules (verified on Tika's LibreOffice file; Argon2id on independently built files); protected iWork documents by the iwork row's ('09 verified on Tika's Pages file; 2013+ on Pages/Numbers/Keynote 14.4 files made for the purpose); PST/OST are not password-encrypted (see the pst row); one file, one password"),
        .init("smime", .protectedContent, "S/MIME", [],
              reads: "originals kept; signatures verified where present (Mac: CMSDecoder; iPhone and iPad, and as the Mac's fallback: mailin's portable CMS reader — RSA PKCS#1 v1.5 and PSS, ECDSA P-256/384/521, SHA-1/256/384/512, opaque and detached, signer certificate from the message, trust judged by the system); with the module on, encrypted S/MIME parts (EnvelopedData and AuthEnvelopedData) are decrypted with a private key in this device's keychain — used in place, never exported — by RSA PKCS#1 v1.5 or RSA-OAEP key transport or ECDH P-256/384/521 key agreement (X9.63 KDF, AES key wrap), content in AES-128/192/256-CBC, AES-GCM or 3DES-CBC; the message inside is read with its attachments as children; on iPhone and iPad the identity is one imported as .p12 in Settings ▸ Health (password typed once, never kept)",
              evidence: .realFixtures,
              limitation: "off by default (preview); verified on envelopes and signatures written by OpenSSL 3.5.1 (RSA v1.5/OAEP, ECDH with SHA-1/256/384 KDFs, AES-CBC/GCM, 3DES, BER streaming, subject-key-identifier recipients; RSA, RSA-PSS and ECDSA signatures, opaque and detached) and on OpenSSL decrypting and verifying mailin-written ones, with throwaway identities made by the test, and the Mac CMSDecoder path on a disposable keychain identity; not read: KEK and password recipients, RC2/DES content, GCM tags under 16 bytes, SHA-224, DSA; identities installed by a configuration profile stay in the system keychain, which iOS does not open to other apps — import the .p12 instead; mail written by Outlook or Apple Mail with a production identity has not been run, and the iPhone/iPad keychain path has not been run on a device",
              dependency: "S/MIME mail from Outlook or Apple Mail with its identity (owner); a device run of the .p12 import"),
        .init("pgp", .protectedContent, "OpenPGP", ["gpg", "pgp", "asc", "sig"],
              reads: "detected and described: PGP/MIME (multipart/encrypted, multipart/signed), inline armor, .gpg/.pgp/.asc/.sig attachments; recipient key IDs (or v6 fingerprints) and algorithms, passphrase sessions, compression, literal data, MDC or AEAD protection; ASCII armor checked by its CRC-24; clearsigned and inline-signed text is read. Signatures VERIFIED against public keys the person imports into the archive's on-device keyring (.asc or binary; v4 and v6 keys; self-signatures, subkey bindings, expiry and revocation checked): good (key, user ID, time, whether the key had expired or been revoked by then), BAD, unknown key (issuer named), or cannot verify (reason) — for cleartext, inline (incl. ZIP/ZLIB-compressed), detached .sig/.asc beside the file it signs, and PGP/MIME signed mail; RSA, ECDSA P-256/P-384/P-521, EdDSA Ed25519 (legacy and v6), with SHA-1 and SHA2-256/384/512",
              evidence: .realFixtures,
              limitation: "never decrypted — public keys only, no secret keys or passphrases, no key server; encrypted content is recorded locked with the recipient key IDs; DSA, Elgamal, Ed448, Brainpool/secp256k1 curves, SHA-224, SHA-3, v5 keys and BZip2-compressed signed data are “cannot verify”, never “bad”; no web of trust (third-party certifications are not judged); verified on RFC 9580 Appendix A samples, PGPy 0.6.0-written keys and signatures (RSA 3072 + subkey, Ed25519, P-256/384/521, expired, revoked, PGP/MIME), and GnuPG's own release keys and a GnuPG-made signature from gnupg.org; no GnuPG on the build Mac, so GnuPG-written PGP/MIME mail has not been run",
              dependency: "GnuPG/Thunderbird-written PGP/MIME mail (owner)"),
        .init("irm", .protectedContent, "Rights-managed files, cloud references", [], reads: "—", evidence: .notImplemented,
              limitation: "no rights-aware access; references are kept as references"),
    ]

    static func capability(id: String) -> FormatCapability? { all.first { $0.id == id } }

    /// The public table, generated from this list (SUPPORTED_FORMATS_AND_LIMITS.md carries it verbatim).
    static func markdownTable() -> String {
        var lines = ["| Family | Format | Extensions | What is read | Evidence | Limitation | Still needed |", "|---|---|---|---|---|---|---|"]
        for c in all {
            let family: String
            switch c.family {
            case .mailSource: family = "Mail source"
            case .attachmentDocument: family = "Attachment"
            case .archiveAttachment: family = "Archive attachment"
            case .protectedContent: family = "Protected content"
            }
            let evidence: String
            switch c.evidence {
            case .realFixtures: evidence = "real files"
            case .syntheticFixtures: evidence = "spec-built fixtures"
            case .notExecuted: evidence = "not executed"
            case .notImplemented: evidence = "**not implemented**"
            }
            lines.append("| \(family) | \(c.name) | \(c.extensions.joined(separator: ", ")) | \(c.whatIsRead) | \(evidence) | \(c.limitation ?? "—") | \(c.externalDependency ?? "—") |")
        }
        return lines.joined(separator: "\n")
    }
}
