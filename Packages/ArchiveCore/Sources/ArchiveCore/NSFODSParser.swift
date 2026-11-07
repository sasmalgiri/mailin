//
//  NSFODSParser.swift
//  ArchiveCore
//
//  GAP-NSF: mail notes read by `NSFODSReader` become `MBOXParser.RawEmail`
//  rows — the same model the old `NSFParser` returns, so the import path can
//  take either (dispatch seam in `EmailParserProtocol`, switch
//  `NotesODSPolicy.isEnabled`). Each message is rebuilt as RFC 5322 text and
//  parsed by `MBOXParser.processRawMessage`, so headers, bodies, MIME
//  attachments and the kept raw source come out exactly as for an .eml.
//

import Foundation
import os

enum NSFODSParser {
    private static let logger = Logger(subsystem: "com.mailin", category: "NSFODSParser")

    struct Result {
        var emails: [MBOXParser.RawEmail]
        var inventory: NSFODSReader.Inventory
    }

    static func parse(fileURL: URL, senderEmail: String, onProgress: ((Double) -> Void)? = nil) throws -> [MBOXParser.RawEmail] {
        try read(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress).emails
    }

    /// Every mail note as a message plus the inventory of everything else.
    static func read(fileURL: URL, senderEmail: String, onProgress: ((Double) -> Void)? = nil) throws -> Result {
        var emails: [MBOXParser.RawEmail] = []
        let inventory = try walk(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress) { emails.append($0) }
        return Result(emails: emails, inventory: inventory)
    }

    /// OPEN-02: one note at a time from the mapped file, handed out in batches.
    /// Returns how many messages were handed out.
    static func parseStreaming(
        fileURL: URL,
        senderEmail: String,
        batchSize: Int,
        onProgress: ((Double) -> Void)? = nil,
        onBatch: ([MBOXParser.RawEmail]) async throws -> Void
    ) async throws -> Int {
        try await parseStreamingWithInventory(fileURL: fileURL, senderEmail: senderEmail, batchSize: batchSize,
                                              onProgress: onProgress, onBatch: onBatch).emitted
    }

    struct Streamed {
        let emitted: Int
        let inventory: NSFODSReader.Inventory
    }

