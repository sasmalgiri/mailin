//
//  OLMParser.swift
//  mailin
//
//  TYPE-06 (owner directive 2026-11-06): Outlook for Mac archives (.olm).
//
//  An OLM file is a ZIP. Outlook for Mac writes one XML record per message
//  under `…/com.microsoft.__Messages/<folder>/…/message_NNNNN.xml`, with the
//  attachment bytes as separate members that each record points at
//  (`OPFAttachmentURL`). Contacts, calendar items, tasks and notes sit in
//  sibling trees (`com.microsoft.__Contacts`, `__Calendar`, …).
//
//  What mailin does with it:
//   • Every message record is rebuilt as an RFC 5322 message — the fields
//     Outlook kept (addresses, subject, times, Message-ID, reply chain,
//     bodies, attachments with their bytes) become ordinary headers and MIME
//     parts, and the message is then parsed by the same path a .eml takes.
//     The rebuilt form carries `X-Mailin-Reconstructed` and names the record
//     it came from, so nobody can mistake it for the bytes Outlook received.
//   • The folder path is the record's place in the archive tree; "On My
//     Computer" folders lose their `Local` root, account trees keep the
//     account's name.
//   • Read and flagged states become flags (never folders), like Apple Mail's.
//   • Non-mail objects are counted out, never imported, and the count is on
//     the receipt (`olm_contacts_not_imported`, …) — the same rule PSTs follow.
//   • Members stream one at a time through a scratch file; the archive is
//     never loaded whole. There is no message or attachment cap of mailin's
//     own; the ZIP reader's checks (size, CRC-32, free scratch space) apply.
//

import Foundation

struct OLMParser {

    /// Bumped when message extraction/ordering changes — invalidates mid-file
    /// resume checkpoints bound to the previous version.
    static let parserVersion = 1

    static let messagesMarker = "com.microsoft.__Messages"

    /// The sibling trees that are not mail, with the receipt category each
    /// one is counted under.
    static let nonMailTrees: [(marker: String, category: String)] = [
        ("com.microsoft.__Contacts", "olm_contacts_not_imported"),
        ("com.microsoft.__Calendar", "olm_calendar_not_imported"),
        ("com.microsoft.__Tasks", "olm_tasks_not_imported"),
        ("com.microsoft.__Notes", "olm_notes_not_imported"),
    ]

    /// True when a ZIP's member list is an Outlook for Mac archive.
    static func isOLM(members: [ZIPArchiveReader.Member]) -> Bool {
        members.contains { $0.name.contains(messagesMarker + "/") }
    }

    // MARK: - Array path

    static func parse(fileURL: URL, senderEmail: String,
                      onProgress: ((Double) -> Void)? = nil) throws -> [MBOXParser.RawEmail] {
        var all: [MBOXParser.RawEmail] = []
        _ = try walk(fileURL: fileURL, senderEmail: senderEmail, batchSize: .max, onProgress: onProgress) { batch in
            all += batch
        }
        return all
    }

    // MARK: - Streaming path

    struct Outcome {
        var total = 0
        var parsed = 0
        var failed = 0
        var categories: [String: Int] = [:]
        var declaredFolders: [String] = []
    }

    /// Reads every message record, in archive order, and hands them out in
    /// batches. `onBatch` may suspend (the store writes between batches).
    static func parseStreaming(fileURL: URL, senderEmail: String, batchSize: Int,
                               onProgress: ((Double) -> Void)? = nil,
                               onBatch: ([MBOXParser.RawEmail]) async throws -> Void) async throws -> Outcome {
        // The ZIP walk is synchronous; batches are collected and awaited
        // between members so the store's writes interleave with extraction.
        var pending: [MBOXParser.RawEmail] = []
        var outcome = Outcome()
        let plan = try self.plan(fileURL: fileURL)
        outcome.categories = plan.nonMailCounts
        outcome.declaredFolders = plan.folders
        let scratch = try ParserFactory.containerScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        for (index, record) in plan.records.enumerated() {
            try Task.checkCancellation()
            let emails = messages(for: record, plan: plan, fileURL: fileURL, scratch: scratch,
                                  senderEmail: senderEmail, outcome: &outcome)
            pending += emails
            while pending.count >= max(1, batchSize) {
                let batch = Array(pending.prefix(max(1, batchSize)))
                pending.removeFirst(batch.count)
                try await onBatch(batch)
            }
            onProgress?(Double(index + 1) / Double(max(1, plan.records.count)))
        }
        if !pending.isEmpty { try await onBatch(pending) }
        return outcome
    }

