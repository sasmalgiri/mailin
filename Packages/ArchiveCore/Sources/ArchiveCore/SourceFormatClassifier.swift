//
//  SourceFormatClassifier.swift
//  mailin
//
//  Decides WHICH parser a source file goes to, from its CONTENT.
//
//  Before this, routing was the file extension alone
//  (`ParserFactory.parseStreamingCallback` switched on `pathExtension`), and
//  the individual parsers validated their magic bytes only after being chosen.
//  That left two real defects:
//
//   • A PST/OST/ZIP/gzip file named `.mbox` was handed to the MBOX parser,
//     which has no signature check. It would happily read binary as text and
//     manufacture junk "messages" — silent corruption of an evidence archive,
//     the worst failure mode this app has.
//   • A perfectly good mbox named `mail.txt` (or `Takeout-1`, or anything a
//     user renamed) was rejected as an unsupported type.
//
//  Content decides; the extension is a hint. Every classification carries the
//  evidence for the decision so an import receipt can state why a file was
//  routed the way it was, and a mismatch between name and content is reported
//  rather than hidden.
//

import Foundation

/// A source container format — what a file IS, not what it is called.
enum SourceFormat: String, Sendable, Equatable, CaseIterable {
    case mbox
    case eml
    case emlx
    case msg
    case pst
    case ost
    case nsf
    /// Containers: imported member by member through `ZIPArchiveReader`
    /// (streamed to a scratch file, one at a time; v2.1 backlog #1).
    case zip
    case gzip
    /// TYPE-06: a tar wrapper (`.tar`; `.tgz` / `.tar.gz` is gzip → tar),
    /// imported member by member through `TARReader`.
    case tar
    /// TYPE-06: an Outlook for Mac archive — a ZIP whose records are
    /// Outlook's message XML; read by `OLMParser`, never member-classified.
    case olm
    /// Directive 2026-11-07 §6 "Containers": a 7z archive (`SevenZipReader`;
    /// `.7z.001` split sets with their sibling volumes) and a RAR archive
    /// (`RARReader`: stored and compressed members imported — RAR 2.9–4.x
    /// and RAR 5.0 through the vendored libarchive reader — the rest refused
    /// and counted), imported member by member like ZIP.
    case sevenZip
    case rar
    /// Directory forms.
    case appleMailMailbox     // Apple Mail's .mbox *package*
    case appleMailLibrary     // Mail's own folders: <box>.mbox/<UUID>/Data/…/Messages/*.emlx
    case maildir              // cur/new/tmp
    case emlFolder            // a plain folder of .eml files
    case unknown

    var isSupported: Bool {
        switch self {
        case .mbox, .eml, .emlx, .msg, .pst, .ost, .nsf,
             .appleMailMailbox, .appleMailLibrary, .maildir, .emlFolder, .zip, .gzip, .tar, .olm, .sevenZip, .rar:
            return true
        case .unknown:
            return false
        }
    }

    /// ZIP, gzip, tar, 7z, RAR: the messages are inside; each member is
    /// extracted to a scratch file and classified on its own contents.
    var isContainer: Bool { self == .zip || self == .gzip || self == .tar || self == .sevenZip || self == .rar }

    /// The parser that handles this format, as an extension token the existing
    /// `ParserFactory` dispatch understands.
    var parserToken: String {
        switch self {
        case .mbox, .appleMailMailbox, .maildir, .emlFolder: return "mbox"
        case .eml: return "eml"
        case .emlx, .appleMailLibrary: return "emlx"
        case .msg: return "msg"
        case .pst: return "pst"
        case .ost: return "ost"
        case .nsf: return "nsf"
        case .zip: return "zip"
        case .gzip: return "gzip"
        case .tar: return "tar"
        case .olm: return "olm"
        case .sevenZip: return "7z"
        case .rar: return "rar"
        case .unknown: return ""
        }
    }