    static func parseStreamingWithInventory(
        fileURL: URL,
        senderEmail: String,
        batchSize: Int,
        onProgress: ((Double) -> Void)? = nil,
        onBatch: ([MBOXParser.RawEmail]) async throws -> Void
    ) async throws -> Streamed {
        let size = max(1, batchSize)
        let data = try mapped(fileURL)
        let reader = try NSFODSReader(data: data)
        var inventory = NSFODSReader.Inventory()
        var cursor = NSFODSReader.Cursor()
        var batch: [MBOXParser.RawEmail] = []
        batch.reserveCapacity(size)
        var emitted = 0
        while let record = reader.next(&cursor) {
            try Task.checkCancellation()
            if let email = account(record, reader: reader, senderEmail: senderEmail, inventory: &inventory) {
                batch.append(email)
                if batch.count >= size {
                    try await onBatch(batch)
                    emitted += batch.count
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if cursor.index % 64 == 0 { onProgress?(Double(cursor.index) / Double(max(reader.entryCount, 1))) }
        }
        if !batch.isEmpty {
            try await onBatch(batch)
            emitted += batch.count
        }
        onProgress?(1)
        logger.info("NSF ODS: streamed \(emitted) of \(inventory.mailNotes) mail notes")
        return Streamed(emitted: emitted, inventory: inventory)
    }

    /// The import report: every mail note is a message; the ones that could
    /// not be rebuilt, and documents whose items could not be placed (they
    /// may be mail), are failures with a category.
    static func report(_ streamed: Streamed) -> MBOXParser.ParseRecoveryReport {
        let inv = streamed.inventory
        var categories: [String: Int] = [:]
        if !inv.mailFailed.isEmpty { categories["nsf_mail_note_unreadable"] = inv.mailFailed.count }
        if !inv.unplacedDocuments.isEmpty { categories["nsf_document_items_unplaced"] = inv.unplacedDocuments.count }
        let failed = inv.mailFailed.count + inv.unplacedDocuments.count
        return MBOXParser.ParseRecoveryReport(
            totalMessages: streamed.emitted + failed, successfullyParsed: streamed.emitted,
            failed: failed, errorCategories: categories)
    }

    /// The inventory alone (still builds each message, to count failures honestly).
    static func inventory(fileURL: URL) throws -> NSFODSReader.Inventory {
        try walk(fileURL: fileURL, senderEmail: "", onProgress: nil) { _ in }
    }

    private static func walk(fileURL: URL, senderEmail: String, onProgress: ((Double) -> Void)?,
                             emit: (MBOXParser.RawEmail) -> Void) throws -> NSFODSReader.Inventory {
        let data = try mapped(fileURL)
        let reader = try NSFODSReader(data: data)
        var inventory = NSFODSReader.Inventory()
        var cursor = NSFODSReader.Cursor()
        while let record = reader.next(&cursor) {
            if let email = account(record, reader: reader, senderEmail: senderEmail, inventory: &inventory) { emit(email) }
            if cursor.index % 64 == 0 { onProgress?(Double(cursor.index) / Double(max(reader.entryCount, 1))) }
        }
        onProgress?(1)
        logger.info("NSF ODS: \(inventory.mailRead) of \(inventory.mailNotes) mail notes read; \(inventory.designNotes) design, \(inventory.deletionStubs) stubs, \(inventory.otherDocuments) other documents")
        return inventory
    }

    private static func mapped(_ fileURL: URL) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attrs[.size] as? Int64 ?? 0
        if case .refuse(let reason) = SourceSizePolicy.nsfVerdict(fileSize: fileSize) {
            throw NSFParser.NSFError.invalidFormat(reason)
        }
        return try Data(contentsOf: fileURL, options: .mappedIfSafe)
    }

    // MARK: - One record

    private static func account(_ record: NSFODSReader.Record, reader: NSFODSReader, senderEmail: String,
                                inventory: inout NSFODSReader.Inventory) -> MBOXParser.RawEmail? {
        inventory.odsVersion = reader.odsVersion
        inventory.rrvBuckets = reader.rrvBucketCount
        switch record {
        case .object:
            inventory.rrvEntries += 1; inventory.objects += 1
        case .unresolved(let id):
            inventory.rrvEntries += 1; inventory.unresolvedEntries.append(id)
        case .deletionStub:
            inventory.rrvEntries += 1; inventory.noteRecords += 1; inventory.deletionStubs += 1
        case .design(_, let cls):
            inventory.rrvEntries += 1; inventory.noteRecords += 1; inventory.designNotesByClass[cls, default: 0] += 1
        case .empty:
            inventory.rrvEntries += 1; inventory.noteRecords += 1; inventory.emptyDocuments += 1
        case .unplaced(let id):
            inventory.rrvEntries += 1; inventory.noteRecords += 1; inventory.unplacedDocuments.append(id)
        case .note(let note):
            inventory.rrvEntries += 1; inventory.noteRecords += 1
            guard isMail(note) else {
                let form = note.first("Form").map(NotesValue.string) ?? ""
                inventory.otherDocumentsByForm[form, default: 0] += 1
                return nil
            }
            inventory.mailNotes += 1
            do {
                let email = try message(note, reader: reader, senderEmail: senderEmail, inventory: &inventory)
                inventory.mailRead += 1
                return email
            } catch {
                inventory.mailFailed[note.id] = error.localizedDescription
            }
        }
        return nil
    }

    static let mailForms: Set<String> = ["memo", "reply", "reply with history", "forward"]

    /// A document is mail when its Form is a mail form, or when it has no
    /// Form (mail delivered by SMTP/POP often carries none) and has a sender
    /// or recipients. Profiles and other documents are counted, not read.
    static func isMail(_ note: NSFODSReader.Note) -> Bool {
        if let form = note.first("Form").map(NotesValue.string)?.trimmingCharacters(in: .whitespaces), !form.isEmpty {
            return mailForms.contains(form.lowercased())
        }
        return note.first("From") != nil || note.first("SendTo") != nil
    }

    // MARK: - Rebuilding the message

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private struct FileRef { let name: String; let bytes: Data?; let reason: String? }

    private static func files(_ note: NSFODSReader.Note, reader: NSFODSReader, inventory: inout NSFODSReader.Inventory,
                              notes: inout [String]) -> [FileRef] {
        note.all("$FILE").compactMap { item -> FileRef? in
            let v = item.value
            guard item.type == 0x0003, v.count >= 36 else {
                inventory.attachmentObjectsNotDecoded += 1
                notes.append("NSF ODS: a $FILE item of \(v.count) bytes is not a file object and was not read")
                return nil
            }
            let rrvID = NSFODSReader.u32(v, 2)
            let nameLength = Int(NSFODSReader.u16(v, 6))
            let compression = NSFODSReader.u16(v, 10)
            let size = Int(NSFODSReader.u32(v, 16))
            // The name runs to the end of the value; a damaged length word
            // (seen once on the public sample: 0x0108 for "mime.htm") does
            // not lose the file — the stored bytes are the name.
            let name = LMBCS.decode(v.subdata(in: 36..<min(v.count, 36 + nameLength)))
            if 36 + nameLength != v.count {
                notes.append("NSF ODS: file object \(name) declares a \(nameLength)-byte name in a \(v.count - 36)-byte field; the stored bytes were used")
            }
            guard compression == 0 else {
                inventory.attachmentObjectsNotDecoded += 1
                return FileRef(name: name, bytes: nil, reason: compression == 1 ? "Huffman-compressed" : "LZ1-compressed")
            }
            guard let off = reader.object(rrvID: rrvID), NSFODSReader.u16(reader.data, off) == 0x0007,
                  Int(NSFODSReader.u32(reader.data, off + 2)) == 22 + size, off + 22 + size <= reader.data.count else {
                inventory.attachmentObjectsNotDecoded += 1
                return FileRef(name: name, bytes: nil, reason: "object not stored as one record")
            }
            inventory.attachmentObjectsDecoded += 1
            return FileRef(name: name, bytes: reader.data.subdata(in: (off + 22)..<(off + 22 + size)), reason: nil)
        }
    }

    private static func message(_ note: NSFODSReader.Note, reader: NSFODSReader, senderEmail: String,
                                inventory: inout NSFODSReader.Inventory) throws -> MBOXParser.RawEmail {
        var notes: [String] = []
        let attachments = files(note, reader: reader, inventory: &inventory, notes: &notes)
        let raw: Data
        let parts = note.items.filter { $0.type == 0x0019 }
        if !parts.isEmpty {
            inventory.nativeMIMEMail += 1
            raw = try nativeMIME(note, parts: parts, files: attachments, notes: &notes)
        } else {
            inventory.richTextMail += 1
            raw = richTextMessage(note, files: attachments, notes: &notes)
        }
        let text = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) ?? String(decoding: raw, as: UTF8.self)
        var email = try MBOXParser.processRawMessage(text, senderEmail: senderEmail)
        email.headers["X-Source-Format"] = "NSF"
        email.headers["X-Notes-NoteID"] = String(format: "0x%X", note.id)
        if let form = note.first("Form").map(NotesValue.string), !form.isEmpty { email.headers["X-Notes-Form"] = form }
        if email.headers["Date"] == nil, let posted = (note.first("PostedDate") ?? note.first("DeliveredDate")).flatMap(NotesValue.dateValue) {
            email.timestamp = ISO8601DateFormatter().string(from: posted)
        }
        email.anomalies.append(contentsOf: notes)
        return email
    }

