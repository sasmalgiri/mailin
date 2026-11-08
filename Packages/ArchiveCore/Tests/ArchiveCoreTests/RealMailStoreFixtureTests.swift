//
//  RealMailStoreFixtureTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §3, one test per acceptance anchor, run on the public
//  samples obtained 2026-11-07 (`Fixtures/FIXTURE_ACQUISITION_2026-11-07.md`)
//  against the PRODUCTION readers (`OLMParser`, `PSTParser` / `PSTSpecReader`,
//  `NSFParser`, `EMLXParser`). Expected values come from independent sources:
//
//   • OLM — the archive is a ZIP; the test extracts it with /usr/bin/ditto and
//     reads `message_*.xml`, the attachment members and the contact /
//     calendar / task / note files with its own XMLParser delegate (not the
//     production reader), hashing the member bytes itself.
//   • OST — readpst (libpst) output recorded in `Fixtures/real/*-readpst-inventory.json`.
//   • NSF — no independent reader on this Mac; the parser's result is recorded
//     and the fidelity claim stays open.
//
//  Each required external file is its own test method; an absent file is an
//  explicit `XCTSkip` naming it (release preflight: `ReleasePreflightFixtureTests`).
//

import XCTest
import Foundation
import CryptoKit
@testable import ArchiveCore

final class RealMailStoreFixtureTests: XCTestCase {

    // MARK: - Fixture access

    static let fixtures = ExternalFixtures.shared

    static let asposeOLM = "opensource/aspose-email-net/SampleOLM.olm"
    static let nativeOLM = "opensource/olmreader/outlook_example.olm"
    static let asposeOST = "opensource/aspose-email-net/SampleOstFile.ost"
    static let ost2013 = "opensource/java-libpst/example-2013.ost"
    static let asposeNSF = "opensource/aspose-email-net/SampleNSF.nsf"

    /// The external copy (verified) or, for the two small OLMs, the in-repo copy.
    private func olm(_ relative: String) throws -> URL {
        if case .verified(let url) = Self.fixtures.status(of: relative) { return url }
        let inRepo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(relative)")
        guard FileManager.default.fileExists(atPath: inRepo.path) else { return try Self.fixtures.require(relative) }
        return inRepo
    }

