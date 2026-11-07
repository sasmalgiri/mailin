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
        .init("nsf", .mailSource, "Lotus Notes database", ["nsf"], reads: "heuristic: scans the whole file for item records in mailin's own synthetic layout and, failing that, for 'Form: Memo' text lines; LMBCS strings, attachments by $FILE item",
              evidence: .syntheticFixtures,
              limitation: "executed 2026-11-07 on the public Aspose SampleNSF.nsf (47 MB Notes mail database with a user's documents): 0 notes read — the reader does not parse the Notes ODS bucket layout, so real databases yield nothing; synthetic fixtures only prove the heuristic on its own layout. Not verified; do not claim NSF import",
              dependency: "a Notes ODS reader (bucket descriptors, RRV, summary/non-summary buckets, LZ1 compression) and an independent Notes inventory of a real database"),
        .init("olm", .mailSource, "Outlook for Mac archive", ["olm"], reads: "every message record rebuilt as RFC 5322 with folder, read/flag state, categories, priority, sent and received times, attachments' bytes with Content-IDs; contacts, contact groups, calendar, tasks and notes counted per record, never imported",
              evidence: .realFixtures,
              limitation: "executed 2026-11-07 on two real archives against an independent XML inventory: Aspose SampleOLM.olm — 22 of 22 mail records, 38 of 38 attachment occurrences byte-identical (24 with Content-ID), 11 folder paths, 3 contacts counted; Outlook 16 outlook_example.olm (teverett/OLMReader) — 7 of 7 records, 9 of 9 attachments, 5 contacts / 2 groups / 8 appointments / 5 tasks / 1 note counted. Times are read as UTC (Outlook writes no zone). Not yet run on the owner's own export with the same-message MBOX/EML set",
              dependency: "the owner's native export + Apple Mail MBOX + derived EML of one message (pack 1)"),
        .init("zip-source", .mailSource, "ZIP / gzip / tar of mailboxes", ["zip", "z01…zNN (spanned)", "gz", "tgz", "tar"],
              reads: "each member classified on its bytes and imported; one level of nesting followed; a spanned ZIP set (archive.z01 … archive.zip) is read with the volumes in the same folder, a member on a missing volume refused and counted",
              evidence: .syntheticFixtures, limitation: "encrypted members and other compression methods refused and counted; spanned sets verified on Info-ZIP (zip -s) output written at test time"),
        .init("7z-rar-source", .mailSource, "7z / RAR of mailboxes", ["7z", "7z.001…", "rar"],
              reads: "7z: each member decoded (Copy, LZMA, LZMA2, BCJ x86, Delta, Deflate) and classified on its bytes, a split .7z.001 set read with the volumes beside it; RAR: stored members imported",
              evidence: .syntheticFixtures,
              limitation: "7z members in BZip2/PPMd/BCJ2/ARM…, encrypted members (no password on import) and members on a missing volume are refused and counted; RAR-compressed and encrypted members refused and counted (RAR compression is not opened); the import run on spec-built archives, the readers themselves on bsdtar/7-Zip files",
              dependency: "a real 7z / RAR mail export (owner)"),

        // MARK: Attachment documents
        .init("ooxml", .attachmentDocument, "Word, Excel, PowerPoint (Office Open XML)", ["docx", "docm", "dotx", "xlsx", "xlsm", "xltx", "pptx", "pptm", "ppsx", "potx"],
              reads: "body, tables, text boxes, headers/footers, footnotes, endnotes, comments; tracked changes labelled inline with author and date — insertions, deletions, moved text ({moved from} / {moved to}, never counted as insertion or deletion), formatting changes ({formatting changed}), revised paragraph marks and table rows — in the body, headers, footers, footnotes, endnotes, comments and text boxes, each also listed with its part and paragraph; every sheet (hidden and very hidden ones marked) with cell addresses, the stored result and the formula text (shared formulas re-based on the cell), date-formatted serials rendered as the ISO date with the serial kept, percentages and currencies naming their format, hidden rows and columns labelled, defined names (hidden ones marked), external workbook references listed and never refreshed, comments, the 1904 date system stated; slides (hidden marked), notes, comments; chart titles, labels and values; embedded documents as child documents; Transitional and Strict namespaces",
              evidence: .realFixtures, limitation: "custom number formats are classified by their codes (date/time/percent/currency), not rendered digit for digit; a shared-formula reference that would leave the sheet is named, not shifted; Tika's Office files cover charts, comments, embedded objects, text boxes, Strict, real moves (testWORD_features) and shared formulas / date formats (testEXCEL, testEXCEL_dateFormats); tracked changes verified against the public pack's structured record (W05: two insertions, one deletion with author and date; W01/W06/W07 none)"),
        .init("ole", .attachmentDocument, "Word, Excel, PowerPoint 97–2003", ["doc", "dot", "xls", "xlt", "ppt", "pps", "pot"],
              reads: "Word text through the piece table; Excel cells with addresses, formula results, comments, hidden sheets; PowerPoint slide text",
              evidence: .syntheticFixtures, limitation: ".doc verified on a real file; .xls/.ppt on spec-built records; number formats not applied",
              dependency: "real .xls / .ppt files"),
        .init("odf", .attachmentDocument, "OpenDocument", ["odt", "ott", "ods", "ots", "odp", "otp"],
              reads: "body, headings, lists, tables (numbers and dates), sheets by name, slides and their notes, headers/footers (text, sheets, presentation master pages), footnotes, comments with their author, embedded objects as their own section; encrypted packages locked, or opened with a password (Blowfish CFB, AES-CBC, AES-GCM; PBKDF2 over a SHA-1/SHA-256 start key)",
              evidence: .realFixtures,
              limitation: "verified on 21 OpenOffice.org 2/3, NeoOffice and LibreOffice files from Apache Tika (incl. the LibreOffice-encrypted one, password known), asserting Tika's own phrases; macros listed and never run; Argon2id key derivation (LibreOffice 7.x option) named as locked, not done; formula (.odf) and drawing (.odg) documents are not read"),
        .init("iwork", .attachmentDocument, "Pages, Numbers, Keynote", ["pages", "numbers", "key"],
              reads: "iWork '09 XML (plain or gzip): paragraphs, table cells row by row with numbers, formula results, dates and pop-up menus, table and chart names with their labels, Pages headers/footers per page with the auto page number in the document's style, footnotes, comments, text boxes, Keynote slides, notes and master slides, Numbers sheets; IWA 2013+ (snappy + protobuf): text storages, slides, cell strings with sheet names; the 2018 zipped bundle with its inner Index.zip",
              evidence: .realFixtures,
              limitation: "verified on 22 Pages/Numbers/Keynote '09, 2013 and 2018 files from Apache Tika, asserting Tika's phrases; IWA numeric cell values (table tiles) are not decoded — strings only; placeholder (ghost) text excluded; password-protected '09 documents (Apple ZIP methods 25451/25452) reported locked by name, not opened"),
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
              reads: "every sheet (hidden and very hidden ones marked) with cell addresses, cached values, booleans, errors; formula text decoded from the BIFF12 token stream (references, 3-D references, names, operators, functions, shared and array formulas re-based on the cell), date-formatted serials rendered as the ISO date with the serial kept, percentages and currencies naming their format, hidden rows and columns labelled, defined names (hidden ones marked), external workbook references listed and never refreshed; shared strings; the 1904 date system stated",
              evidence: .realFixtures, limitation: "a token the decoder does not know ends the formula with '(formula not decoded: token 0xNN)' — table (structured) references and natural-language formulas are such tokens; functions outside the Excel function table are named by number; cell comments (comments1.bin) are not read; verified on three Excel-written .xlsb from Apache Tika (testEXCEL_various: =C13*2, =COS(NA), =1/C13, a date, a percentage, a currency, a hidden name)"),
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
              reads: "every page's text from its latest revision (titles, outlines, hyperlinks as label <url>), then the text of earlier revisions and objects no page reaches under its own label; Office 365 / FSSHTTPB-packaged sections in storage order; .onepkg cabinets (stored and MSZIP folders) with each section labelled; embedded files counted",
              evidence: .realFixtures, limitation: "FSSHTTPB-packaged sections are not grouped by page (the output says so); a section whose structure cannot be followed falls back to a labelled string scan; password-protected sections reported locked; LZX/Quantum cabinet folders named and not opened; OneNote 2003 and .onetoc2 not read — verified on 15 OneNote 2010–2016, Office 365 and 2007 files from Apache Tika"),
        .init("visio-binary", .attachmentDocument, "Visio drawing (binary)", ["vsd", "vss", "vst"],
              reads: "every shape's text through the pointer tree and Visio's LZW, one line per paragraph; Visio 5 – 2010",
              evidence: .realFixtures, limitation: "page names are not derivable from the public layout, so text is not grouped by page (the .vsdx reader does that); VBA listed as not text and never executed — verified on Visio 2000/2003 files from Apache Tika and POI, including POI's damaged regression files"),
        .init("project-binary", .attachmentDocument, "Project plan (binary)", ["mpp", "mpt"],
              reads: "document properties (title, subject, author, manager, company, category, keywords, comments); tasks and resources as ID, name and notes (RTF to plain text); Project 2000–2019 (MPP9/12/14)",
              evidence: .realFixtures, limitation: "dates, durations and assignments are not read (the Project XML reader has them); Project 98 (MPP8) and Project 4 give their properties and say their tasks are not read; a read password locks the file, a write-reservation password is decoded and noted — verified on Project 2003/2007/2013 files from Apache Tika and MPXJ, including MPXJ's password files"),
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
        .init("rar", .archiveAttachment, "RAR", ["rar", "r00…rNN"],
              reads: "RAR 5.0 and RAR 1.5–4.x headers exact: every member's name, sizes, CRC-32, method, encryption, solid and split flags; stored (uncompressed) members read as child documents",
              evidence: .syntheticFixtures,
              limitation: "compressed members are \"RAR compression not opened (needs a RAR decompressor)\"; encrypted members and encrypted headers reported locked, not decrypted; members continuing in another volume not opened; verified on spec-built RAR5/RAR4 archives only — no RAR writer exists on the development Mac",
              dependency: "a WinRAR-written archive (owner); a decision on a RAR decompressor (unrar source licence vs libarchive's BSD RAR5 reader)"),
        .init("bz2-xz", .archiveAttachment, "bz2, xz", ["bz2", "xz"], reads: "—", evidence: .notImplemented, limitation: "kept as files, stated"),

        // MARK: Protected content
        .init("locked", .protectedContent, "Password-protected PDF / Office / archive members", [],
              reads: "detected and recorded as locked; Unlock… on the attachment takes a password once — PDF (PDFKit), Office Open XML Standard and Agile encryption, ZIP members (ZipCrypto and WinZip AES) — and either shows the text for this view or stores it for search, as the person chooses; passwords are never kept",
              evidence: .realFixtures, limitation: "Office Standard and Agile verified on Word/Excel/PowerPoint-written files from Apache Tika and POI (incl. Excel's default password) and a protected PDF; ZipCrypto and AES-256 verified on archives made with official 7-Zip 26.05, AES-128/256 (deflated and stored) on libarchive's WinZip fixtures; encrypted OpenDocument opened by the odf row's rules (verified on Tika's LibreOffice file); PST/OST are not password-encrypted (see the pst row); one file, one password"),
        .init("smime", .protectedContent, "S/MIME", [],
              reads: "originals kept; signatures verified where present; with the module on (Mac), enveloped and signed S/MIME parts are decoded with a private key from the keychain and the message inside is read",
              evidence: .notExecuted, limitation: "Mac only (CMSDecoder); off by default", dependency: "a test identity in the keychain (owner)"),
        .init("pgp", .protectedContent, "OpenPGP", ["gpg", "pgp", "asc", "sig"],
              reads: "detected and described without a key: PGP/MIME (multipart/encrypted + application/pgp-encrypted, multipart/signed + application/pgp-signature), inline armor, .gpg/.pgp/.asc attachments; the packet headers name the recipient key IDs (or v6 fingerprints) and algorithms, passphrase sessions and their cipher, signatures (version, type, hash and key algorithms, issuer, time), compression, literal data, and whether an MDC or AEAD protects the data; ASCII armor checked by its CRC-24; clearsigned text is read",
              evidence: .syntheticFixtures,
              limitation: "never decrypted and never verified — this release has no OpenPGP key store or trust store; encrypted content is recorded locked with the recipient key IDs, signatures as “present, not verified”; packets built from RFC 4880/9580 — no GnuPG on the build Mac, so no GnuPG-written file has been run",
              dependency: "GnuPG- or Sequoia-written fixtures (owner); a dependency decision for decryption (ObjectivePGP, MIT, or Sequoia-PGP via FFI) before any key handling"),
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