    /// The synchronous walk the array path uses.
    @discardableResult
    static func walk(fileURL: URL, senderEmail: String, batchSize: Int,
                     onProgress: ((Double) -> Void)?,
                     onBatch: ([MBOXParser.RawEmail]) throws -> Void) throws -> Outcome {
        var outcome = Outcome()
        let plan = try self.plan(fileURL: fileURL)
        outcome.categories = plan.nonMailCounts
        outcome.declaredFolders = plan.folders
        let scratch = try ParserFactory.containerScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var pending: [MBOXParser.RawEmail] = []
        for (index, record) in plan.records.enumerated() {
            pending += messages(for: record, plan: plan, fileURL: fileURL, scratch: scratch,
                                senderEmail: senderEmail, outcome: &outcome)
            if pending.count >= batchSize { try onBatch(pending); pending.removeAll() }
            onProgress?(Double(index + 1) / Double(max(1, plan.records.count)))
        }
        if !pending.isEmpty { try onBatch(pending) }
        return outcome
    }

    /// FOLD-02: the folders the archive lists, message records or not.
    static func declaredFolders(fileURL: URL) -> [String] {
        (try? plan(fileURL: fileURL).folders) ?? []
    }

    // MARK: - The archive's shape

    struct Plan {
        var records: [ZIPArchiveReader.Member]
        var byName: [String: ZIPArchiveReader.Member]
        var folders: [String]
        var nonMailCounts: [String: Int]
    }

    static func plan(fileURL: URL) throws -> Plan {
        let members = try ZIPArchiveReader.members(of: fileURL)
        var records: [ZIPArchiveReader.Member] = []
        var byName: [String: ZIPArchiveReader.Member] = [:]
        var folders = Set<String>()
        var nonMail: [String: Int] = [:]
        for member in members {
            byName[member.name] = member
            if member.isJunk { continue }
            if member.name.contains(messagesMarker + "/") {
                if let folder = folderPath(forMember: member.name) { folders.insert(folder) }
                if !member.isDirectory, member.name.lowercased().hasSuffix(".xml"),
                   (member.name as NSString).lastPathComponent.lowercased().hasPrefix("message") {
                    records.append(member)
                }
                continue
            }
            guard !member.isDirectory, member.name.lowercased().hasSuffix(".xml") else { continue }
            if let tree = nonMailTrees.first(where: { member.name.contains($0.marker) }) {
                nonMail[tree.category, default: 0] += 1
            } else if !member.name.contains("com.microsoft.__Attachments") {
                nonMail["olm_other_objects_not_imported", default: 0] += 1
            }
        }
        // Archive order is Outlook's writing order; keep it, but make it
        // stable across readers that list the directory differently.
        return Plan(records: records, byName: byName, folders: folders.sorted(), nonMailCounts: nonMail)
    }

    /// `Local/com.microsoft.__Messages/Inbox/Clients/com.microsoft.__Messages/message_0001.xml`
    /// → "Inbox/Clients"; `Accounts/Work/com.microsoft.__Messages/Sent/…` → "Work/Sent".
    static func folderPath(forMember name: String) -> String? {
        var parts = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let last = parts.last, !name.hasSuffix("/"), last.contains(".") { parts.removeLast() }
        parts.removeAll { $0 == messagesMarker }
        if parts.first == "Local" { parts.removeFirst() }
        if parts.first == "Accounts" { parts.removeFirst() }
        let path = parts.joined(separator: "/")
        return path.isEmpty ? nil : path
    }

    // MARK: - One record