    private var scratch: URL!
    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("real-stores-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: scratch); super.tearDown() }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func attachmentDigest(_ a: AttachmentMetadata) -> String? {
        if let b64 = a.base64, let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) { return sha256(data) }
        if let url = a.fileURL, let data = try? Data(contentsOf: url) { return sha256(data) }
        return nil
    }

    // MARK: - Independent OLM inventory (ditto + own XML walk)

    struct InventoryAttachment { let name: String; let contentID: String?; let url: String; let member: URL?; let sha256: String?; let size: Int? }
    struct InventoryMessage {
        var record = ""          // archive-relative path of message_NNNNN.xml
        var subject = ""
        var sent: String?        // OPFMessageCopySentTime, as written
        var received: String?
        var isRead: String?      // OPFMessageGetIsRead, as written ("1E0", "0E0")
        var flagStatus: String?  // OPFMessageCopyGetFlagStatus
        var priority: String?    // OPFMessageGetPriority
        var messageID: String?
        var categories: [String] = []
        var attachments: [InventoryAttachment] = []
        /// Folder derived independently: the record's directory minus `Local/`, `Accounts/` and the `__Messages` marker.
        var folder: String {
            var parts = record.split(separator: "/").dropLast().map(String.init)
            parts.removeAll { $0 == "com.microsoft.__Messages" }
            if parts.first == "Local" || parts.first == "Accounts" { parts.removeFirst() }
            return parts.joined(separator: "/")
        }
        var key: String { "\(folder)|\(subject)" }
    }
    struct Inventory {
        var messages: [InventoryMessage] = []
        /// Non-mail files: root element → number of direct child records (contacts, appointments, tasks, notes, groups, categories).
        var nonMail: [String: Int] = [:]
        var attachmentOccurrences: Int { messages.reduce(0) { $0 + $1.attachments.count } }
    }

    /// Reads one `message_*.xml` with a delegate that knows only element names and attributes.
    private final class RecordDelegate: NSObject, XMLParserDelegate {
        var messages: [InventoryMessage] = []
        private var current: InventoryMessage?
        private var text = ""
        private var insideCategoryList = false
        private var insidePrimaryCategory = false
        var rootElement: String?
        var depth = 0
        var topLevelChildren = 0
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            if depth == 1 { rootElement = name }
            if depth == 2 { topLevelChildren += 1 }
            text = ""
            switch name {
            case "email": current = InventoryMessage()
            case "OPFMessageCopyCategoryList": insideCategoryList = true
            case "OPFMessageCopyPrimaryCategory": insidePrimaryCategory = true
            case "category" where insideCategoryList:
                if let n = attributes["OPFCategoryCopyName"] { current?.categories.append(n) }
            case "messageAttachment":
                current?.attachments.append(InventoryAttachment(name: attributes["OPFAttachmentName"] ?? "", contentID: attributes["OPFAttachmentContentID"],
                                                                url: attributes["OPFAttachmentURL"] ?? "", member: nil, sha256: nil, size: nil))
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            depth -= 1
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "email": if let m = current { messages.append(m) }; current = nil
            case "OPFMessageCopyCategoryList": insideCategoryList = false
            case "OPFMessageCopyPrimaryCategory": insidePrimaryCategory = false
            case "OPFCategoryCopyName" where insidePrimaryCategory:
                if !value.isEmpty, current?.categories.contains(value) == false { current?.categories.append(value) }
            case "OPFMessageCopySubject": current?.subject = value
            case "OPFMessageCopySentTime": current?.sent = value
            case "OPFMessageCopyReceivedTime": current?.received = value
            case "OPFMessageGetIsRead": current?.isRead = value
            case "OPFMessageCopyGetFlagStatus": current?.flagStatus = value
            case "OPFMessageGetPriority": current?.priority = value
            case "OPFMessageCopyMessageID": current?.messageID = value
            default: break
            }
            text = ""
        }
    }

    func independentInventory(of archive: URL) throws -> Inventory {
        let out = scratch.appendingPathComponent("x-\(archive.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, out.path]
        try ditto.run(); ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0, "ditto extracted \(archive.lastPathComponent)")
        var inventory = Inventory()
        let enumerator = FileManager.default.enumerator(at: out, includingPropertiesForKeys: [.isRegularFileKey])!
        var files: [URL] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
        let base = out.standardizedFileURL.path + "/"
        func relative(_ url: URL) -> String { String(url.standardizedFileURL.path.dropFirst(base.count)) }
        for url in files.sorted(by: { relative($0) < relative($1) }) where url.pathExtension.lowercased() == "xml" {
            let rel = relative(url)
            let parser = XMLParser(data: try Data(contentsOf: url))
            let delegate = RecordDelegate()
            parser.delegate = delegate
            parser.parse()
            if rel.contains("com.microsoft.__Messages/"), url.lastPathComponent.hasPrefix("message_") {
                for var m in delegate.messages {
                    m.record = rel
                    m.attachments = m.attachments.map { a in
                        let candidates = [a.url, "Local/" + a.url, a.url.hasPrefix("/") ? String(a.url.dropFirst()) : a.url]
                        let member = candidates.map { out.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
                        let data = member.flatMap { try? Data(contentsOf: $0) }
                        return InventoryAttachment(name: a.name, contentID: a.contentID, url: a.url, member: member,
                                                   sha256: data.map(Self.sha256), size: data?.count)
                    }
                    inventory.messages.append(m)
                }
            } else if let root = delegate.rootElement {
                inventory.nonMail[root, default: 0] += delegate.topLevelChildren
            }
        }
        return inventory
    }

    /// Multiset of "folder|subject" keys, so copies of one message in several folders are matched one for one.
    private func groups(_ emails: [MBOXParser.RawEmail]) -> [String: [MBOXParser.RawEmail]] {
        Dictionary(grouping: emails) { "\($0.folderPath ?? "")|\($0.headers["Subject"] ?? "")" }
    }

    // MARK: - Aspose SampleOLM.olm (22 mail records, 38 attachment occurrences)

    func testAsposeOLM_countsMatchIndependentInventory_22MailRecords_38AttachmentOccurrences() async throws {
        let url = try olm(Self.asposeOLM)
        let inventory = try independentInventory(of: url)
        XCTAssertEqual(inventory.messages.count, 22, "independent XML inventory: mail records")
        XCTAssertEqual(inventory.attachmentOccurrences, 38, "independent XML inventory: attachment occurrences")
        XCTAssertEqual(inventory.messages.flatMap(\.attachments).filter { $0.sha256 != nil }.count, 38, "every attachment URL resolves to a member")

        var parsed: [MBOXParser.RawEmail] = []
        let outcome = try OLMParser.walk(fileURL: url, senderEmail: "", batchSize: 5, onProgress: nil) { parsed += $0 }
        XCTAssertEqual(parsed.count, 22, "production OLM reader: messages")
        XCTAssertEqual(outcome.total, 22); XCTAssertEqual(outcome.parsed, 22); XCTAssertEqual(outcome.failed, 0)
        XCTAssertEqual(parsed.flatMap(\.attachments).count, 38, "production OLM reader: attachment occurrences")
        XCTAssertEqual(parsed.flatMap(\.attachments).filter { $0.isInline && !($0.contentID ?? "").isEmpty }.count, 24, "24 occurrences carry a Content-ID (inline)")
        XCTAssertNil(outcome.categories["olm_attachment_bytes_missing"])
        // The streaming entry point hands out the same messages.
        var streamed: [MBOXParser.RawEmail] = []
        let result = try await OLMParser.parseStreaming(fileURL: url, senderEmail: "", batchSize: 7) { streamed += $0 }
        XCTAssertEqual(result.parsed, 22)
        XCTAssertEqual(streamed.map { $0.headers["Message-ID"] ?? "" }, parsed.map { $0.headers["Message-ID"] ?? "" })
    }

    func testAsposeOLM_folderPathsAreTheRecordsRealPlaceInTheTree() throws {
        let url = try olm(Self.asposeOLM)
        let inventory = try independentInventory(of: url)
        let parsed = try OLMParser.parse(fileURL: url, senderEmail: "")
        let expected = Set(inventory.messages.map(\.folder))
        XCTAssertEqual(expected.count, 11)
        XCTAssertTrue(expected.contains("Outlook2 PST/Inbox/Custom Folder"))
        XCTAssertTrue(expected.contains("Deleted Items/Outlook for Mac ArchiveZZZ OLM/On My Computer/test_olm2010 PST/Folder"))
        XCTAssertEqual(Set(parsed.compactMap(\.folderPath)), expected, "folder paths")
        XCTAssertEqual(parsed.map { "\($0.folderPath ?? "")|\($0.headers["Subject"] ?? "")" }.sorted(),
                       inventory.messages.map(\.key).sorted(), "each message sits in the folder its record sits in")
        XCTAssertEqual(Set(OLMParser.declaredFolders(fileURL: url)).isSuperset(of: expected), true, "FOLD-02: every folder with records is declared")
        for empty in ["Inbox", "Sent Items", "Drafts", "Junk E-mail", "Outbox"] {
            XCTAssertTrue(OLMParser.declaredFolders(fileURL: url).contains(empty), "empty top-level folder \(empty) declared")
        }
    }

    func testAsposeOLM_datesAreTheRecordsSentTime() throws {
        let url = try olm(Self.asposeOLM)
        let inventory = try independentInventory(of: url)
        let parsed = groups(try OLMParser.parse(fileURL: url, senderEmail: ""))
        var checked = 0
        for (key, records) in Dictionary(grouping: inventory.messages, by: \.key) {
            let got = parsed[key] ?? []
            XCTAssertEqual(got.count, records.count, key)
            // Outlook writes `2011-06-21T23:51:07` with no zone; the reader reads it as UTC.
            XCTAssertEqual(Set(got.map(\.timestamp)), Set(records.compactMap { $0.sent.map { $0 + "Z" } }), "timestamp of \(key)")
            checked += got.count
        }
        XCTAssertEqual(checked, 22)
        // Received time is kept too (differs from sent on the Outlook2 Inbox test messages).
        let received = parsed["Outlook2 PST/Inbox/Custom Folder|Microsoft Office Outlook Test Message"]?.first
        XCTAssertEqual(received?.timestamp, "2019-06-15T09:22:55Z")
        XCTAssertEqual(received?.headers["X-Mailin-Received-Time"], "2011-06-21T23:44:21Z")
    }

    func testAsposeOLM_attachmentBytesAndContentIDsMatchTheArchiveMembers() throws {
        let url = try olm(Self.asposeOLM)
        let inventory = try independentInventory(of: url)
        let parsed = groups(try OLMParser.parse(fileURL: url, senderEmail: ""))
        var compared = 0
        for record in inventory.messages where !record.attachments.isEmpty {
            guard let email = parsed[record.key]?.first(where: { e in e.attachments.map(Self.attachmentDigest) == record.attachments.map(\.sha256) }) ?? parsed[record.key]?.first else {
                XCTFail("no parsed message for \(record.key)"); continue
            }
            XCTAssertEqual(email.attachments.map(\.filename), record.attachments.map(\.name), "names, in record order: \(record.key)")
            XCTAssertEqual(email.attachments.map(Self.attachmentDigest), record.attachments.map(\.sha256), "SHA-256 of the bytes: \(record.key)")
            XCTAssertEqual(email.attachments.map { $0.size }, record.attachments.map { $0.size ?? -1 }, "sizes are the member's real size, not Outlook's rounded figure: \(record.key)")
            XCTAssertEqual(email.attachments.map { $0.contentID?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) },
                           record.attachments.map { $0.contentID?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }, "Content-IDs: \(record.key)")
            compared += email.attachments.count
        }
        XCTAssertEqual(compared, 38)
        // The embedded .eml attachment ("test message with embedded message") is a message/rfc822 part with its real bytes.
        let embedded = inventory.messages.first { $0.subject == "test message with embedded message" }
        XCTAssertEqual(embedded?.attachments.first?.name.hasSuffix(".eml"), true)
    }

    func testAsposeOLM_readFlagsCategoriesAndNonMailAccounting() throws {
        let url = try olm(Self.asposeOLM)
        let inventory = try independentInventory(of: url)
        var parsed: [MBOXParser.RawEmail] = []
        let outcome = try OLMParser.walk(fileURL: url, senderEmail: "", batchSize: 50, onProgress: nil) { parsed += $0 }
        // Every record is read (`OPFMessageGetIsRead` = "1E0") and unflagged ("0"); none carries a category.
        XCTAssertEqual(Set(inventory.messages.compactMap(\.isRead)), ["1E0"])
        XCTAssertEqual(parsed.filter { $0.flags.contains("Read") }.count, 22, "read state read from Outlook's '1E0'")
        XCTAssertEqual(parsed.filter { $0.flags.contains("Flagged") }.count, 0)
        XCTAssertTrue(inventory.messages.allSatisfy { $0.categories.isEmpty })
        XCTAssertTrue(parsed.allSatisfy { Set($0.tags).subtracting(["Read"]).isEmpty }, "no category tags invented")
        // Non-mail: three Contacts.xml files with one contact each; Categories.xml is a colour table, not an object.
        XCTAssertEqual(inventory.nonMail["contacts"], 3)
        XCTAssertEqual(inventory.nonMail["categories"], 12)
        XCTAssertEqual(outcome.categories["olm_contacts_not_imported"], 3, "contacts counted per record, separately from mail")
        XCTAssertNil(outcome.categories["olm_other_objects_not_imported"], "nothing left as 'other': \(outcome.categories)")
        XCTAssertNil(outcome.categories["olm_calendar_not_imported"])
    }

    // MARK: - Native Outlook 16 for Mac export (teverett/OLMReader outlook_example.olm)

    func testNativeOLM_7MailRecords_9Attachments_bytesMatchMembers() throws {
        let url = try olm(Self.nativeOLM)
        let inventory = try independentInventory(of: url)
        XCTAssertEqual(inventory.messages.count, 7)
        XCTAssertEqual(inventory.attachmentOccurrences, 9)
        let parsed = try OLMParser.parse(fileURL: url, senderEmail: "")
        XCTAssertEqual(parsed.count, 7)
        XCTAssertEqual(parsed.flatMap(\.attachments).count, 9)
        let byKey = groups(parsed)
        for record in inventory.messages {
            let email = byKey[record.key]?.first
            XCTAssertNotNil(email, record.key)
            XCTAssertEqual(email?.attachments.map(\.filename), record.attachments.map(\.name), record.key)
            XCTAssertEqual(email?.attachments.map(Self.attachmentDigest), record.attachments.map(\.sha256), "bytes of \(record.key)")
            XCTAssertEqual(email?.attachments.map { $0.size }, record.attachments.map { $0.size ?? -1 }, "sizes of \(record.key)")
        }
        XCTAssertEqual(Set(parsed.compactMap(\.folderPath)), ["Drafts", "Outlook PST/Archive", "Outlook PST/Drafts", "Outlook PST/Inbox"])
        // Non-ASCII subjects survive (Japanese, Hebrew, Korean records).
        XCTAssertTrue(parsed.contains { $0.headers["Subject"] == "パーティーは何時ですか？" })
        XCTAssertTrue(parsed.contains { $0.headers["Subject"] == "באיזה שעה המסיבה?" })
        // A draft without a received time still has its sent time as the date.
        XCTAssertEqual(byKey["Drafts|Draft with low priority"]?.first?.timestamp, "2018-06-21T03:26:46Z")
        // A record with only a received time (no sent time) takes it as the date.
        XCTAssertEqual(byKey["Outlook PST/Archive|Email Test"]?.first?.timestamp, "2018-06-18T03:34:54Z")
    }

    func testNativeOLM_nonMailObjectsAccountedSeparatelyFromMail() throws {
        let url = try olm(Self.nativeOLM)
        let inventory = try independentInventory(of: url)
        XCTAssertEqual(inventory.nonMail["contacts"], 5)
        XCTAssertEqual(inventory.nonMail["groups"], 2)
        XCTAssertEqual(inventory.nonMail["appointments"], 8)
        XCTAssertEqual(inventory.nonMail["tasks"], 5)
        XCTAssertEqual(inventory.nonMail["notes"], 1)
        XCTAssertEqual(inventory.nonMail["categories"], 10)
        var parsed: [MBOXParser.RawEmail] = []
        let outcome = try OLMParser.walk(fileURL: url, senderEmail: "", batchSize: 50, onProgress: nil) { parsed += $0 }
        XCTAssertEqual(outcome.parsed, 7, "mail")
        XCTAssertEqual(outcome.categories["olm_contacts_not_imported"], 5, "\(outcome.categories)")
        XCTAssertEqual(outcome.categories["olm_contact_groups_not_imported"], 2)
        XCTAssertEqual(outcome.categories["olm_calendar_not_imported"], 8)
        XCTAssertEqual(outcome.categories["olm_tasks_not_imported"], 5)
        XCTAssertEqual(outcome.categories["olm_notes_not_imported"], 1)
        XCTAssertNil(outcome.categories["olm_other_objects_not_imported"], "the category colour table is not an object")
        XCTAssertEqual(parsed.count, 7, "non-mail never becomes a message")
    }

    func testNativeOLM_categoryFlagPriorityAndUnreadStateFromRealRecords() throws {
        let url = try olm(Self.nativeOLM)
        let inventory = try independentInventory(of: url)
        let byKey = groups(try OLMParser.parse(fileURL: url, senderEmail: ""))
        // Category list + primary category (nested elements) → one tag.
        XCTAssertEqual(inventory.messages.first { $0.subject == "Email Test" }?.categories, ["Blue Category"])
        let emailTest = byKey["Outlook PST/Archive|Email Test"]?.first
        XCTAssertEqual(emailTest?.tags.filter { $0 == "Blue Category" }.count, 1, "category as a tag, once: \(emailTest?.tags ?? [])")
        XCTAssertEqual(emailTest?.headers["X-Priority"], "2", "Outlook's 2 = high")
        // Follow-up flag ("1") and unread ("0E0").
        let followup = byKey["Drafts|Mail with followup"]?.first
        XCTAssertEqual(inventory.messages.first { $0.subject == "Mail with followup" }?.flagStatus, "1")
        XCTAssertTrue(followup?.flags.contains("Flagged") == true, "\(followup?.flags ?? [])")
        XCTAssertFalse(followup?.flags.contains("Read") == true, "0E0 = unread")
        XCTAssertFalse(byKey["Outlook PST/Drafts|What time is party?"]?.first?.flags.contains("Read") == true)
        XCTAssertEqual(byKey.values.flatMap { $0 }.filter { $0.flags.contains("Read") }.count, 5, "5 of 7 are read")
        // Low priority ("4") and normal ("3": no header).
        XCTAssertEqual(byKey["Drafts|Draft with low priority"]?.first?.headers["X-Priority"], "4")
        XCTAssertNil(byKey["Outlook PST|Inbox"]?.first?.headers["X-Priority"])
        XCTAssertNil(byKey["Outlook PST/Drafts|What time is party?"]?.first?.headers["X-Priority"])
    }

    // MARK: - OST through the PST readers, reconciled with readpst

    struct ReadpstInventory: Decodable {
        struct Item: Decodable { let n: Int; let kind: String; let subject: String?; let messageID: String?; let date: String?; let attachments: [Att] }
        struct Att: Decodable { let name: String; let size: Int; let sha256: String }
        struct Totals: Decodable { let items: Int; let mail: Int; let nonMail: Int; let attachmentPayloads: Int }
        let store: String
        let folders: [String: [Item]]
        let totals: Totals
    }
    static func readpst(_ name: String) throws -> ReadpstInventory {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/real/\(name)")
        return try JSONDecoder().decode(ReadpstInventory.self, from: Data(contentsOf: url))
    }
    static func normalizedID(_ id: String?) -> String { (id ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }

    func testAsposeOST_wVer23_92ItemsReconciledWithReadpst_87MailAnd5Calendar_attachmentBytes() async throws {
        let url = try Self.fixtures.require(Self.asposeOST)
        let reference = try Self.readpst("sampleost-readpst-inventory.json")
        XCTAssertEqual(reference.totals.items, 92); XCTAssertEqual(reference.totals.mail, 87); XCTAssertEqual(reference.totals.nonMail, 5)
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let spec = try PSTSpecReader(data: bytes)
        XCTAssertEqual(spec.geometry, .unicode512, "Aspose's OST is the Unicode 512-byte layout (wVer 23)")
        XCTAssertEqual(Array(bytes[8..<10]), [0x53, 0x4F], "wMagicClient SO")

        let parsed = try PSTParser.parse(fileURL: url, senderEmail: "")
        let referenceMail = reference.folders.flatMap { folder, items in items.filter { $0.kind == "eml" }.map { (folder, $0) } }
        XCTAssertEqual(parsed.count, 87, "mail items (readpst: 87 .eml); calendar items are not mail")
        // Every readpst message is present, by Message-ID, in the folder readpst found it in.
        let byID = Dictionary(grouping: parsed) { Self.normalizedID($0.headers["Message-ID"]) }
        var matched = 0
        for (folder, item) in referenceMail {
            let id = Self.normalizedID(item.messageID)
            guard !id.isEmpty else { continue }
            guard let hits = byID[id], !hits.isEmpty else { XCTFail("readpst \(folder)/\(item.n) \(id) not read"); continue }
            XCTAssertTrue(hits.contains { ($0.folderPath ?? "").hasSuffix(folder) }, "\(id) in \(folder), reader says \(hits.map { $0.folderPath ?? "nil" })")
            matched += 1
        }
        XCTAssertEqual(matched, referenceMail.filter { !Self.normalizedID($0.1.messageID).isEmpty }.count)
        // Per-folder counts.
        var perFolder: [String: Int] = [:]
        for e in parsed { perFolder[e.folderPath ?? "", default: 0] += 1 }
        for (folder, items) in reference.folders where !items.filter({ $0.kind == "eml" }).isEmpty {
            let got = perFolder.first { $0.key.hasSuffix(folder) }?.value ?? 0
            XCTAssertEqual(got, items.filter { $0.kind == "eml" }.count, "folder \(folder)")
        }
        // Attachments: every payload readpst extracted is present byte for byte on the same message.
        // Sent items and sync logs have no Message-ID (13 of 87): those pair by folder + subject.
        var paired = Set<UUID>()
        func pair(_ folder: String, _ item: ReadpstInventory.Item) -> MBOXParser.RawEmail? {
            let id = Self.normalizedID(item.messageID)
            let candidates = id.isEmpty
                ? parsed.filter { ($0.folderPath ?? "").hasSuffix(folder) && ($0.headers["Subject"] ?? "") == (item.subject ?? "") }
                : (byID[id] ?? []).filter { ($0.folderPath ?? "").hasSuffix(folder) }
            guard let hit = candidates.first(where: { !paired.contains($0.id) }) else { return nil }
            paired.insert(hit.id)
            return hit
        }
        var payloadsMatched = 0
        for (folder, item) in referenceMail where !item.attachments.isEmpty {
            guard let email = pair(folder, item) else { XCTFail("no reader message for readpst \(folder)/\(item.n) \(item.subject ?? "")"); continue }
            XCTAssertEqual(email.attachments.count, item.attachments.count, "\(folder)/\(item.n) \(item.subject ?? ""): attachment count")
            let digests = Set(email.attachments.compactMap(Self.attachmentDigest))
            for att in item.attachments {
                XCTAssertTrue(digests.contains(att.sha256), "\(folder)/\(item.n) \(att.name) (\(att.size) bytes) byte-identical")
                if digests.contains(att.sha256) { payloadsMatched += 1 }
            }
        }
        XCTAssertEqual(payloadsMatched, reference.totals.attachmentPayloads, "all 36 readpst payloads found")
        let total = parsed.reduce(0) { $0 + $1.attachments.count }
        // readpst -S writes 36 payload files; the directive quotes libpff's 39. The reader's figure is reported, not hidden.
        XCTAssertGreaterThanOrEqual(total, 36, "attachment payloads read: \(total) (readpst 36, libpff 39)")
        XCTAssertLessThanOrEqual(total, 39, "attachment payloads read: \(total) (readpst 36, libpff 39)")
        // Streaming path: same count and order.
        var streamed: [MBOXParser.RawEmail] = []
        let result = try await PSTParser.parseStreaming(fileURL: url, senderEmail: "", batchSize: 10) { streamed += $0 }
        XCTAssertEqual(result.count, 87)
        XCTAssertEqual(streamed.map { $0.headers["Message-ID"] ?? "" }, parsed.map { $0.headers["Message-ID"] ?? "" })
    }

    func testExample2013OST_wVer36_realFileConfirmsTheFourKiBGeometry_3Messages() async throws {
        let url = try Self.fixtures.require(Self.ost2013)
        let reference = try Self.readpst("example2013-readpst-inventory.json")
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        func u16(_ o: Int) -> UInt16 { UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8 }
        func u64(_ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[o + $1]) << (8 * UInt64($1)) } }
        // Header: "!BDN", "SO", wVer 36; Unicode layout (ROOT at 180, BREFs at 216–247, bCryptMethod at 513).
        XCTAssertEqual(Array(bytes.prefix(4)), [0x21, 0x42, 0x44, 0x4E])
        XCTAssertEqual(Array(bytes[8..<10]), [0x53, 0x4F])
        XCTAssertEqual(u16(10), 36)
        XCTAssertEqual(u64(184), UInt64(bytes.count), "ROOT.cbFile is the file size")
        XCTAssertEqual(bytes[513], 0, "bCryptMethod none")
        let nbtIB = Int(u64(224)), bbtIB = Int(u64(240))
        XCTAssertEqual(nbtIB % 4096, 0); XCTAssertEqual(bbtIB % 4096, 0)
        for (ib, ptype) in [(nbtIB, UInt8(0x81)), (bbtIB, UInt8(0x80))] {
            // Counts at 4056 as two-byte values; 169 entries of 24 bytes fit in 4056; trailer at 4072 with the CRC over the 4072 bytes before it.
            XCTAssertEqual(Int(u16(ib + 4058)), 4056 / 24, "cEntMax")
            XCTAssertEqual(bytes[ib + 4060], 24, "cbEnt of an index page")
            XCTAssertGreaterThan(bytes[ib + 4061], 0, "cLevel: a real 2013 OST has an index level")
            XCTAssertEqual(bytes[ib + 4072], ptype); XCTAssertEqual(bytes[ib + 4073], ptype)
            XCTAssertEqual(bytes.subdata(in: (ib + 4076)..<(ib + 4080)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) },
                           PSTSpecFormat.crc(bytes.subdata(in: ib..<(ib + 4072))), "dwCRC over 4072 bytes")
            XCTAssertEqual(PSTPageGeometry.fourK.pageCounts(bytes, pageOffset: ib).cbEnt, 24)
        }
        // Fixed pages as Outlook 2013 really places them: DList at 0x21000, first AMap at 0x22000 (= ROOT.ibAMapLast),
        // and the file ends exactly one AMap region (4072 × 8 × 512 bytes) after it. No PMap / FMap pages.
        XCTAssertEqual(bytes[0x21000 + 4072], 0x86, "DList")
        XCTAssertEqual(bytes[0x22000 + 4072], 0x84, "AMap")
        XCTAssertEqual(u64(192), 0x22000, "ROOT.ibAMapLast")
        XCTAssertEqual(UInt64(bytes.count) - 0x22000, PSTWriterLayout.ost4K.amapRegion, "one AMap region covers the rest of the file")
        XCTAssertNotEqual(PSTWriterLayout.ost4K.amapBase, 0x22000, "the spec writer's fixed-page positions differ from Outlook 2013's (recorded; the reader takes positions from the header, not from this constant)")

        // The production readers.
        let spec = try PSTSpecReader(data: bytes)
        XCTAssertEqual(spec.geometry, .fourK)
        let parsed = try PSTParser.parse(fileURL: url, senderEmail: "")
        let withID = parsed.filter { !Self.normalizedID($0.headers["Message-ID"]).isEmpty }
        let referenceIDs = Set(reference.folders.values.flatMap { $0 }.map { Self.normalizedID($0.messageID) }.filter { !$0.isEmpty })
        XCTAssertEqual(referenceIDs.count, 3)
        XCTAssertEqual(Set(withID.map { Self.normalizedID($0.headers["Message-ID"]) }), referenceIDs, "the 3 messages readpst read")
        XCTAssertEqual(withID.count, 3, "3 messages; reader total \(parsed.count) (readpst also writes one empty root item, 16.eml)")
        let bySubject = Dictionary(grouping: withID) { $0.headers["Subject"] ?? "" }
        XCTAssertEqual(bySubject["Microsoft Outlook Test Message"]?.count, 2)
        XCTAssertEqual(bySubject["Test 2"]?.count, 1)
        XCTAssertEqual(bySubject["Test 2"]?.first?.folderPath?.hasSuffix("Sent Items"), true)
        XCTAssertTrue(bySubject["Microsoft Outlook Test Message"]?.allSatisfy { $0.folderPath?.hasSuffix("Inbox") == true } == true)
        XCTAssertEqual(Set(bySubject["Microsoft Outlook Test Message"]?.map(\.timestamp) ?? []), ["2014-04-09T19:54:39Z", "2014-06-05T16:22:32Z"])
        // readpst's Date header is the transport Date (16:38:31Z); mailin's timestamp is PR_MESSAGE_DELIVERY_TIME,
        // one second later on this sent item. Both are the message's own data; the difference is recorded, not hidden.
        XCTAssertEqual(bySubject["Test 2"]?.first?.timestamp, "2014-04-09T16:38:32Z", "delivery time")
        XCTAssertEqual(MBOXParser.parseDate(bySubject["Test 2"]?.first?.headers["Date"])?.timeIntervalSince1970, 1397061512, "Date header = delivery time (readpst's transport Date is 16:38:31Z)")
        XCTAssertEqual(bySubject["Test 2"]?.first?.headers["From"]?.contains("bernard.chung@apogeephysicians.com"), true)
        XCTAssertTrue(parsed.allSatisfy { $0.attachments.isEmpty }, "readpst found no attachment payloads")
        // Folders the file lists (empty ones included), 2013 names.
        let declared = Set(spec.folderPaths())
        for name in ["Inbox", "Sent Items", "Inbox/Testing", "Calendar (This computer only)", "Contacts (This computer only)"] {
            XCTAssertTrue(declared.contains { $0.hasSuffix(name) }, "declared folder \(name) in \(declared.count) folders")
        }
        var streamed: [MBOXParser.RawEmail] = []
        let result = try await PSTParser.parseStreaming(fileURL: url, senderEmail: "", batchSize: 2) { streamed += $0 }
        XCTAssertEqual(result.count, parsed.count)
        XCTAssertEqual(streamed.count, parsed.count)
    }

    // MARK: - NSF: the parser's result on the exact public sample, inventory still needed

    /// The measured state on the exact public sample, stated as such. `SampleNSF.nsf` is a 47 MB Notes
    /// mail database (mail template design notes signed "CN=Lotus Notes Template Development/O=Lotus
    /// Notes", plus a user's documents: "CN=Dmit Sam/O=Dmit Sam" appears 64 times, the address
    /// <sdmit@km.ru> once). `NSFParser` reads **0** mail notes from it: the "structured" path looks for an
    /// item layout mailin's own synthetic writer produces (`type, nameLen, valueLen, name, value`), not the
    /// Notes ODS bucket layout, and the text fallback finds no "Form: Memo" lines because the file is binary.
    /// No independent Notes reader exists on this Mac, so no fidelity is claimed and the registry row says so.
    /// This test fails the day the reader starts reading the file (then the numbers here must be re-derived).
    func testAsposeNSF_productionParserRunRecorded_readsZeroNotes_independentInventoryStillNeeded() async throws {
        let url = try Self.fixtures.require(Self.asposeNSF)
        let start = Date()
        let parsed = try NSFParser.parse(fileURL: url, senderEmail: "")
        let elapsed = Date().timeIntervalSince(start)
        print("NSF SampleNSF.nsf: \(parsed.count) mail rows, \(String(format: "%.1f", elapsed)) s — reader does not parse the ODS layout")
        XCTAssertEqual(parsed.count, 0, "measured 2026-11-07: the heuristic reader salvages nothing from the real database; a real result here is news — update the registry row")
        // The whole file is scanned (no 100 KB give-up) and the two paths agree.
        var count = 0
        let emitted = try await NSFParser.parseStreaming(fileURL: url, senderEmail: "", batchSize: 50) { count += $0.count }
        XCTAssertEqual(emitted, count)
        XCTAssertEqual(emitted, parsed.count, "streaming and array paths agree")
    }

    /// Rule 6: the structured scan used to stop after 100,000 bytes without a record, so any note
    /// sitting behind more than 100 KB of design data (every real database) was never reached.
    func testNSF_structuredScanReadsANoteBehind150KBOfNonRecordBytes() async throws {
        func item(_ name: String, _ value: String) -> Data {
            var d = Data()
            let n = Data(name.utf8), v = Data(value.utf8)
            withUnsafeBytes(of: UInt16(0x0500).littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(n.count).littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(v.count).littleEndian) { d.append(contentsOf: $0) }
            d.append(n); d.append(v)
            return d
        }
        var file = Data([0x1A, 0x00]); file.append(Data(repeating: 0, count: 254))
        withUnsafeBytes(of: UInt32(256).littleEndian) { file.replaceSubrange(0x28..<0x2C, with: $0) }
        // 150 KB of bytes that are not a record (design-note-like text, no valid item type word).
        file.append(Data(String(repeating: "LotusScript design element text; ", count: 150 * 1024 / 33 + 1).utf8))
        for name in ["Subject", "From", "SendTo", "DeliveredDate", "$MessageID", "Body", "Form"] {
            let value = ["Subject": "Behind the design notes", "From": "CN=Dmit Sam/O=Dmit Sam", "SendTo": "CN=Team/O=Acme",
                         "DeliveredDate": "02/03/2024 09:10:00", "$MessageID": "<behind@acme.example>", "Body": "Found.", "Form": "Memo"][name]!
            file.append(item(name, value))
        }
        file.append(Data(repeating: 0, count: 128))
        let url = scratch.appendingPathComponent("behind.nsf")
        try file.write(to: url)
        let parsed = try NSFParser.parse(fileURL: url, senderEmail: "")
        XCTAssertEqual(parsed.map { $0.headers["Subject"] ?? "" }, ["Behind the design notes"])
        var streamed = 0
        let emitted = try await NSFParser.parseStreaming(fileURL: url, senderEmail: "", batchSize: 10) { streamed += $0.count }
        XCTAssertEqual(emitted, 1); XCTAssertEqual(streamed, 1)
    }

    // MARK: - Apple Mail .emlx (Tika) and the owner-bound same-message set

    func testTikaEMLX_appleMailMessagesReadWithSubjectAndHTML() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/opensource/tika-mail")
        let multipart = dir.appendingPathComponent("testEMLX_multipart_html.emlx")
        let single = dir.appendingPathComponent("testEMLX_single_part_html.emlx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: multipart.path), "Tika EMLX fixture not in the repo")
        let a = try EMLXParser.parse(fileURL: multipart, senderEmail: "")
        XCTAssertEqual(a.count, 1)
        XCTAssertFalse(a.first?.headers["Subject"]?.isEmpty ?? true)
        XCTAssertFalse(a.first?.htmlBody.isEmpty ?? true, "HTML part kept")
        let b = try EMLXParser.parse(fileURL: single, senderEmail: "")
        XCTAssertEqual(b.count, 1)
        XCTAssertFalse(b.first?.htmlBody.isEmpty ?? true)
    }

    func testOwnerPack_nativeOLMAppleMailMBOXAndDerivedEMLOfTheSameMessage_pending() throws {
        let pending = ExternalFixtures.required.compactMap { if case .pending(let what) = $0 { return what } else { return nil } }
        throw XCTSkip("owner-bound (pack 'Online mail fixtures and S/MIME' exists only as a ChatGPT library file; not on this Mac on 2026-11-09): \(pending.joined(separator: "; ")). The public samples are not that set and are not presented as it.")
    }
}
