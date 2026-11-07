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
        .init("eml", .mailSource, "RFC 822 message", ["eml"], reads: "single messages and folders of them, with the folder as mailbox", evidence: .realFixtures),
        .init("emlx", .mailSource, "Apple Mail message / library", ["emlx"], reads: "messages with flags, the mailbox chain from the library layout", evidence: .realFixtures),
        .init("applemail", .mailSource, "Apple Mail mailbox package", ["mbox (package)"], reads: "the mbox inside, mailbox chain", evidence: .syntheticFixtures,
              dependency: "a real Apple Mail export (owner)"),
        .init("maildir", .mailSource, "Maildir / Thunderbird folder", ["cur, new"], reads: "one message per file, the folder as mailbox", evidence: .syntheticFixtures,
              limitation: "Maildir++ sub-folders flatten to the root name; tmp/ skipped by design"),
        .init("msg", .mailSource, "Outlook message", ["msg"], reads: "MAPI properties: sender, recipients, subject, bodies (plain, HTML, RTF), attachments", evidence: .realFixtures,
              limitation: "embedded messages recognised, not expanded; OFT templates not read"),
        .init("pst", .mailSource, "Outlook data file", ["pst"], reads: "ANSI and Unicode; folders including empty ones, recipients, bodies, attachments by the MS-PST layers; non-mail items counted out",
              evidence: .realFixtures, dependency: "small real PSTs with empty/deep/Unicode folders for the candidate run"),
        .init("ost", .mailSource, "Outlook offline store", ["ost"], reads: "shares the PST reader", evidence: .notExecuted,
              limitation: "4 KB-page OST (Outlook 2013+, wVer 36) not read by layout", dependency: "a real OST"),
        .init("nsf", .mailSource, "Lotus Notes database", ["nsf"], reads: "structured notes with LZSS and LMBCS, attachments by item; heuristic text scan as fallback",
              evidence: .syntheticFixtures, limitation: "fallback path is not byte-exact", dependency: "a real NSF"),
        .init("olm", .mailSource, "Outlook for Mac archive", ["olm"], reads: "every message record rebuilt as RFC 5322 with folder, flags, category, attachments' bytes; contacts/calendar/tasks/notes counted out",
              evidence: .syntheticFixtures, dependency: "a real Outlook for Mac export"),
        .init("zip-source", .mailSource, "ZIP / gzip / tar of mailboxes", ["zip", "gz", "tgz", "tar"], reads: "each member classified on its bytes and imported; one level of nesting followed",
              evidence: .syntheticFixtures, limitation: "encrypted members and other compression methods refused and counted"),

        // MARK: Attachment documents
        .init("ooxml", .attachmentDocument, "Word, Excel, PowerPoint (Office Open XML)", ["docx", "docm", "dotx", "xlsx", "xlsm", "xltx", "pptx", "pptm", "ppsx", "potx"],
              reads: "body, tables, headers/footers, footnotes, comments; sheets with cell addresses, formulas, shared strings; slides and notes",
              evidence: .syntheticFixtures, limitation: "Strict OOXML namespaces, XLSB, text boxes, deleted revisions, chart labels not read",
              dependency: "real files from each program for the candidate run"),
        .init("ole", .attachmentDocument, "Word, Excel, PowerPoint 97–2003", ["doc", "dot", "xls", "xlt", "ppt", "pps", "pot"],
              reads: "Word text through the piece table; Excel cells with addresses, formula results, comments, hidden sheets; PowerPoint slide text",
              evidence: .syntheticFixtures, limitation: ".doc verified on a real file; .xls/.ppt on spec-built records; number formats not applied",
              dependency: "real .xls / .ppt files"),
        .init("odf", .attachmentDocument, "OpenDocument", ["odt", "ott", "ods", "ots", "odp", "otp"], reads: "text, sheets, slides and notes, headers/footers; encrypted packages reported locked",
              evidence: .syntheticFixtures, dependency: "real LibreOffice files"),
        .init("iwork", .attachmentDocument, "Pages, Numbers, Keynote", ["pages", "numbers", "key"], reads: "IWA (snappy + protobuf) and iWork '09 XML: body, table cells, slides",
              evidence: .realFixtures),
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
        .init("eml-attached", .attachmentDocument, "Attached message", ["eml", "message/rfc822"], reads: "decoded headers and body, its own attachments as children (three levels)",
              evidence: .syntheticFixtures, limitation: "each attachment of the message is its own child document (name, hash, state); MSG/TNEF children not yet"),
        .init("xlsb", .attachmentDocument, "Excel Binary Workbook", ["xlsb"], reads: "—", evidence: .notImplemented, limitation: "no reader; kept and listed as unsupported"),
        .init("oft-tnef", .attachmentDocument, "Outlook template / TNEF", ["oft", "winmail.dat"], reads: "—", evidence: .notImplemented, limitation: "no reader"),
        .init("other-office", .attachmentDocument, "OneNote, Visio, Project, Publisher, Access", ["one", "onepkg", "vsd", "vsdx", "mpp", "pub", "mdb", "accdb"], reads: "—",
              evidence: .notImplemented, limitation: "no reader; a new adapter project per family"),

        // MARK: Archive attachments
        .init("zip-attached", .archiveAttachment, "ZIP, tar, gzip attachments", ["zip", "tar", "tgz", "gz", "gzip"],
              reads: "every child accounted for: documents, text, PDFs/images/recordings through the same readers; unread children listed; three levels; 1 GiB per attachment",
              evidence: .syntheticFixtures, limitation: "each member is its own child document with path, hash and state, searchable and openable on its own; 7z/RAR/split volumes not opened"),
        .init("7z-rar", .archiveAttachment, "7z, RAR, bz2, xz", ["7z", "rar", "bz2", "xz"], reads: "—", evidence: .notImplemented, limitation: "kept as files, stated"),

        // MARK: Protected content
        .init("locked", .protectedContent, "Password-protected PDF / Office / archive members", [], reads: "detected and reported as locked",
              evidence: .syntheticFixtures, limitation: "no password entry, retry or credential retention"),
        .init("smime", .protectedContent, "S/MIME and OpenPGP", [], reads: "originals kept; signatures verified where present", evidence: .notExecuted,
              limitation: "no decrypt-and-index path"),
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