    var displayName: String {
        switch self {
        case .mbox: return "mbox mailbox"
        case .eml: return "single RFC 822 message (.eml)"
        case .emlx: return "Apple Mail message (.emlx)"
        case .msg: return "Outlook message (.msg)"
        case .pst: return "Outlook data file (.pst)"
        case .ost: return "Outlook offline store (.ost)"
        case .nsf: return "Lotus Notes database (.nsf)"
        case .zip: return "ZIP archive"
        case .gzip: return "gzip-compressed file"
        case .tar: return "tar archive"
        case .sevenZip: return "7z archive"
        case .rar: return "RAR archive"
        case .olm: return "Outlook for Mac archive (.olm)"
        case .appleMailMailbox: return "Apple Mail mailbox package"
        case .appleMailLibrary: return "Apple Mail folder (.emlx messages)"
        case .maildir: return "Maildir folder"
        case .emlFolder: return "folder of .eml messages"
        case .unknown: return "unrecognised file"
        }
    }

    /// What the user should do when this format cannot be imported as-is.
    var advice: String? {
        switch self {
        case .zip:
            return "Each mailbox file inside will be imported; other files, encrypted members and nested archives are skipped and counted."
        case .gzip:
            return "The compressed mailbox inside will be imported."
        case .tar:
            return "Each mailbox file inside will be imported; other files and archives nested more than one level down are skipped and counted."
        case .sevenZip:
            return "Each mailbox file inside will be imported (a split .7z.001 set is read with the volumes next to it); encrypted members, methods this reader does not open and nested archives are skipped and counted."
        case .rar:
            return "Each mailbox file inside will be imported (a multi-volume set is read with the volumes next to it); encrypted members, compressions this reader does not open and nested archives are skipped and counted."
        case .olm:
            return "Every message record is imported with its folder, flags and attachments; contacts, calendar items, tasks and notes are counted and left in the file."
        case .unknown:
            return "This file does not look like any mail format mailin can read. Check that it is a mailbox export and not, for example, a database or a disk image."
        default:
            return nil
        }
    }
}

/// The classifier's decision, with the evidence behind it.
struct SourceClassification: Sendable, Equatable {
    var format: SourceFormat
    /// Why — quoted in the import receipt and the pre-import sheet.
    var evidence: String
    /// The extension the file carried, lowercased ("" when absent).
    var extensionHint: String
    /// True when the name says one thing and the bytes say another. Content
    /// wins; this flag makes the disagreement visible.
    var nameContentMismatch: Bool
    /// Set when the bytes look like a supported format that is damaged or
    /// encrypted, so the UI can say so before a parse is attempted.
    var warning: String?

    var isSupported: Bool { format.isSupported }

    /// One line for the receipt / progress UI.
    var summary: String {
        var text = "Detected \(format.displayName) — \(evidence)"
        if nameContentMismatch {
            text += ". The file is named .\(extensionHint), which does not match its contents"
        }
        if let warning { text += ". \(warning)" }
        return text
    }
}

enum SourceFormatClassifier {

    /// How much of the file the classifier reads. Enough for a MIME header
    /// block and several mbox separators; never the whole file.
    static let probeBytes = 64 * 1024

    // MARK: - Entry point

    static func classify(url: URL) -> SourceClassification {
        let ext = url.pathExtension.lowercased()

        // Directories first: Apple Mail packages and Maildir folders are real
        // sources, and reading them as a byte stream would fail confusingly.
        if let directory = classifyDirectory(url: url, ext: ext) { return directory }

        guard let probe = readProbe(url: url), !probe.isEmpty else {
            return SourceClassification(
                format: .unknown,
                evidence: "the file is empty or could not be read",
                extensionHint: ext, nameContentMismatch: false, warning: nil)
        }

        // Directive §6 "Containers": the LAST volume of a spanned ZIP set
        // (`set.zip` beside `set.z01 …`) begins with the tail of whatever
        // member ran over from the previous volume — often mailbox text — and
        // only its end-of-central-directory record says what it is. Decided
        // from that record for files named as ZIP volumes, before any text rule.
        if let part = SplitVolumeSet.part(ofName: url.lastPathComponent), part.kind == .zipSpanned,
           !(probe.count >= 2 && probe[probe.startIndex] == 0x50 && probe[probe.startIndex + 1] == 0x4B),
           let disks = ZIPArchiveReader.spannedDiskCount(url: url) {
            return SourceClassification(
                format: .zip,
                evidence: "end-of-central-directory record of a spanned ZIP set (\(disks) volumes; this is volume \(disks))",
                extensionHint: ext, nameContentMismatch: false, warning: nil)
        }

        if var byMagic = classifyByMagic(probe, ext: ext, currentURL: url) {
            // S1: attach the documented size verdict now, so the pre-import
            // sheet can warn before a parse is attempted rather than after.
            byMagic.warning = sizeWarning(for: byMagic.format, url: url, probe: probe)
                ?? byMagic.warning
            return byMagic
        }
        if let byText = classifyByText(probe, ext: ext) { return byText }

        return SourceClassification(
            format: .unknown,
            evidence: "no mail-format signature or RFC 822 header block in the first \(probe.count) bytes",
            extensionHint: ext,
            nameContentMismatch: !ext.isEmpty,
            warning: nil)
    }