    /// RFC822_TEXT lines in item order, then the MIME parts in item order.
    private static func nativeMIME(_ note: NSFODSReader.Note, parts: [NSFODSReader.Item], files: [FileRef],
                                   notes: inout [String]) throws -> Data {
        var out = Data()
        for item in note.items where item.type == 0x0502 {
            var line: Data
            if let parsed = NotesValue.rfc822(item.value) {
                line = parsed.line
            } else if let rest = NotesValue.rfc822HeaderLine(item.value) {
                // The length words are damaged but the stored bytes after the
                // native value still read as one header line: keep it, say so.
                line = rest
                notes.append("NSF ODS: header item \(item.name) has inconsistent lengths; its stored header line was used")
            } else {
                notes.append("NSF ODS: header item \(item.name) (\(item.value.count) bytes) could not be read and is missing from the message")
                continue
            }
            guard !line.isEmpty else { continue }
            out.append(line)
            if !line.ends(with: [0x0D, 0x0A]) { out.append(contentsOf: [0x0D, 0x0A]) }
        }
        var referenced = Set<String>()
        for part in parts {
            let v = part.value
            guard v.count >= 20, NSFODSReader.u16(v, 0) == 0x0002 else {
                notes.append("NSF ODS: a MIME part of \(part.value.count) bytes is not in the MIME_PART layout and was left out")
                continue
            }
            let flags = NSFODSReader.u32(v, 2)
            let count = Int(NSFODSReader.u16(v, 8)), boundary = Int(NSFODSReader.u16(v, 10)), headers = Int(NSFODSReader.u16(v, 12))
            guard 20 + count <= v.count, boundary + headers <= count else {
                throw Failure("MIME part lengths exceed the stored value")
            }
            let content = v.subdata(in: 20..<(20 + count))
            let bound = content.subdata(in: 0..<boundary)
            var head = content.subdata(in: boundary..<(boundary + headers))
            var body = content.subdata(in: (boundary + headers)..<content.count)
            if flags & 0x0004 != 0 {                       // MIME_PART_BODY_IN_DBOBJECT
                let name = LMBCS.decode(body).trimmingCharacters(in: .whitespacesAndNewlines)
                referenced.insert(name)
                if let file = files.first(where: { $0.name == name }), let bytes = file.bytes {
                    body = bytes
                } else {
                    let why = files.first(where: { $0.name == name })?.reason ?? "no $FILE item of that name"
                    notes.append("NSF ODS: MIME part body \(name) not read (\(why))")
                    body = Data()
                }
            }
            if body.contains(where: { $0 >= 0x80 || $0 == 0 }) {
                head = base64Headers(head)
                body = Data(body.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]).utf8)
                body.append(contentsOf: [0x0D, 0x0A])
            }
            out.append(bound); out.append(head); out.append(body)
        }
        for file in files where !referenced.contains(file.name) {
            notes.append("NSF ODS: attachment \(file.name) is not part of the MIME structure and was not added")
        }
        return out
    }

    /// The part's headers with Content-Transfer-Encoding set to base64.
    private static func base64Headers(_ head: Data) -> Data {
        let text = String(decoding: head, as: UTF8.self)
        var lines: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\r\n") {
            if skipping, line.first == " " || line.first == "\t" { continue }
            skipping = line.lowercased().hasPrefix("content-transfer-encoding:")
            if !skipping { lines.append(line) }
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        lines.append("Content-Transfer-Encoding: base64")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// A Notes rich-text memo: header fields from the items, CD text as the body.
    private static func richTextMessage(_ note: NSFODSReader.Note, files: [FileRef], notes: inout [String]) -> Data {
        func field(_ names: String...) -> String? {
            for name in names {
                if let item = note.first(name) {
                    let s = NotesValue.string(item).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { return s }
                }
            }
            return nil
        }
        func header(_ name: String, _ value: String) -> String {
            let clean = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            if clean.unicodeScalars.allSatisfy({ $0.isASCII }) { return "\(name): \(clean)\r\n" }
            return "\(name): =?UTF-8?B?\(Data(clean.utf8).base64EncodedString())?=\r\n"
        }
        var head = ""
        head += header("From", field("From", "$From", "SMTPOriginator") ?? "")
        if let to = field("SendTo", "EnterSendTo") { head += header("To", to) }
        if let cc = field("CopyTo", "EnterCopyTo") { head += header("Cc", cc) }
        if let bcc = field("BlindCopyTo") { head += header("Bcc", bcc) }
        head += header("Subject", field("Subject") ?? "")
        if let date = (note.first("PostedDate") ?? note.first("DeliveredDate")).flatMap(NotesValue.dateValue) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
            head += "Date: \(f.string(from: date))\r\n"
        }
        if let id = field("$MessageID") { head += header("Message-ID", id) }
        head += "MIME-Version: 1.0\r\n"

        var text = ""
        let bodies = note.all("Body")
        for body in bodies {
            switch body.type {
            case 0x0001: text += NotesRichText.plainText(body.value)
            case 0x0500, 0x0501: text += NotesValue.string(body)
            default: notes.append("NSF ODS: Body item of type 0x\(String(body.type, radix: 16)) not converted")
            }
        }
        if bodies.contains(where: { $0.type == 0x0001 }) {
            notes.append("NSF ODS: rich-text body read as plain text (formatting, tables, links and embedded images not kept)")
        }
        let encodedText = Data(text.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let readable = files.filter { $0.bytes != nil }
        for file in files where file.bytes == nil {
            notes.append("NSF ODS: attachment \(file.name) not read (\(file.reason ?? "unknown layout"))")
        }
        guard !readable.isEmpty else {
            head += "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            return Data((head + encodedText + "\r\n").utf8)
        }
        let boundary = "=_mailin_nsf_\(String(format: "%08X", note.id))"
        var out = head + "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
        out += "--\(boundary)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(encodedText)\r\n"
        for file in readable {
            let name = file.name.replacingOccurrences(of: "\"", with: "'")
            out += "--\(boundary)\r\nContent-Type: application/octet-stream; name=\"\(name)\"\r\n"
            out += "Content-Disposition: attachment; filename=\"\(name)\"\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            out += file.bytes!.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            out += "\r\n"
        }
        out += "--\(boundary)--\r\n"
        return Data(out.utf8)
    }
}

private extension Data {
    func ends(with suffix: [UInt8]) -> Bool {
        count >= suffix.count && Array(self.suffix(suffix.count)) == suffix
    }
}