    private static func messages(for record: ZIPArchiveReader.Member, plan: Plan, fileURL: URL, scratch: URL,
                                 senderEmail: String, outcome: inout Outcome) -> [MBOXParser.RawEmail] {
        let destination = scratch.appendingPathComponent(UUID().uuidString + ".xml")
        defer { try? FileManager.default.removeItem(at: destination) }
        let data: Data
        do {
            try ZIPArchiveReader.extract(record, from: fileURL, to: destination)
            data = try Data(contentsOf: destination)
        } catch {
            outcome.total += 1
            outcome.failed += 1
            outcome.categories["olm_record_unreadable", default: 0] += 1
            return []
        }
        let parsed = OLMRecordReader.read(data)
        guard !parsed.isEmpty else {
            outcome.total += 1
            outcome.failed += 1
            outcome.categories["olm_record_without_message", default: 0] += 1
            return []
        }
        let folder = folderPath(forMember: record.name)
        var out: [MBOXParser.RawEmail] = []
        for message in parsed {
            outcome.total += 1
            let attachments = attachmentPayloads(for: message, plan: plan, fileURL: fileURL, scratch: scratch, outcome: &outcome)
            let rfc822 = rebuild(message, attachments: attachments, record: record.name)
            do {
                var email = try MBOXParser.processRawMessage(rfc822, senderEmail: senderEmail)
                email.folderPath = folder
                var flags: [String] = []
                if message.isRead { flags.append("Read") }
                if message.isFlagged { flags.append("Flagged") }
                email.flags = flags
                email.tags.append(contentsOf: flags)
                if let category = message.category, !category.isEmpty { email.tags.append(category) }
                out.append(email)
                outcome.parsed += 1
            } catch {
                outcome.failed += 1
                outcome.categories["olm_record_damaged", default: 0] += 1
            }
        }
        return out
    }

    private static func attachmentPayloads(for message: OLMRecordReader.Message, plan: Plan, fileURL: URL,
                                           scratch: URL, outcome: inout Outcome) -> [(OLMRecordReader.Attachment, Data?)] {
        message.attachments.map { attachment in
            guard let member = member(for: attachment.url, in: plan) else {
                outcome.categories["olm_attachment_bytes_missing", default: 0] += 1
                return (attachment, nil)
            }
            let destination = scratch.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            do {
                try ZIPArchiveReader.extract(member, from: fileURL, to: destination)
                return (attachment, try Data(contentsOf: destination))
            } catch {
                outcome.categories["olm_attachment_bytes_missing", default: 0] += 1
                return (attachment, nil)
            }
        }
    }

    /// The member an `OPFAttachmentURL` names: exact, then with the usual
    /// `Local/` root, then by suffix (Outlook versions differ in the root).
    private static func member(for url: String, in plan: Plan) -> ZIPArchiveReader.Member? {
        guard !url.isEmpty else { return nil }
        let candidates = [url, "Local/" + url, url.hasPrefix("/") ? String(url.dropFirst()) : url]
        for candidate in candidates { if let hit = plan.byName[candidate] { return hit } }
        let suffix = "/" + url
        return plan.byName.values.first { $0.name.hasSuffix(suffix) && !$0.isDirectory }
    }

    // MARK: - Rebuilding the RFC 5322 form

