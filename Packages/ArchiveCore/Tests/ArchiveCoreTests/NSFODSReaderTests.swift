//
//  NSFODSReaderTests.swift
//  ArchiveCoreTests
//
//  GAP-NSF: the Notes ODS reader on the exact public sample
//  (opensource/aspose-email-net/SampleNSF.nsf, 47,448,064 bytes, MIT, SHA-256
//  in the pack's SHA256SUMS — `ExternalFixtures` verifies it; XCTSkip when the
//  pack is absent) and on synthetic inputs for the parts the sample does not
//  exercise.
//
//  No Notes client exists on this Mac, so every number is checked against
//  something the reader does not compute itself:
//   • bucket count  — the bucket signature (02 42) at 256-byte-aligned file
//     offsets, found by a plain byte scan, against the superblock's table;
//   • note census   — every RRV entry is accounted for exactly once
//     (records + objects + unresolved = entries; classes + stubs + empty +
//     other documents + mail = records);
//   • headers       — each message's From / Message-ID / Subject line is
//     searched for verbatim in the raw database bytes;
//   • dates         — the TIMEDATE stored beside each Date header (the
//     RFC822 item's native value) against the Date text itself;
//   • attachments   — file magic and trailer of the decoded bytes, and the
//     bytes found verbatim in the database.
//  The sample is itself damaged in a dozen single bytes (e.g. "Aspo{e.Cells",
//  "ne~sletter", "Wed, 3!Oct 2018", a 0x0E where a CR belongs); the reader
//  reproduces those bytes, and the tests below name the ones they meet.
//

import XCTest
@testable import ArchiveCore

final class NSFODSReaderTests: XCTestCase {
    static let fixtures = ExternalFixtures.shared
    static let asposeNSF = "opensource/aspose-email-net/SampleNSF.nsf"

    override func tearDown() {
        NotesODSPolicy.isEnabled = false
        super.tearDown()
    }

    private func sample() throws -> (URL, Data, NSFODSParser.Result) {
        let url = try Self.fixtures.require(Self.asposeNSF)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return (url, data, try NSFODSParser.read(fileURL: url, senderEmail: ""))
    }

    // MARK: - Real sample

    func testSampleNSF_everyRRVEntryAccountedFor_45MailNotesOf1412NoteRecords() throws {
        let (_, data, result) = try sample()
        let inv = result.inventory
        XCTAssertEqual(inv.odsVersion, 43, "ODS 43 = Notes 6/7/8 on-disk structure")
        XCTAssertEqual(inv.rrvBuckets, 4)

        // Census: every entry once.
        XCTAssertEqual(inv.rrvEntries, 1626)
        XCTAssertEqual(inv.noteRecords, 1412)
        XCTAssertEqual(inv.objects, 203)
        XCTAssertEqual(inv.unresolvedEntries.count, 11, "entries whose slot carries another note ID: \(inv.unresolvedEntries)")
        XCTAssertEqual(inv.noteRecords + inv.objects + inv.unresolvedEntries.count, inv.rrvEntries)
        XCTAssertEqual(inv.designNotes, 1030)
        XCTAssertEqual(inv.designNotesByClass[0x0004], 788, "forms, subforms, pages, images, script libraries")
        XCTAssertEqual(inv.designNotesByClass[0x0200], 131, "agents / filters")
        XCTAssertEqual(inv.designNotesByClass[0x0008], 94, "views and folders")
        XCTAssertEqual(inv.designNotesByClass[0x0400], 10, "shared fields")
        XCTAssertEqual(inv.deletionStubs, 323)
        XCTAssertEqual(inv.emptyDocuments, 3)
        XCTAssertEqual(inv.otherDocumentsByForm, ["": 9, "CalendarProfile": 1, "iNotesProfile": 1])
        XCTAssertEqual(inv.unplacedDocuments, [])
        XCTAssertEqual(inv.designNotes + inv.deletionStubs + inv.emptyDocuments + inv.otherDocuments
                       + inv.unplacedDocuments.count + inv.mailNotes, inv.noteRecords)

        XCTAssertEqual(inv.mailNotes, 45)
        XCTAssertEqual(inv.mailRead, 45)
        XCTAssertEqual(inv.mailFailed, [:])
        XCTAssertEqual(inv.nativeMIMEMail, 45)
        XCTAssertEqual(inv.richTextMail, 0, "the sample has no Notes rich-text mail")
        XCTAssertEqual(inv.attachmentObjectsDecoded, 42)
        XCTAssertEqual(inv.attachmentObjectsNotDecoded, 0)
        XCTAssertEqual(result.emails.count, 45)

        // Independent: bucket signatures by byte scan vs the superblock's table.
        let reader = try NSFODSReader(data: data)
        var scanned = 0
        var offset = 0
        while offset + 2 <= data.count {
            if data[offset] == 0x02 && data[offset + 1] == 0x42 { scanned += 1 }
            offset += 256
        }
        XCTAssertEqual(scanned, 76)
        XCTAssertEqual(reader.summaryBucketCount, scanned)
    }

