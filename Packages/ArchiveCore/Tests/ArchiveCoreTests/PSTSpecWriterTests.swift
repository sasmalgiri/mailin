//
//  PSTSpecWriterTests.swift
//  ArchiveCoreTests
//
//  3.0 B8: the [MS-PST] writer. 1,000 synthetic emails (attachments, cc/bcc,
//  HTML, bodies larger than one heap allocation and one block) are written,
//  then read back by mailin's spec reader; with MAILIN_PST_TOOLS=1 the same
//  file is also checked by libpff (pypff) and libpst (readpst), independent
//  readers, run as external tools.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class PSTSpecWriterTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pstspecw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    static func emails(_ n: Int) -> [MBOXParser.RawEmail] {
        (0..<n).map { i in
            let long = i % 25 == 0 ? String(repeating: "Long paragraph \(i) for the body. ", count: 400) : ""
            let body = "Hello number \(i).\n\(long)Regards,\nSender \(i % 30)"
            var atts: [AttachmentMetadata] = []
            if i % 10 == 0 {
                let bytes = Data((0..<(i % 40 == 0 ? 20_000 : 300)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ i) })
                atts.append(AttachmentMetadata(filename: "file-\(i).bin", mimeType: "application/octet-stream", size: bytes.count,
                                               base64: bytes.base64EncodedString()))
            }
            var headers = ["From": "Sender \(i % 30) <s\(i % 30)@example.com>", "To": "Ann <ann@example.org>, bob@example.org",
                           "Subject": "Subject \(i) — résumé ✓", "Message-ID": "<w\(i)@example.com>",
                           "Date": "Mon, 6 Jan 2025 10:\(String(format: "%02d", i % 60)):00 +0000"]
            if i % 3 == 0 { headers["Cc"] = "Cara <cara@example.net>" }
            if i % 7 == 0 { headers["Bcc"] = "hidden@example.net" }
            return MBOXParser.RawEmail(headers: headers,
                                       rawSource: "From: s@example.com\r\nSubject: Subject \(i)\r\n\r\n\(body)",
                                       messageType: "email", attachments: atts,
                                       timestamp: "2025-01-06T10:\(String(format: "%02d", i % 60)):00Z", domains: ["example.com"],
                                       plainBody: body, htmlBody: i % 4 == 0 ? "<p>Hello <b>\(i)</b></p>" : "")
        }
    }

    /// Replication state as SCANPST's optional repair leaves it: the store's version history
    /// [1][GUID][1]; on every folder row (but the spam folder's) and message row a ReplItemid,
    /// a unique change number (multiple of 4) and the store's version history; the HMP (0xC01:
    /// heap 0x9C → root HID → BTH 16-byte key → NID) holding exactly those item IDs in byte order.
    static func replicationProblems(_ spec: PSTSpecReader, expectedRows: Int) -> [String] {
        var problems: [String] = []
        let store = spec.nodes[0x21].map { spec.propertyContext(dataBid: $0.dataBid, subBid: $0.subBid) } ?? [:]
        guard let history = store[0x0E34]?.bytes, history.count == 24,
              history.prefix(4) == [1, 0, 0, 0], history.suffix(4) == [1, 0, 0, 0] else { return ["store version history"] }
        var rows: [[UInt8]: UInt32] = [:]
        var changeNumbers = Set<Int64>()
        for node in spec.nodes.values where node.nid & 0x1F == 0x0D || node.nid & 0x1F == 0x0E {
            for row in spec.table(dataBid: node.dataBid, subBid: node.subBid) where row.rowID != PSTSpecWriter.spamSearchFolderNid {
                guard let id = row.values[0x0E30_0102]?.bytes, id.count == 16,
                      let cn = row.values[0x0E33_0014]?.int, cn % 4 == 0,
                      row.values[0x0E34_0102]?.bytes == history else { problems.append("row \(String(row.rowID, radix: 16)) replication cells"); continue }
                if rows.updateValue(row.rowID, forKey: id) != nil { problems.append("item id repeated") }
                if !changeNumbers.insert(cn).inserted { problems.append("change number \(cn) repeated") }
            }
        }
        if rows.count != expectedRows { problems.append("\(rows.count) rows with item ids, expected \(expectedRows)") }
        guard let node = spec.nodes[0xC01], let heap = PSTSpecReader.Heap(spec.dataBlocks(node.dataBid)), heap.clientSig == 0x9C,
              let root = heap.alloc(heap.userRoot), root.count == 4 else { return problems + ["HMP heap"] }
        let records = spec.bth(heap, PSTSpecReader.u32(root, 0))
        if records.map(\.0) != records.map(\.0).sorted(by: { $0.lexicographicallyPrecedes($1) }) { problems.append("HMP keys not in byte order") }
        if records.count != rows.count { problems.append("HMP \(records.count) records, \(rows.count) rows") }
        for (key, value) in records where rows[key] != PSTSpecReader.u32(value, 0) { problems.append("HMP \(key) → wrong NID"); break }
        return problems
    }

    func writeFixture(_ n: Int, name: String = "spec.pst", diagnosticEmptyNodes: [UInt32] = []) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let w = try PSTSpecWriter(url: url)
        w.diagnosticEmptyNodes = diagnosticEmptyNodes
        let inbox = w.appendFolder(name: "Inbox")
        for (i, e) in Self.emails(n).enumerated() {
            if i % 5 == 0 { try w.append(email: e, folder: inbox) } else { try w.appendMessage(e) }
        }
        XCTAssertEqual(try w.finalize(), n)
        return url
    }

    func testSpecWriter_1k_readsBackExactly_throughTheSpecReader() throws {
        let n = 1_000
        let url = try writeFixture(n)
        let bytes = try Data(contentsOf: url)
        // Structure: header CRCs, file ends at an allocation-map boundary.
        XCTAssertEqual(Array(bytes.prefix(4)), [0x21, 0x42, 0x44, 0x4E])
        let partial = bytes.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(partial, PSTSpecFormat.crc(bytes.subdata(in: 8..<479)))
        XCTAssertEqual((UInt64(bytes.count) - PSTSpecFormat.amapBase) % PSTSpecFormat.amapRegion, 0)

        let spec = try PSTSpecReader(data: bytes)
        XCTAssertEqual(spec.crypt, 0)
        let read = spec.messages()
        XCTAssertEqual(read.count, n)
        let original = Self.emails(n)
        let bySubject = Dictionary(uniqueKeysWithValues: read.map { ($0.internetMessageId ?? "", $0) })
        var problems: [String] = []
        for e in original {
            guard let m = bySubject[e.headers["Message-ID"]!] else { problems.append("missing \(e.headers["Message-ID"]!)"); continue }
            if m.subject != e.headers["Subject"] { problems.append("subject \(m.subject)") }
            if m.bodyText != e.plainBody { problems.append("body of \(m.subject) (\(m.bodyText.count) vs \(e.plainBody.count))") }
            if m.attachments.count != e.attachments.count { problems.append("attachments of \(m.subject)") }
            for (a, b) in zip(m.attachments, e.attachments) where Data(base64Encoded: a.base64 ?? "", options: .ignoreUnknownCharacters) != Data(base64Encoded: b.base64 ?? "") {
                problems.append("attachment bytes of \(m.subject): read \(Data(base64Encoded: a.base64 ?? "", options: .ignoreUnknownCharacters)?.count ?? -1) of \(b.size), meta size \(a.size), file \(a.fileURL?.path ?? "-")")
            }
            if m.senderEmail != PSTSpecWriter.addresses(e.headers["From"]).first?.email { problems.append("sender of \(m.subject)") }
            // Cc/Bcc come back (display lines, or the recipient table when a reader has none).
            if e.headers["Cc"] != nil, !m.displayCc.contains("cara@example.net") { problems.append("cc of \(m.subject): \(m.displayCc)") }
            if e.headers["Bcc"] != nil, !m.displayBcc.contains("hidden@example.net") { problems.append("bcc of \(m.subject): \(m.displayBcc)") }
        }
        XCTAssertTrue(problems.isEmpty, problems.prefix(8).joined(separator: "\n"))
        // Folders: Inbox holds every fifth message, the export folder the rest.
        let inInbox = read.filter { $0.folderPath.hasSuffix("Inbox") }.count
        XCTAssertEqual(inInbox, n / 5)
        // Like Outlook, every message carries both a recipient table (0x692) and an
        // attachment table (0x671), empty or not; libpff rejects one without the other.
        let messageNodes = spec.nodes.values.filter { $0.nid & 0x1F == 0x04 }
        XCTAssertEqual(messageNodes.count, n)
        let incomplete = messageNodes.filter { node in
            let subs = spec.subnodes(node.subBid)
            return subs[0x692] == nil || subs[0x671] == nil
        }
        XCTAssertEqual(incomplete.count, 0, "messages missing a recipient or attachment table")
        // [MS-PST] 2.7.1 "Mandatory Nodes": a PST without any of these is invalid, and
        // Outlook refuses it (2026-10-14: the spam search folder 0x2223 was missing).
        let mandatory: [UInt32] = [0x21, 0x61, 0x122, 0x12D, 0x12E, 0x12F, 0x1E1, 0x201, 0x60D, 0x60E, 0x60F, 0x610,
                                   0x692, 0x671, 0x2223, 0x8022, 0x802D, 0x802E, 0x802F, 0x8042, 0x804D, 0x804E, 0x804F,
                                   0x8062, 0x806D, 0x806E, 0x806F]
        let missing = mandatory.filter { spec.nodes[$0] == nil }
        XCTAssertEqual(missing.map { String($0, radix: 16) }, [], "mandatory nodes missing")
        XCTAssertEqual(spec.nodes[0x2223]?.parent, 0x122, "the spam search folder belongs to the root folder")
        // [MS-PST] 2.4.5.1.1: properties every Message object PC must carry — except
        // PidTagMessageStatus, which Outlook computes and never stores on the message
        // (2.5.2.3; checked on Outlook-written files): it lives in the contents row.
        let requiredMessageProps: [UInt16] = [0x001A, 0x0E07, 0x0E08, 0x3007, 0x3008, 0x300B]
        let lacking = messageNodes.prefix(50).filter { node in
            let props = spec.propertyContext(dataBid: node.dataBid, subBid: node.subBid)
            return requiredMessageProps.contains { props[$0] == nil }
        }
        XCTAssertEqual(lacking.count, 0, "messages missing a required property")
        // Contents rows agree with their messages the way Outlook's do (SCANPST,
        // 2026-10-14: "row doesn't match sub-object" on every row). The repaired v5 file
        // showed Microsoft's corrections: PidTagMessageSize = the message node's data-block
        // bytes, and DisplayCc / DisplayBcc stored (DisplayCc also in the row) when present.
        var versions = Set<Int64>()
        var rowProblems: [String] = []
        for folder in [0x8082, 0x80A2] as [UInt32] {
            guard let node = spec.nodes[(folder >> 5) << 5 | 0x0E] else { XCTFail("contents table of \(folder)"); continue }
            for row in spec.table(dataBid: node.dataBid, subBid: node.subBid) {
                for tag: UInt32 in [0x0057_000B, 0x0058_000B] where row.values[tag] != nil {
                    rowProblems.append("row \(String(row.rowID, radix: 16)) carries \(String(tag, radix: 16))")
                }
                if let v = row.values[0x67F3_0003]?.int { versions.insert(v) }
                guard let msg = spec.nodes[row.rowID] else { rowProblems.append("row \(row.rowID) without message"); continue }
                let props = spec.propertyContext(dataBid: msg.dataBid, subBid: msg.subBid)
                let size = Self.dataBlockBytes(spec, msg.dataBid, msg.subBid)
                if props[0x0E08]?.int != Int64(size) { rowProblems.append("message \(String(row.rowID, radix: 16)) size \(props[0x0E08]?.int ?? -1), data bytes \(size)") }
                if row.values[0x0E08_0003]?.int != Int64(size) { rowProblems.append("row \(String(row.rowID, radix: 16)) size ≠ \(size)") }
                if row.values[0x0E03_001F]?.string != props[0x0E03]?.string { rowProblems.append("row \(String(row.rowID, radix: 16)) DisplayCc ≠ message") }
                let ccNames = (props[0x0E03]?.string).map { [$0] } ?? []
                let subject = props[0x0037]?.string ?? ""
                if let i = Int(subject.split(separator: " ").dropFirst().first ?? "") {
                    XCTAssertEqual(ccNames, i % 3 == 0 ? ["Cara"] : [], "DisplayCc of \(subject)")
                    XCTAssertEqual(props[0x0E02]?.string, i % 7 == 0 ? "hidden@example.net" : nil, "DisplayBcc of \(subject)")
                }
            }
        }
        XCTAssertTrue(rowProblems.isEmpty, rowProblems.prefix(8).joined(separator: "\n"))
        XCTAssertEqual(versions.count, n, "every row has its own non-zero row version")
        XCTAssertFalse(versions.contains(0))
        // SCANPST on the v3 file (2026-10-14): the templates Outlook writes, recipient row IDs
        // non-zero, every block but the last of a heap full.
        for template: UInt32 in [0x62B, 0x64C, 0x6D7, 0x6F8] { XCTAssertNotNil(spec.nodes[template], "template \(String(template, radix: 16))") }
        // SCANPST on the v4 file: the search activity list names the spam folder, the receive
        // folder table maps the default class, the LTP high-water mark is past every LTP NID.
        let sal = spec.nodes[0x201].map { spec.dataBlocks($0.dataBid).flatMap { $0 } } ?? []
        XCTAssertEqual(Array(sal.prefix(4)), [0x23, 0x22, 0x00, 0x00], "search activity list")
        // SCANPST on v6: "Deleting SDO" (its repair removed the empty 0x261) and "HMP not found –
        // creating" (its repair added 0xC01). No SDO; the HMP byte for byte as Outlook 2010 writes it.
        XCTAssertNil(spec.nodes[0x261], "no search domain object: no criteria reference a folder")
        // SCANPST on v7: "Search folder (nid=EC1) missing update queue"; its correction, an empty
        // 0xEC1, made the diagnostic file draw no finding.
        XCTAssertNotNil(spec.nodes[0xEC1], "search update queue 0xEC1")
        XCTAssertEqual(spec.nodes[0xEC1]?.dataBid, 0, "empty: nothing pending")
        // SCANPST on the v7 diagnostic: "only minor inconsistencies" — its optional repair gave the
        // store PidTagReplVersionhistory, every folder and message row ReplItemid / ReplChangenum /
        // ReplVersionhistory, and the HMP one ReplItemid → NID record per row.
        let replProblems = Self.replicationProblems(spec, expectedRows: n + 5)
        XCTAssertTrue(replProblems.isEmpty, replProblems.prefix(8).joined(separator: "\n"))
        let receive = spec.nodes[0x62B].map { spec.table(dataBid: $0.dataBid, subBid: $0.subBid) } ?? []
        XCTAssertEqual(receive.map { $0.values[0x001A_001F]?.string ?? "-" }, ["", "IPM", "Report.IPM", "IPC"])
        let rgnidLTP = bytes.subdata(in: (44 + 4 * 31)..<(48 + 4 * 31)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertGreaterThan(rgnidLTP, 0x400, "rgnid[NID_TYPE_LTP] past the subnode NIDs in use")
        XCTAssertNil(spec.propertyContext(dataBid: messageNodes[0].dataBid, subBid: messageNodes[0].subBid)[0x0E17], "status not stored on the message")
        for node in messageNodes.prefix(50) {
            guard let rt = spec.subnodes(node.subBid)[0x692] else { continue }
            let ids = spec.table(dataBid: rt.0, subBid: rt.1).map(\.rowID)
            XCTAssertFalse(ids.contains(0), "recipient row id 0")
            XCTAssertEqual(ids, ids.sorted())
        }
        for folder in [0x808E, 0x80AE] as [UInt32] {
            guard let node = spec.nodes[folder] else { continue }
            let sizes = spec.dataBlocks(node.dataBid).map(\.count)
            XCTAssertTrue(sizes.dropLast().allSatisfy { $0 == 8176 }, "heap of \(String(folder, radix: 16)): \(sizes)")
        }
        let spamProps = spec.propertyContext(dataBid: spec.nodes[0x2223]?.dataBid ?? 0, subBid: 0)
        if case .string(let name)? = spamProps[0x3001] { XCTAssertEqual(name, "SPAM Search Folder 2") } else { XCTFail("spam folder name") }
        // Keep a copy for the external readers.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: "/tmp/mailin-spec-1k.pst"))
        try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: "/tmp/mailin-spec-1k.pst"))
        // Diagnostic twin for a SCANPST run (never what the app writes): plus the empty 0xEC1
        // SCANPST's v6 repair added for "Search folder (nid=EC1) missing update queue".
        if let out = ProcessInfo.processInfo.environment["MAILIN_PST_FIXTURE_DIR"] {
            let diag = try writeFixture(n, name: "spec-ec1.pst", diagnosticEmptyNodes: [0xEC1])
            XCTAssertNotNil(try PSTSpecReader(data: Data(contentsOf: diag)).nodes[0xEC1])
            let target = URL(fileURLWithPath: out).appendingPathComponent("diagnostic-ec1.pst")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: diag, to: target)
        }
    }

    /// Bytes of a node's data blocks — its data tree and every subnode's, nested ones too;
    /// XBLOCK/SLBLOCK bytes not counted. What SCANPST recomputes PidTagMessageSize as.
    static func dataBlockBytes(_ spec: PSTSpecReader, _ dataBid: UInt64, _ subBid: UInt64) -> Int {
        spec.dataBlocks(dataBid).reduce(0) { $0 + $1.count }
            + spec.subnodes(subBid).values.reduce(0) { $0 + dataBlockBytes(spec, $1.0, $1.1) }
    }

    // MARK: Fixture set (each feature on its own, for Windows/SCANPST and independent decoders)

    /// rgnid[t] = max(starting value, highest nidIndex of type t in use), computed from the
    /// file itself: every top-level node and every subnode.
    static func expectedRGNID(_ spec: PSTSpecReader) -> [UInt32] {
        var used = [UInt32](repeating: 0, count: 32)
        func note(_ nid: UInt32) { used[Int(nid & 0x1F)] = max(used[Int(nid & 0x1F)], nid >> 5) }
        for node in spec.nodes.values {
            note(node.nid)
            for sub in spec.subnodes(node.subBid).keys { note(sub) }
        }
        return (0..<32).map { max(PSTSpecWriter.rgnidStart($0), used[$0]) }
    }

    static func variant(_ i: Int, to: [String] = ["Ann <ann@example.org>"], cc: [String] = [], bcc: [String] = [],
                        subject: String? = nil, body: String? = nil, html: String = "",
                        attachments: [(String, Int)] = []) -> MBOXParser.RawEmail {
        var headers = ["From": "Sender \(i) <s\(i)@example.com>", "To": to.joined(separator: ", "),
                       "Subject": subject ?? "Message \(i)", "Message-ID": "<v\(i)@example.com>",
                       "Date": "Tue, 7 Jan 2025 09:\(String(format: "%02d", i % 60)):00 +0000"]
        if !cc.isEmpty { headers["Cc"] = cc.joined(separator: ", ") }
        if !bcc.isEmpty { headers["Bcc"] = bcc.joined(separator: ", ") }
        let text = body ?? "Body of message \(i)."
        let atts = attachments.map { name, size -> AttachmentMetadata in
            let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i) })
            return AttachmentMetadata(filename: name, mimeType: "application/octet-stream", size: size, base64: bytes.base64EncodedString())
        }
        return MBOXParser.RawEmail(headers: headers, rawSource: "", messageType: "email", attachments: atts,
                                   timestamp: "2025-01-07T09:\(String(format: "%02d", i % 60)):00Z", domains: ["example.com"],
                                   plainBody: text, htmlBody: html)
    }

    func testFixtureSet_eachFeatureWritesAValidStore() throws {
        let unicode = "Résumé — naïve façade ✓ Ελληνικά 日本語 עברית 🙂"
        let cases: [(String, [MBOXParser.RawEmail])] = [
            ("01-empty-store", []),
            ("02-one-plain-message", [Self.variant(1)]),
            ("03-recipients-to-cc-bcc", [Self.variant(2, to: ["Ann <ann@example.org>", "bob@example.org", "Chloé Durand <chloe@example.fr>"],
                                                       cc: ["Cara <cara@example.net>", "dan@example.net"], bcc: ["hidden@example.net", "Eve <eve@example.com>"])]),
            ("04-html-and-unicode", [Self.variant(3, subject: unicode, body: unicode + "\nSecond line.", html: "<p>\(unicode)</p>")]),
            ("05-attachments-small-and-multiblock", [Self.variant(4, attachments: [("small.txt", 40), ("two-blocks.bin", 12_000), ("many-blocks.bin", 300_000)])]),
            ("06-crosses-table-and-heap-blocks", (0..<300).map { Self.variant(100 + $0, subject: "Boundary \($0) " + String(repeating: "x", count: 60)) }),
        ]
        let outDir = ProcessInfo.processInfo.environment["MAILIN_PST_FIXTURE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        for (name, emails) in cases {
            let url = dir.appendingPathComponent("\(name).pst")
            let w = try PSTSpecWriter(url: url)
            for e in emails { try w.appendMessage(e) }
            XCTAssertEqual(try w.finalize(), emails.count, name)
            let bytes = try Data(contentsOf: url)
            let spec = try PSTSpecReader(data: bytes)
            // Header high-water marks equal what the file allocates (per type, start-clamped).
            let header = (0..<32).map { t in bytes.subdata(in: (44 + 4 * t)..<(48 + 4 * t)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
            XCTAssertEqual(header, Self.expectedRGNID(spec), "\(name): rgnid")
            // Replication state: 4 folder rows (Top of Personal Folders, Search Root, Deleted Items,
            // mailin export) plus one row per message, each in the HMP.
            XCTAssertEqual(Self.replicationProblems(spec, expectedRows: emails.count + 4), [], name)
            // Read back: subjects, bodies, recipients, attachment bytes.
            let read = spec.messages()
            XCTAssertEqual(read.count, emails.count, name)
            for e in emails {
                guard let m = read.first(where: { $0.internetMessageId == e.headers["Message-ID"] }) else { XCTFail("\(name): missing \(e.headers["Message-ID"]!)"); continue }
                XCTAssertEqual(m.subject, e.headers["Subject"], name)
                XCTAssertEqual(m.bodyText, e.plainBody, name)
                for cc in PSTSpecWriter.addresses(e.headers["Cc"]) { XCTAssertTrue(m.displayCc.contains(cc.email), "\(name): cc \(cc.email)") }
                for bcc in PSTSpecWriter.addresses(e.headers["Bcc"]) { XCTAssertTrue(m.displayBcc.contains(bcc.email), "\(name): bcc \(bcc.email)") }
                XCTAssertEqual(m.attachments.map { Data(base64Encoded: $0.base64 ?? "", options: .ignoreUnknownCharacters) },
                               e.attachments.map { Data(base64Encoded: $0.base64 ?? "") }, "\(name): attachment bytes")
            }
            if let outDir {
                try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                let dest = outDir.appendingPathComponent("\(name).pst")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
            }
        }
    }
}