    // MARK: - Binary signatures

    private static func classifyByMagic(_ data: Data, ext: String, currentURL: URL? = nil) -> SourceClassification? {
        func has(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            guard data.count >= offset + bytes.count else { return false }
            let start = data.index(data.startIndex, offsetBy: offset)
            return Array(data[start..<data.index(start, offsetBy: bytes.count)]) == bytes
        }

        // PST/OST: "!BDN". The 11th byte distinguishes the two in practice, but
        // both route to the same parser, so prefer the extension for the label.
        if has([0x21, 0x42, 0x44, 0x4E]) {
            let format: SourceFormat = (ext == "ost") ? .ost : .pst
            return SourceClassification(
                format: format,
                evidence: "PST/OST signature \"!BDN\" at offset 0",
                extensionHint: ext,
                nameContentMismatch: !(ext == "pst" || ext == "ost"),
                warning: nil)
        }

        // OLE compound document — Outlook .msg lives in one of these, and so
        // does an Outlook template (.oft): the same MAPI streams, read the same way.
        if has([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            return SourceClassification(
                format: .msg,
                evidence: ext == "oft" ? "OLE compound-document signature at offset 0 (Outlook template)" : "OLE compound-document signature at offset 0",
                extensionHint: ext,
                nameContentMismatch: !(ext == "msg" || ext == "oft"),
                warning: nil)
        }

        // Directive §6 "Containers": 7z, RAR (4.x and 5.0), and the first
        // volume of a spanned ZIP (PK\x07\x08 spanning marker before the
        // first local header).
        if has([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) {
            let isVolume = SplitVolumeSet.part(ofName: currentURL?.lastPathComponent ?? "")?.kind == .sevenZipSplit
            return SourceClassification(
                format: .sevenZip,
                evidence: isVolume ? "7z signature at offset 0 (first volume of a split set)" : "7z signature at offset 0",
                extensionHint: ext,
                nameContentMismatch: ext != "7z" && !isVolume,
                warning: nil)
        }
        if has([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]) || has([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]) {
            let isNewFormat = has([0x01], at: 6)
            return SourceClassification(
                format: .rar,
                evidence: isNewFormat ? "RAR 5.0 signature at offset 0" : "RAR 1.5–4.x signature at offset 0",
                extensionHint: ext,
                nameContentMismatch: ext != "rar" && !(ext.count == 3 && ext.hasPrefix("r") && Int(ext.dropFirst()) != nil),
                warning: nil)
        }
        if has([0x50, 0x4B, 0x07, 0x08]) {
            return SourceClassification(
                format: .zip,
                evidence: "ZIP spanning marker PK\\x07\\x08 at offset 0 (first volume of a split set; the other volumes are read from the same folder)",
                extensionHint: ext,
                nameContentMismatch: SplitVolumeSet.part(ofName: currentURL?.lastPathComponent ?? "")?.kind != .zipSpanned,
                warning: nil)
        }
        if has([0x50, 0x4B, 0x03, 0x04]) || has([0x50, 0x4B, 0x05, 0x06]) {
            // TYPE-06: an Outlook for Mac archive is a ZIP whose directory
            // holds `com.microsoft.__Messages/` records. Decided from the
            // directory, not the name — a renamed .olm is still an OLM, and a
            // plain ZIP named .olm is still a ZIP of whatever it holds.
            if let url = currentURL, let members = try? ZIPArchiveReader.members(of: url), OLMParser.isOLM(members: members) {
                return SourceClassification(
                    format: .olm,
                    evidence: "ZIP whose directory holds Outlook for Mac message records (com.microsoft.__Messages)",
                    extensionHint: ext,
                    nameContentMismatch: ext != "olm",
                    warning: nil)
            }
            return SourceClassification(
                format: .zip,
                evidence: "ZIP signature \"PK\" at offset 0",
                extensionHint: ext,
                nameContentMismatch: ext != "zip" && ext != "olm",
                warning: nil)
        }

        // TYPE-06: tar — ustar magic at offset 257, or a pre-POSIX header
        // whose checksum verifies. Checked before the text rules because a
        // tar of mbox files begins with a header block followed by mail text.
        if TARReader.looksLikeTar(data) {
            return SourceClassification(
                format: .tar,
                evidence: "tar header block at offset 0 (ustar magic or verified header checksum)",
                extensionHint: ext,
                nameContentMismatch: ext != "tar",
                warning: nil)
        }

        if has([0x1F, 0x8B]) {
            return SourceClassification(
                format: .gzip,
                evidence: "gzip signature at offset 0",
                extensionHint: ext,
                nameContentMismatch: ext != "gz" && ext != "gzip" && ext != "tgz",
                warning: nil)
        }

        // Lotus Notes NSF: 0x1A00 is the common leading signature.
        if has([0x1A, 0x00]) {
            return SourceClassification(
                format: .nsf,
                evidence: "Notes database signature 0x1A00 at offset 0",
                extensionHint: ext,
                nameContentMismatch: ext != "nsf",
                warning: nil)
        }

        return nil
    }

    /// The documented format/product size verdict for a detected binary
    /// format, phrased for the user. Refusals are enforced by the parsers;
    /// this is the early warning.
    private static func sizeWarning(for format: SourceFormat, url: URL, probe: Data) -> String? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        switch format {
        case .pst, .ost:
            let verdict = SourceSizePolicy.pstVerdict(
                version: SourceSizePolicy.pstFormatVersion(fromHeader: probe), fileSize: size)
            return verdict.refusal ?? verdict.warning
        case .nsf:
            let verdict = SourceSizePolicy.nsfVerdict(fileSize: size)
            return verdict.refusal ?? verdict.warning
        default:
            return nil
        }
    }

    // MARK: - Text structure

    private static func classifyByText(_ data: Data, ext: String) -> SourceClassification? {
        // Decode leniently: a mailbox may hold any charset, and a strict UTF-8
        // decode failing must not be read as "not mail".
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else { return nil }

        // Reject binary-looking content before treating it as text, so a
        // random binary file cannot be mistaken for a mailbox.
        let controlCount = data.prefix(4096).filter { $0 < 0x09 || ($0 > 0x0D && $0 < 0x20) }.count
        if controlCount > 64 {
            return SourceClassification(
                format: .unknown,
                evidence: "content is binary (\(controlCount) control bytes in the first 4 KB) and matches no known mail signature",
                extensionHint: ext, nameContentMismatch: !ext.isEmpty, warning: nil)
        }

        let lines = text.components(separatedBy: .newlines)

        // EMLX: a byte count on the first line, then the message.
        if let first = lines.first,
           !first.isEmpty,
           first.allSatisfy(\.isNumber),
           lines.dropFirst().contains(where: { isHeaderLine($0) }) {
            return SourceClassification(
                format: .emlx,
                evidence: "leading byte count then RFC 822 headers (Apple Mail .emlx layout)",
                extensionHint: ext,
                nameContentMismatch: ext != "emlx",
                warning: nil)
        }

        // mbox: at least one "From " separator at the start of a line.
        let separators = lines.filter { isMBOXSeparator($0) }.count
        if separators > 0 {
            // One separator plus headers could be either; more than one is
            // unambiguous. A single separator at line 0 is still an mbox
            // container holding one message.
            return SourceClassification(
                format: .mbox,
                evidence: separators == 1
                    ? "one \"From \" separator at the start of a line"
                    : "\(separators) \"From \" separators in the first \(data.count) bytes",
                extensionHint: ext,
                nameContentMismatch: !(ext == "mbox" || ext.isEmpty),
                warning: nil)
        }

        // eml: an RFC 822 header block with no mbox envelope.
        let headerCount = lines.prefix(40).filter { isHeaderLine($0) }.count
        if headerCount >= 2 {
            return SourceClassification(
                format: .eml,
                evidence: "\(headerCount) RFC 822 header lines and no mbox separator",
                extensionHint: ext,
                nameContentMismatch: !(ext == "eml" || ext.isEmpty),
                warning: nil)
        }

        return nil
    }

    private static func isHeaderLine(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":"), colon > line.startIndex else { return false }
        let name = line[line.startIndex..<colon]
        guard name.count <= 40,
              name.allSatisfy({ $0.isLetter || $0 == "-" || $0.isNumber }) else { return false }
        let known = ["from", "to", "cc", "bcc", "subject", "date", "message-id",
                     "received", "return-path", "mime-version", "content-type",
                     "delivered-to", "x-gmail-labels", "in-reply-to", "references",
                     "content-transfer-encoding", "reply-to", "sender"]
        return known.contains(name.lowercased())
    }

