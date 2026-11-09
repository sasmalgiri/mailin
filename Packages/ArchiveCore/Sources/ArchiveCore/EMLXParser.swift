import Foundation

// §3-P2 (strict memory safety): the byte-level scanning in this file reads raw
// buffers (`withUTF8`, `withUnsafeBytes`) for speed on large archives. Every
// such read is marked `unsafe`. SAFETY: each buffer is used only inside its
// closure, and every index is checked against the buffer's count before it is read.

struct EMLXParser {
    /// Bump when message extraction/ordering changes — invalidates mid-file
    /// resume checkpoints bound to the previous version (Part B5).
    static let parserVersion = 1

    struct ParseResult {
        let emails: [MBOXParser.RawEmail]
        let totalFiles: Int
        let failedFiles: Int
        let errors: [(filename: String, reason: String)]

        var summary: String? {
            guard failedFiles > 0 else { return nil }
            return "Recovered \(emails.count) of \(totalFiles) EMLX files (\(failedFiles) damaged)"
        }
    }

    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [MBOXParser.RawEmail] {
        let result = try parseWithReport(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        return result.emails
    }

    static func parseWithReport(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> ParseResult {
        let ext = fileURL.pathExtension.lowercased()

        if ext == "emlx" {
            let email = try parseSingleEMLX(fileURL: fileURL, senderEmail: senderEmail)
            onProgress?(1.0)
            return ParseResult(emails: [email], totalFiles: 1, failedFiles: 0, errors: [])
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard unsafe fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw EMLXError.invalidFormat("Expected .emlx file or directory")
        }

        let contents = try fm.contentsOfDirectory(at: fileURL, includingPropertiesForKeys: nil)
        let emlxFiles = contents.filter { $0.pathExtension.lowercased() == "emlx" }
        guard !emlxFiles.isEmpty else {
            throw EMLXError.noEmailsFound
        }

        var emails: [MBOXParser.RawEmail] = []
        var errors: [(filename: String, reason: String)] = []
        let total = Double(emlxFiles.count)
        for (idx, file) in emlxFiles.enumerated() {
            do {
                let email = try parseSingleEMLX(fileURL: file, senderEmail: senderEmail)
                emails.append(email)
            } catch {
                errors.append((filename: file.lastPathComponent, reason: error.localizedDescription))
            }
            onProgress?((Double(idx + 1)) / total)
        }
        return ParseResult(emails: emails, totalFiles: emlxFiles.count, failedFiles: errors.count, errors: errors)
    }

    /// Where the parts of an .emlx file are: the byte-count line, the RFC 822
    /// message it counts, and Apple Mail's property list after it.
    struct Layout: Sendable, Equatable {
        var fileSize: Int64
        var message: ByteRange
        /// Absent when the message runs to the end of the file.
        var plist: ByteRange?
    }

    /// CLOSE-01: an .emlx file is no longer read whole into memory (the former
    /// 500,000,000-byte refusal is gone). Only its first line is read to find
    /// the message's byte range; the message and the property list are then
    /// read by range — in full for a message at or under the offset engine's
    /// full-parse ceiling, by a byte locator above it
    /// (`OffsetImportEngine.importLargeSingleMessage`). A byte count that runs
    /// past the end of the file keeps the rest of the file as the message.
    static func layout(of fileURL: URL) throws -> Layout {
        let source = try FileRandomAccessSource(url: fileURL)
        let fileSize = source.length
        guard fileSize > 0 else { throw EMLXError.invalidFormat("Empty file (0 bytes)") }
        let head = try source.read(at: 0, count: 256)
        guard let newline = head.firstIndex(of: 0x0A) else {
            if fileSize <= Int64(head.count) {
                throw EMLXError.invalidFormat("File too short — expected byte count + RFC822 message")
            }
            let line = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw EMLXError.invalidFormat("Invalid byte count line: \(line.prefix(20))")
        }
        let line = String(decoding: head[head.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let byteCount = Int64(line), byteCount > 0 else {
            throw EMLXError.invalidFormat("Invalid byte count line: \(line.prefix(20))")
        }
        let start = Int64(head.distance(from: head.startIndex, to: newline)) + 1
        let available = fileSize - start
        guard available > 0 else { throw EMLXError.invalidFormat("No message content after byte count line") }
        let length = min(byteCount, available)
        let plist = start + length < fileSize ? ByteRange(offset: start + length, length: fileSize - start - length) : nil
        return Layout(fileSize: fileSize, message: ByteRange(offset: start, length: length), plist: plist)
    }

    /// Apple Mail's property list for the message, or empty when there is none
    /// or it does not parse. The tail is read only when it opens like a
    /// property list, so a wrong byte count cannot pull the rest of a large
    /// file into memory as a "plist".
    static func plist(of fileURL: URL, layout: Layout) -> [String: Any] {
        guard let range = layout.plist, let source = try? FileRandomAccessSource(url: fileURL),
              let peek = try? source.read(at: range.offset, count: 64) else { return [:] }
        let opening = String(decoding: peek, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard opening.hasPrefix("<?xml") || opening.hasPrefix("<plist") || opening.hasPrefix("<!DOCTYPE") || opening.hasPrefix("bplist"),
              let data = try? source.read(at: range.offset, count: Int(clamping: range.length)),
              let plist = unsafe try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return [:]
        }
        return plist
    }

    private static func parseSingleEMLX(fileURL: URL, senderEmail: String) throws -> MBOXParser.RawEmail {
        let layout = try layout(of: fileURL)
        let data = try FileRandomAccessSource(url: fileURL).read(at: layout.message.offset, count: Int(clamping: layout.message.length))
        guard data.contains(where: { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D) }) else {
            throw EMLXError.invalidFormat("No message content after byte count line")
        }
        let rfc822Message = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        var email = try MBOXParser.processRawMessage(rfc822Message, senderEmail: senderEmail)
        applyMetadata(plist: plist(of: fileURL, layout: layout), fileURL: fileURL, to: &email)
        return email
    }

    /// Flags, the mailbox chain from the path, and the recovery state — the
    /// same for a message read whole and one imported by its byte range.
    static func applyMetadata(plist plistFlags: [String: Any], fileURL: URL, to email: inout MBOXParser.RawEmail) {
        if let flags = plistFlags["flags"] as? Int {
            var set: [String] = []
            if flags & 0x01 != 0 { set.append("Read") }
            if flags & 0x02 != 0 { set.append("Deleted") }
            if flags & 0x04 != 0 { set.append("Answered") }
            if flags & 0x10 != 0 { set.append("Flagged") }
            if flags & 0x80 != 0 { set.append("Draft") }
            email.tags.append(contentsOf: set)
            // FOLD-02: flags stay tags for compatibility but are never folders.
            email.flags = set
        }
        // FOLD-02: the mailbox chain from the path ("Inbox.mbox/Clients.mbox").
        email.folderPath = SourceFormatClassifier.folderPath(member: fileURL, root: fileURL, format: .appleMailLibrary)
        // 3.1 R4: deleted flag → a recovery state (the "Deleted" tag stays for 3.0 compatibility).
        if let r = RecoveryDetector.fromEMLX(flags: plistFlags["flags"] as? Int,
                                               mailboxPath: fileURL.pathComponents.last(where: { $0.hasSuffix(".mbox") }).map { String($0.dropLast(5)) }) {
            email.recovery = r
        }
    }

    static func scanMailDirectory(at path: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: path, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var emlxFiles: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension.lowercased() == "emlx" {
                emlxFiles.append(url)
            }
        }
        return emlxFiles
    }

    enum EMLXError: LocalizedError {
        case invalidFormat(String)
        case noEmailsFound

        var errorDescription: String? {
            switch self {
            case .invalidFormat(let reason): return "Invalid EMLX format: \(reason)"
            case .noEmailsFound: return "No EMLX emails found in directory"
            }
        }
    }
}