    func testSampleNSF_sendersMessageIDsSubjectsAreTheDatabaseBytes() throws {
        let (_, data, result) = try sample()
        func line(_ name: String, in raw: String) -> Data? {
            let body = raw.hasPrefix("From MAILER-DAEMON") ? String(raw.drop(while: { $0 != "\n" }).dropFirst()) : raw
            for l in body.components(separatedBy: "\r\n") {
                if l.isEmpty { break }
                if l.hasPrefix(name + ": ") { return l.data(using: .isoLatin1) }
            }
            return nil
        }
        var fromFound = 0, idFound = 0, subjectFound = 0
        var subjectMisses: [String] = []
        var ids = Set<String>()
        for email in result.emails {
            let id = email.headers["X-Notes-NoteID"] ?? "?"
            if let l = line("From", in: email.rawSource), data.range(of: l + Data("\r\n".utf8)) != nil { fromFound += 1 }
            if let l = line("Message-ID", in: email.rawSource), data.range(of: l) != nil { idFound += 1 }
            if let mid = email.headers["Message-ID"] { ids.insert(mid) }
            if let l = line("Subject", in: email.rawSource), data.range(of: l + Data("\r\n".utf8)) != nil { subjectFound += 1 } else { subjectMisses.append(id) }
        }
        XCTAssertEqual(fromFound, 45)
        XCTAssertEqual(idFound, 45)
        XCTAssertEqual(ids.count, 45, "45 distinct Message-IDs")
        XCTAssertEqual(subjectFound, 45)
        XCTAssertEqual(subjectMisses, [])
        // 0x1522's folded Subject keeps the database's 0x0E where a CR belongs.
        XCTAssertNotNil(data.range(of: Data("Code_Example?=".utf8) + Data([0x0E, 0x0A])))
        XCTAssertTrue(byIDRaw(result, "0x1522")?.contains("Code_Example?=\u{0E}\n") ?? false)

        let byID = Dictionary(uniqueKeysWithValues: result.emails.map { ($0.headers["X-Notes-NoteID"] ?? "", $0) })
        XCTAssertEqual(byID["0x1126"]?.headers["Subject"], "Introducing the Improved Aspose.Tasks for Java and Other+News from Aspose, April 2015")
        XCTAssertEqual(byID["0x1126"]?.headers["From"], "campaign <campaign@banckle.com>")
        XCTAssertEqual(byID["0x1126"]?.headers["Message-ID"], "<B4955F9308760247847A8A2006609C73471A80@exchange.aspose.com>")
        XCTAssertEqual(byID["0x165A"]?.headers["From"], "Aspose.Com Newsletter <newsletter@aspose.com>")
        XCTAssertEqual(byID["0x14C6"]?.headers["Subject"], "[Register Now] Value Stream Management with Guest Speaker")
        // Damaged-in-the-file bytes come through as stored, not "corrected".
        XCTAssertEqual(byID["0x1156"]?.headers["Subject"], "Spotlight on Aspo{e.Cells and News from Aspose, May 2015")
        let recipients = result.emails.map { $0.headers["To"] ?? "" }
        XCTAssertEqual(recipients.filter { $0.contains("sdmit@km.ru") }.count, 42)
        // The other three To lines are damaged in the file itself (one byte each).
        XCTAssertEqual(recipients.filter { !$0.contains("sdmit@km.ru") }.sorted(), ["<sdmit@jm.ru>", "<sdmit@km.rr>", "<sdmit@km.rr>"])
        XCTAssertNotNil(data.range(of: Data("To: <sdmit@jm.ru>\r\n".utf8)))
        // A damaged length word is named on the message, the line kept.
        XCTAssertTrue(byID["0x15DA"]?.anomalies.contains { $0.contains("$MessageID has inconsistent lengths") } ?? false)
        XCTAssertEqual(byID["0x15DA"]?.headers["Message-ID"], "<41e8ae20bbc5fbe335e613a5af2ee441@newsletter.aspose.com>")
    }