    /// An mbox separator: `From ` followed by an address-ish token and a year.
    private static func isMBOXSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("From "), line.count > 5 else { return false }
        return line.range(of: #"\d{4}"#, options: .regularExpression) != nil
    }

    // MARK: - Directories

    private static func classifyDirectory(url: URL, ext: String) -> SourceClassification? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])

        // Mail's own library (V10, an account, or one of its mailboxes): the
        // messages are .emlx files a few folders down, there is no `mbox` file.
        // Classified as a package before 2026-10-14, it imported nothing.
        if !names.contains("mbox"), !names.contains(where: { $0.lowercased().hasSuffix(".emlx") }),
           !emlxDirectories(under: url, limit: 1).isEmpty {
            return SourceClassification(
                format: .appleMailLibrary,
                evidence: "folder with .emlx messages below it (Apple Mail's own layout)",
                extensionHint: ext, nameContentMismatch: false, warning: nil)
        }

        // Apple Mail exports a .mbox *package* containing `mbox` and/or `Data/`.
        if ext == "mbox" || names.contains("mbox") || names.contains("Info.plist") {
            return SourceClassification(
                format: .appleMailMailbox,
                evidence: names.contains("mbox")
                    ? "directory containing an `mbox` file (Apple Mail mailbox package)"
                    : "Apple Mail mailbox package layout",
                extensionHint: ext,
                nameContentMismatch: false,
                warning: names.contains("mbox") ? nil : "No `mbox` file was found inside the package; there may be nothing to import.")
        }

        if names.contains("cur"), names.contains("new"), names.contains("tmp") {
            return SourceClassification(
                format: .maildir,
                evidence: "directory containing cur/new/tmp (Maildir layout)",
                extensionHint: ext, nameContentMismatch: false, warning: nil)
        }

        // Plain folders of individual messages — what a Mail "Save As" or an
        // unpacked export usually produces. Routing these as "unknown" made
        // mailin reject message sets it can read file by file.
        let emlxCount = names.filter { $0.lowercased().hasSuffix(".emlx") }.count
        if emlxCount > 0 {
            // EMLXParser reads a directory of .emlx natively, so this is NOT
            // a directory form for expansion purposes.
            return SourceClassification(
                format: .emlx,
                evidence: "directory containing \(emlxCount) .emlx message file\(emlxCount == 1 ? "" : "s")",
                extensionHint: ext, nameContentMismatch: false, warning: nil)
        }

        // Directive 2026-11-07 §6: the .eml files may sit in sub-folders (an export
        // of a folder tree); those folders are the mailboxes, so the whole tree counts.
        let emlDirect = names.filter { $0.lowercased().hasSuffix(".eml") }.count
        let emlCount = emlDirect > 0 ? emlDirect : emlFiles(under: url).count
        if emlCount > 0 {
            return SourceClassification(
                format: .emlFolder,
                evidence: emlDirect > 0
                    ? "directory containing \(emlCount) .eml message file\(emlCount == 1 ? "" : "s")"
                    : "directory with \(emlCount) .eml message file\(emlCount == 1 ? "" : "s") in its sub-folders",
                extensionHint: ext, nameContentMismatch: false, warning: nil)
        }

        return SourceClassification(
            format: .unknown,
            evidence: "a folder that is not an Apple Mail package or a Maildir",
            extensionHint: ext, nameContentMismatch: false,
            warning: "Select the mailbox files inside it, or the folder itself if it is an exported mailbox.")
    }

    // MARK: - Directory expansion

    /// Directory formats do not hold their messages in the directory itself —
    /// they hold them in files inside it. Returns the files that must actually
    /// be parsed, in a stable order.
    ///
    /// Without this, `.appleMailMailbox` and `.maildir` classified as
    /// *supported* and were then handed to the MBOX parser as a directory
    /// path, which cannot be opened as a byte stream: the import failed with
    /// an I/O error instead of reading the mailbox. Any other format returns
    /// itself, so callers can treat every source uniformly.
    static func expand(_ url: URL, format: SourceFormat) -> [URL] {
        expandDirectory(url, format: format).members
    }

    /// What a directory source expands to: the files to parse, the files the
    /// layout says are not messages (Maildir `tmp/`, counted as skipped), and
    /// every mailbox the layout declares — empty ones too (FOLD-02).
    struct DirectoryExpansion {
        var members: [URL] = []
        var skipped: [URL] = []
        var declaredFolders: [String] = []
    }

    /// Directive 2026-11-07 §6: Maildir++ and nested .eml folders keep their
    /// folders. A Maildir root is the inbox (`cur/`, `new/`); every directory
    /// below it that holds `cur/` or `new/` is a mailbox — Maildir++ names them
    /// with leading dots (`.Sent`, `.Archive.2024` → `Sent`, `Archive/2024`),
    /// Dovecot's fs layout nests them as plain directories (`Archive/2024/cur`).
    /// `cur`, `new` and `tmp` are never folder names; `tmp/` holds deliveries in
    /// progress and is skipped and counted. A folder of .eml files is walked
    /// whole; each file's directory, relative to the root, is its folder.
    static func expandDirectory(_ url: URL, format: SourceFormat) -> DirectoryExpansion {
        let fm = FileManager.default
        switch format {
        case .maildir:
            var out = DirectoryExpansion()
            func files(in directory: URL) -> [URL] {
                ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            }
            func isMailbox(_ directory: URL) -> Bool {
                fm.fileExists(atPath: directory.appendingPathComponent("cur").path) || fm.fileExists(atPath: directory.appendingPathComponent("new").path)
            }
            var visited = Set<String>()   // against symlink loops; not a limit on the tree
            func visit(_ directory: URL, mailbox: Bool) {
                guard visited.insert(directory.standardizedFileURL.resolvingSymlinksInPath().path).inserted else { return }
                if mailbox {
                    if let folder = maildirMailboxPath(directory, root: url) { out.declaredFolders.append(folder) }
                    for sub in ["cur", "new"] { out.members += files(in: directory.appendingPathComponent(sub, isDirectory: true)) }
                    out.skipped += files(in: directory.appendingPathComponent("tmp", isDirectory: true))
                }
                // Sub-mailboxes (dot-named or plain directories holding cur/ or new/) and the plain
                // directories on the way to them (Dovecot fs layout: Lists/Swift/cur).
                let children = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? [])
                    .filter { child in
                        let name = child.lastPathComponent
                        guard name != ".", name != "..", !(mailbox && maildirInternalNames.contains(name)) else { return false }
                        return (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children { visit(child, mailbox: isMailbox(child)) }
            }
            visit(url, mailbox: true)
            out.members.sort { $0.path < $1.path }
            out.skipped.sort { $0.path < $1.path }
            out.declaredFolders = Array(Set(out.declaredFolders)).sorted()
            return out

        case .emlFolder:
            var out = DirectoryExpansion()
            out.members = emlFiles(under: url)
            out.declaredFolders = Array(Set(out.members.compactMap { folderPath(member: $0, root: url, format: .emlFolder) })).sorted()
            return out

        default:
            return DirectoryExpansion(members: expandLegacy(url, format: format))
        }
    }

    /// The three directories of a Maildir mailbox; never folder names.
    static let maildirInternalNames: Set<String> = ["cur", "new", "tmp"]

    /// A Maildir mailbox directory's folder path: the root is the folder's own name;
    /// below it, Maildir++ dot names decode to a path (".Archive.2024" → "Archive/2024")
    /// and plain nested directories are the path as they are ("Archive/2024").
    static func maildirMailboxPath(_ mailbox: URL, root: URL) -> String? {
        let rootName = root.lastPathComponent
        guard let components = relativeComponents(of: mailbox, below: root), !components.isEmpty else {
            return rootName.isEmpty ? nil : rootName
        }
        let parts = components.flatMap { name -> [String] in
            name.hasPrefix(".") ? name.split(separator: ".", omittingEmptySubsequences: true).map(String.init) : [name]
        }.filter { !$0.isEmpty && !maildirInternalNames.contains($0) }
        return parts.isEmpty ? (rootName.isEmpty ? nil : rootName) : parts.joined(separator: "/")
    }

    /// Every .eml file under `url`, sub-folders included, hidden entries skipped, sorted by path.
    static func emlFiles(under url: URL) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let child as URL in walker where child.pathExtension.lowercased() == "eml" {
            guard (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            found.append(child)
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The directory walk of a mailbox member: its path components below `root`.
    private static func relativeComponents(of url: URL, below root: URL) -> [String]? {
        let member = url.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents
        guard member.count >= base.count, Array(member.prefix(base.count)) == base else { return nil }
        return Array(member.dropFirst(base.count))
    }

    private static func expandLegacy(_ url: URL, format: SourceFormat) -> [URL] {
        let fm = FileManager.default
        switch format {
        case .appleMailMailbox:
            // Apple Mail keeps the mbox at the package root in some exports
            // and under `Data/…/Messages` in others. Take the root one when
            // it exists, otherwise every `mbox` file in the package.
            let root = url.appendingPathComponent("mbox")
            if fm.fileExists(atPath: root.path) { return [root] }
            guard let walker = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
            var found: [URL] = []
            for case let child as URL in walker where child.lastPathComponent == "mbox" {
                found.append(child)
            }
            return found.sorted { $0.path < $1.path }

        case .appleMailLibrary:
            return emlxDirectories(under: url, limit: .max)

        default:
            return [url]
        }
    }

    /// FOLD-02: the mailbox a member file belongs to, as a "/"-separated
    /// path, for the formats whose directory layout IS the folder structure.
    /// Apple Mail: the chain of `.mbox` packages ("Work.mbox/Clients.mbox" →
    /// "Work/Clients"). Maildir: the root mailbox is the folder's own name;
    /// a sub-mailbox is its Maildir++ name decoded (".Archive.2024" →
    /// "Archive/2024") or its directory path below the root ("Archive/2024/cur"
    /// → "Archive/2024"); `cur`, `new`, `tmp` never appear. EML folders: files
    /// in the root carry the folder's own name, files below it the directory
    /// path relative to the root. Nil for everything else.
    static func folderPath(member: URL, root: URL, format: SourceFormat) -> String? {
        switch format {
        case .appleMailMailbox, .appleMailLibrary:
            let names = member.standardizedFileURL.pathComponents
                .filter { $0.lowercased().hasSuffix(".mbox") }
                .map { String($0.dropLast(5)) }
                .filter { !$0.isEmpty }
            return names.isEmpty ? nil : names.joined(separator: "/")
        case .maildir:
            // member = <mailbox>/cur|new|tmp/<file>: the mailbox is two levels up.
            return maildirMailboxPath(member.deletingLastPathComponent().deletingLastPathComponent(), root: root)
        case .emlFolder:
            let rootName = root.lastPathComponent
            guard let components = relativeComponents(of: member.deletingLastPathComponent(), below: root), !components.isEmpty else {
                return rootName.isEmpty ? nil : rootName
            }
            return components.joined(separator: "/")
        default:
            return nil
        }
    }

    /// True when `format` needs `expand(_:format:)` before a parser can run.
    static func isDirectoryForm(_ format: SourceFormat) -> Bool {
        format == .appleMailMailbox || format == .maildir || format == .emlFolder || format == .appleMailLibrary
    }

    /// Folders under `url` that hold .emlx files (Mail's `…/Data/…/Messages`),
    /// sorted, hidden folders skipped; stops after `limit` folders.
    static func emlxDirectories(under url: URL, limit: Int) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        var dirs = Set<URL>()
        for case let child as URL in walker where child.pathExtension.lowercased() == "emlx" {
            dirs.insert(child.deletingLastPathComponent().standardizedFileURL)
            if dirs.count >= limit { break }
        }
        return dirs.sorted { $0.path < $1.path }
    }

    // MARK: - I/O

    private static func readProbe(url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: probeBytes)
    }
}