    static func rebuild(_ message: OLMRecordReader.Message,
                        attachments: [(OLMRecordReader.Attachment, Data?)], record: String) -> String {
        var lines: [String] = []
        func header(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            lines.append("\(name): \(encodeHeader(value))")
        }
        header("From", message.from.isEmpty ? message.senderAddress : message.from)
        header("To", message.to)
        header("Cc", message.cc)
        header("Bcc", message.bcc)
        header("Reply-To", message.replyTo)
        header("Subject", message.subject)
        if let date = message.sentTime ?? message.receivedTime { lines.append("Date: \(rfc2822(date))") }
        header("Message-ID", angled(message.messageID))
        header("In-Reply-To", angled(message.inReplyTo))
        if !message.references.isEmpty {
            lines.append("References: " + message.references.map { angled($0) ?? $0 }.joined(separator: " "))
        }
        header("Thread-Topic", message.threadTopic)
        header("Thread-Index", message.threadIndex)
        if let priority = message.priority { header("X-Priority", priority) }
        lines.append("X-Mailin-Reconstructed: rebuilt from an Outlook for Mac (OLM) record, \(record)")
        lines.append("MIME-Version: 1.0")

        let boundary = "mailin-olm-" + UUID().uuidString.lowercased()
        let hasHTML = !message.htmlBody.isEmpty
        let hasPlain = !message.plainBody.isEmpty
        let present = attachments.filter { $0.1 != nil }
        let missing = attachments.filter { $0.1 == nil }
        if !missing.isEmpty {
            lines.append("X-Mailin-Attachments-Missing: " + missing.map { encodeHeader($0.0.name) }.joined(separator: ", "))
        }
        let multipart = !present.isEmpty || (hasHTML && hasPlain)

        func bodyPart(_ type: String, _ text: String) -> [String] {
            ["Content-Type: \(type); charset=utf-8", "Content-Transfer-Encoding: base64", "",
             wrap(Data(text.utf8).base64EncodedString())]
        }

        guard multipart else {
            lines += bodyPart(hasHTML ? "text/html" : "text/plain", hasHTML ? message.htmlBody : message.plainBody)
            return lines.joined(separator: "\n")
        }
        lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        lines.append("")
        lines.append("--\(boundary)")
        if hasHTML && hasPlain {
            let alt = boundary + "-alt"
            lines.append("Content-Type: multipart/alternative; boundary=\"\(alt)\"")
            lines.append("")
            lines.append("--\(alt)")
            lines += bodyPart("text/plain", message.plainBody)
            lines.append("--\(alt)")
            lines += bodyPart("text/html", message.htmlBody)
            lines.append("--\(alt)--")
        } else {
            lines += bodyPart(hasHTML ? "text/html" : "text/plain", hasHTML ? message.htmlBody : message.plainBody)
        }
        for (attachment, data) in present {
            guard let data else { continue }
            let name = sanitize(attachment.name)
            let type = attachment.contentType.isEmpty ? "application/octet-stream" : attachment.contentType
            lines.append("--\(boundary)")
            lines.append("Content-Type: \(type)")
            let inline = !attachment.contentID.isEmpty
            lines.append("Content-Disposition: \(inline ? "inline" : "attachment"); filename=\"\(encodeHeader(name))\"")
            if inline { lines.append("Content-ID: <\(attachment.contentID.trimmingCharacters(in: CharacterSet(charactersIn: "<>")))>") }
            lines.append("Content-Transfer-Encoding: base64")
            lines.append("")
            lines.append(wrap(data.base64EncodedString()))
        }
        lines.append("--\(boundary)--")
        return lines.joined(separator: "\n")
    }

    private static func angled(_ id: String?) -> String? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return id.hasPrefix("<") ? id : "<\(id)>"
    }

    /// RFC 2047 B-encoding for header values that are not ASCII.
    static func encodeHeader(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        guard clean.unicodeScalars.contains(where: { $0.value > 0x7E || $0.value < 0x20 }) else { return clean }
        // Address lists keep their angle-bracket addresses readable: encode
        // only the display names between them when the value looks like one.
        if clean.contains("<"), clean.contains(">") {
            return clean.split(separator: ",").map { piece -> String in
                let part = piece.trimmingCharacters(in: .whitespaces)
                guard let open = part.lastIndex(of: "<") else { return encodedWord(part) }
                let display = part[..<open].trimmingCharacters(in: .whitespaces)
                let address = part[open...]
                return display.isEmpty ? String(address) : encodedWord(display) + " " + address
            }.joined(separator: ", ")
        }
        return encodedWord(clean)
    }

    private static func encodedWord(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value > 0x7E || $0.value < 0x20 }) else { return text }
        return "=?UTF-8?B?" + Data(text.utf8).base64EncodedString() + "?="
    }

    private static func sanitize(_ filename: String) -> String {
        let cleaned = filename.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    private static func wrap(_ text: String, at width: Int = 76) -> String {
        guard text.count > width else { return text }
        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: width, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[index..<end]))
            index = end
        }
        return result.joined(separator: "\n")
    }

    private static func rfc2822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}

// MARK: - The XML record

/// Reads Outlook for Mac's message XML (`<emails><email>…</email></emails>`).
/// Element names are Outlook's `OPFMessageCopy…` properties; addresses are
/// `<emailAddress>` elements with name/address attributes; attachments are
/// `<messageAttachment>` elements whose attributes name the member that
/// holds the bytes.
struct OLMRecordReader {

    struct Attachment: Equatable {
        var name: String
        var contentType: String
        var contentID: String
        var url: String
        var declaredSize: Int
    }

    struct Message {
        var subject = ""
        var from = ""
        var senderAddress = ""
        var to = ""
        var cc = ""
        var bcc = ""
        var replyTo = ""
        var messageID: String?
        var inReplyTo: String?
        var references: [String] = []
        var threadTopic: String?
        var threadIndex: String?
        var priority: String?
        var sentTime: Date?
        var receivedTime: Date?
        var plainBody = ""
        var htmlBody = ""
        var isRead = false
        var isFlagged = false
        var category: String?
        var attachments: [Attachment] = []
    }