    func testSampleNSF_datesAgreeWithTheTIMEDATEStoredBesideThem() throws {
        let (url, _, _) = try sample()
        let reader = try NSFODSReader(data: try Data(contentsOf: url, options: .mappedIfSafe))
        var cursor = NSFODSReader.Cursor()
        var agree = 0
        var disagree: [String] = []
        var earliest = Date.distantFuture, latest = Date.distantPast
        while let record = reader.next(&cursor) {
            guard case .note(let note) = record, NSFODSParser.isMail(note), let posted = note.first("PostedDate") else { continue }
            guard posted.type == 0x0502, let (native, line) = NotesValue.rfc822(posted.value),
                  let text = String(data: line, encoding: .isoLatin1)?.replacingOccurrences(of: "Date: ", with: "") else {
                XCTFail("PostedDate of 0x\(String(note.id, radix: 16)) is not an RFC822 item"); continue
            }
            let stored = NotesValue.date(native)
            let written = MBOXParser.parseDate(text.trimmingCharacters(in: .whitespacesAndNewlines))
            if let s = stored, let w = written, abs(s.timeIntervalSince(w)) < 1 {
                agree += 1
                earliest = min(earliest, s); latest = max(latest, s)
            } else {
                disagree.append(String(format: "0x%X", note.id))
                if let s = stored, let w = written {
                    // Same time of day: only the day field differs.
                    let a = Int(s.timeIntervalSince1970) % 86_400, b = Int(w.timeIntervalSince1970) % 86_400
                    XCTAssertEqual(a, b, "time of day of 0x\(String(note.id, radix: 16))")
                }
            }
        }
        // 0x1656's text is "Wed, 3!Oct 2018 …" (damaged in the file) and does not
        // parse; 0x11B2's stored day field is damaged (year 2912), its time agrees.
        XCTAssertEqual(agree, 43)
        XCTAssertEqual(disagree, ["0x11B2", "0x1656"])
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(iso.string(from: earliest), "2015-04-03T01:50:03Z")
        XCTAssertEqual(iso.string(from: latest), "2018-11-02T12:06:09Z")
    }

