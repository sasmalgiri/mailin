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
              reads: "shares the PST reader; the 4 KiB-page OST of Outlook 2013 and later (wVer 36) is read by its own page geometry (4096-byte B-tree pages, 24-byte trailers, 512-byte block alignment)",
              evidence: .syntheticFixtures,
              limitation: "wVer 36 read on a spec-built synthetic OST only (geometry from the libpff description of the 2013 format); real example-2013.ost pending owner fixture",
              dependency: "a real OST (example-2013.ost, Aspose SampleOstFile.ost)"),
        .init("nsf", .mailSource, "Lotus Notes database", ["nsf"], reads: "structured notes with LZSS and LMBCS, attachments by item; heuristic text scan as fallback",
              evidence: .syntheticFixtures, limitation: "fallback path is not byte-exact", dependency: "a real NSF"),
        .init("olm", .mailSource, "Outlook for Mac archive", ["olm"], reads: "every message record rebuilt as RFC 5322 with folder, flags, category, attachments' bytes; contacts/calendar/tasks/notes counted out",
              evidence: .syntheticFixtures, dependency: "a real Outlook for Mac export"),
        .init("zip-source", .mailSource, "ZIP / gzip / tar of mailboxes", ["zip", "gz", "tgz", "tar"], reads: "each member classified on its bytes and imported; one level of nesting followed",
              evidence: .syntheticFixtures, limitation: "encrypted members and other compression methods refused and counted"),

        // MARK: Attachment documents
        .init("ooxml", .attachmentDocument, "Word, Excel, PowerPoint (Office Open XML)", ["docx", "docm", "dotx", "xlsx", "xlsm", "xltx", "pptx", "pptm", "ppsx", "potx"],
              reads: "body, tables, text boxes, headers/footers, footnotes, comments, tracked changes labelled; every sheet (hidden ones marked) with cell addresses, cached values and formulas, comments, the 1904 date system stated; slides (hidden marked), notes, comments; chart titles, labels and values; embedded documents as child documents; Transitional and Strict namespaces",
              evidence: .realFixtures, limitation: "displayed (number-formatted) values are not derived from raw values; Tika's Office files cover charts, comments, embedded objects, text boxes and Strict; tracked changes verified on a Word for Microsoft 365 file with a ground-truth record (two insertions, one deletion)"),
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
              reads: "every sheet (hidden ones marked) with cell addresses, cached values, booleans, errors; shared strings; the 1904 date system stated",
              evidence: .realFixtures, limitation: "formula cells show their cached value and {formula}; the formula text itself is not rebuilt from the binary tokens (three Excel-written .xlsb from Apache Tika)"),
        .init("visio-project", .attachmentDocument, "Visio drawing (VSDX), Project XML", ["vsdx", "vsdm", "vstx", "xml (MSPDI)"],
              reads: "Visio: every page's shape text under its page name; Project XML: project name, tasks (id, name, start, finish, notes), resources, assignments",
              evidence: .realFixtures, limitation: "Visio-written .vsdx/.vsdm from Apache Tika; MSPDI plans from the MPXJ corpus"),
        .init("tnef", .attachmentDocument, "TNEF (winmail.dat)", ["winmail.dat", "ms-tnef"],
              reads: "subject, sender, date and body (plain, HTML, compressed RTF); every file inside as a child document with its name and type; a message embedded in the TNEF (ATTACH_EMBEDDED_MSG, or a winmail.dat inside) expanded as an attached message with its own files as children, as many levels as the run's limit allows (three by default; Resume opens one more)",
              evidence: .realFixtures, limitation: "files verified on an Exchange-written winmail.dat from Apache Tika (five files out); embedded-message expansion verified on spec-built TNEF streams only — no real nested winmail.dat fixture; a message deeper than the level ceiling is kept as a winmail.dat child and said to be unexpanded"),
        .init("other-office", .attachmentDocument, "OneNote, Visio binary, Project binary, Publisher, Access", ["one", "onepkg", "vsd", "mpp", "pub", "mdb", "accdb"], reads: "—",
              evidence: .notImplemented, limitation: "no reader; a new adapter project per family (the XML forms VSDX and Project XML are read)"),

        // MARK: Archive attachments
        .init("zip-attached", .archiveAttachment, "ZIP, tar, gzip attachments", ["zip", "tar", "tgz", "gz", "gzip"],
              reads: "every child accounted for: documents, text, PDFs/images/recordings through the same readers; unread children listed; three levels; 1 GiB per attachment",
              evidence: .syntheticFixtures, limitation: "each member is its own child document with path, hash and state, searchable and openable on its own; 7z/RAR/split volumes not opened"),
        .init("7z-rar", .archiveAttachment, "7z, RAR, bz2, xz", ["7z", "rar", "bz2", "xz"], reads: "—", evidence: .notImplemented, limitation: "kept as files, stated"),

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