    static func read(_ data: Data) -> [Message] {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.messages
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var messages: [Message] = []
        private var current: Message?
        private var text = ""
        private var listElement: String?
        private var addresses: [String] = []
        private var elementDepthInsideEmail = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if name == "email" { current = Message(); return }
            guard current != nil else { return }
            text = ""
            switch name {
            case "OPFMessageCopyFromAddresses", "OPFMessageCopyToAddresses", "OPFMessageCopyCCAddresses",
                 "OPFMessageCopyBCCAddresses", "OPFMessageCopyReplyToAddresses", "OPFMessageCopySenderAddress":
                listElement = name
                addresses = []
            case "emailAddress":
                let address = attributes["OPFContactEmailAddressAddress"] ?? ""
                let display = attributes["OPFContactEmailAddressName"] ?? ""
                let formatted: String
                if display.isEmpty || display == address { formatted = address }
                else if address.isEmpty { formatted = display }
                else { formatted = "\"\(display.replacingOccurrences(of: "\"", with: ""))\" <\(address)>" }
                if !formatted.isEmpty { addresses.append(formatted) }
            case "messageAttachment":
                current?.attachments.append(Attachment(
                    name: attributes["OPFAttachmentName"] ?? "attachment",
                    contentType: attributes["OPFAttachmentContentType"] ?? "",
                    contentID: attributes["OPFAttachmentContentID"] ?? "",
                    url: attributes["OPFAttachmentURL"] ?? "",
                    declaredSize: Int(attributes["OPFAttachmentContentFileSize"] ?? "") ?? 0))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard var message = current else { return }
            if name == "email" {
                messages.append(message)
                current = nil
                text = ""
                return
            }
            defer { current = message }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "OPFMessageCopyFromAddresses": message.from = addresses.joined(separator: ", "); listElement = nil
            case "OPFMessageCopySenderAddress": message.senderAddress = addresses.joined(separator: ", "); listElement = nil
            case "OPFMessageCopyToAddresses": message.to = addresses.joined(separator: ", "); listElement = nil
            case "OPFMessageCopyCCAddresses": message.cc = addresses.joined(separator: ", "); listElement = nil
            case "OPFMessageCopyBCCAddresses": message.bcc = addresses.joined(separator: ", "); listElement = nil
            case "OPFMessageCopyReplyToAddresses": message.replyTo = addresses.joined(separator: ", "); listElement = nil
            case "OPFMessageCopySubject": message.subject = value
            case "OPFMessageCopyMessageID": message.messageID = value.isEmpty ? nil : value
            case "OPFMessageCopyInReplyTo": message.inReplyTo = value.isEmpty ? nil : value
            case "OPFMessageCopyReferences":
                message.references = value.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).map(String.init)
            case "OPFMessageCopyThreadTopic": message.threadTopic = value.isEmpty ? nil : value
            case "OPFMessageCopyThreadIndex": message.threadIndex = value.isEmpty ? nil : value
            case "OPFMessageCopySentTime": message.sentTime = OLMRecordReader.date(value)
            case "OPFMessageCopyReceivedTime": message.receivedTime = OLMRecordReader.date(value)
            case "OPFMessageCopyBody": message.plainBody = text.trimmingCharacters(in: .newlines)
            case "OPFMessageCopyHTMLBody": message.htmlBody = text.trimmingCharacters(in: .newlines)
            case "OPFMessageIsRead": message.isRead = value == "1" || value.lowercased() == "true"
            case "OPFMessageGetIsFlagged", "OPFMessageCopyFlagStatus":
                if value == "1" || value.lowercased() == "true" || value == "2" { message.isFlagged = true }
            case "OPFMessageCopyPrimaryCategory": message.category = value.isEmpty ? nil : value
            case "OPFMessageGetPriority", "OPFMessageCopyPriority":
                // Outlook: 1 = high, 3 = normal, 5 = low (MAPI PR_PRIORITY-style values also seen: 1/0/-1).
                switch value {
                case "1", "high": message.priority = "1"
                case "5", "-1", "low": message.priority = "5"
                default: break
                }
            default: break
            }
            text = ""
        }
    }

    /// Outlook writes `2015-03-26T07:54:13` (UTC, no zone) or with a trailing `Z`.
    static func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        if let date = iso.date(from: text + "Z") { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: text) ?? iso.date(from: text + "Z")
    }
}