    func testSampleNSF_htmlBodiesFromAttachmentObjects_andTheOneInlineImage() throws {
        let (_, data, result) = try sample()
        XCTAssertEqual(result.emails.filter { !$0.htmlBody.isEmpty }.count, 45)
        XCTAssertEqual(result.emails.filter { $0.htmlBody.range(of: "<html", options: .caseInsensitive) != nil }.count, 45)
        XCTAssertEqual(result.emails.filter { !$0.plainBody.isEmpty }.count, 33, "12 messages carry HTML only")
        let attachments = result.emails.flatMap { e in e.attachments.map { (e.headers["X-Notes-NoteID"] ?? "", $0) } }
        XCTAssertEqual(attachments.count, 1)
        guard let (owner, png) = attachments.first,
              let bytes = png.base64.flatMap({ Data(base64Encoded: $0) }) ?? png.fileURL.flatMap({ try? Data(contentsOf: $0) }) else {
            return XCTFail("no attachment bytes")
        }
        XCTAssertEqual(owner, "0x1126")
        XCTAssertEqual(png.filename, "048df8f5-315c-4e2e-b9fd-fea8a1c3fe2a")
        XCTAssertEqual(bytes.count, 7655)
        XCTAssertEqual(Array(bytes.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG signature (declared image/jpeg)")
        XCTAssertEqual(Array(bytes.suffix(8)), [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82], "IEND chunk")
        XCTAssertNotNil(data.range(of: bytes), "the decoded bytes are the database bytes")
    }

    func testSampleNSF_seam_switchOffIsTheOldParser_switchOnStreamsTheSame45() async throws {
        let url = try Self.fixtures.require(Self.asposeNSF)
        NotesODSPolicy.isEnabled = false
        XCTAssertEqual(ParserFactory.parserIdentity(forExtension: "nsf").name, "nsf")
        XCTAssertEqual(try ParserFactory.parse(fileURL: url, senderEmail: "").count, 0, "old heuristic, unchanged")

        NotesODSPolicy.isEnabled = true
        XCTAssertEqual(ParserFactory.parserIdentity(forExtension: "nsf").name, "nsf-ods")
        let array = try ParserFactory.parse(fileURL: url, senderEmail: "")
        XCTAssertEqual(array.count, 45)
        var streamed: [MBOXParser.RawEmail] = []
        let report = try await ParserFactory.parseStreamingCallback(fileURL: url, senderEmail: "", batchSize: 7,
                                                                    materializeAttachments: false) { streamed += $0 }
        XCTAssertEqual(report.totalMessages, 45)
        XCTAssertEqual(report.successfullyParsed, 45)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(streamed.map { $0.headers["Message-ID"] ?? "" }, array.map { $0.headers["Message-ID"] ?? "" })
        XCTAssertTrue(streamed.allSatisfy { $0.headers["X-Source-Format"] == "NSF" })
    }

    private func byIDRaw(_ result: NSFODSParser.Result, _ id: String) -> String? {
        result.emails.first { $0.headers["X-Notes-NoteID"] == id }?.rawSource
    }

    // MARK: - Synthetic (what the sample cannot show)

    /// Literal 'a', literal 'b', then a 2-byte back reference at distance 2.
    func testCX_literalsAndBackReference() throws {
        var bits: [Int] = []
        func put(_ value: Int, _ width: Int) { for i in 0..<width { bits.append((value >> i) & 1) } }
        put(0, 1); put(Int(UInt8(ascii: "a")), 8)
        put(0, 1); put(Int(UInt8(ascii: "b")), 8)
        put(1, 1); put(1, 1); put(2, 8)
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = 0x04                                 // low 3 bits > 3: stream starts at bit 3
        for (i, b) in bits.enumerated() where b == 1 {
            let at = i + 3
            bytes[at / 8] |= UInt8(1 << (at % 8))
        }
        let used = (bits.count + 3 + 7) / 8
        XCTAssertEqual(try NotesCX.decompress(Data(bytes.prefix(used)), limit: 64), Data("abab".utf8))
        XCTAssertThrowsError(try NotesCX.decompress(Data([0x01, 0x00]), limit: 64), "a stream whose start bits are <= 3 is refused")
    }

    /// The C API's own example: 2:49:04 PM EST, 10 December 1996.
    func testTIMEDATE_CAPIExample() {
        var v = Data()
        withUnsafeBytes(of: UInt32(0x006C_DCC0).littleEndian) { v.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0x8525_63FC).littleEndian) { v.append(contentsOf: $0) }
        XCTAssertEqual(NotesValue.date(v).map { ISO8601DateFormatter().string(from: $0) }, "1996-12-10T19:49:04Z")
        var allDay = Data(repeating: 0xFF, count: 4)
        withUnsafeBytes(of: UInt32(0x8525_63FC).littleEndian) { allDay.append(contentsOf: $0) }
        XCTAssertNil(NotesValue.date(allDay), "ALLDAY has no instant")
    }

    /// CDTEXT runs and paragraph breaks; other records skipped.
    func testRichText_textRunsAndParagraphs() {
        func text(_ s: String) -> Data {
            let t = Data(s.utf8)
            var d = Data([0x85, 0xFF])
            let len = 8 + t.count
            withUnsafeBytes(of: UInt16(len).littleEndian) { d.append(contentsOf: $0) }
            d.append(Data(repeating: 0, count: 4))     // FONTID
            d.append(t)
            if len % 2 == 1 { d.append(0) }
            return d
        }
        var cd = Data([0x81, 0x02])                    // CDPARAGRAPH (BSIG, 2 bytes)
        cd.append(text("Hello"))
        cd.append(Data([0x81, 0x02]))
        cd.append(Data([0x86, 0xFF, 0x06, 0x00, 0x00, 0x00]))   // some other WSIG record
        cd.append(text("World"))
        XCTAssertEqual(NotesRichText.plainText(cd), "\nHello\nWorld")
    }

    func testLMBCS_asciiGroup1AndUnicodeGroup() {
        XCTAssertEqual(LMBCS.decode(Data("Memo".utf8)), "Memo")
        XCTAssertEqual(LMBCS.decode(Data([0x43, 0x61, 0x66, 0x82])), "Café", "unprefixed high byte: code page 850")
        XCTAssertEqual(LMBCS.decode(Data([0x41, 0x14, 0x04, 0x14])), "AД", "group 0x14: UCS-2 big-endian")
    }
}
