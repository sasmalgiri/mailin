//
//  ExportReconciliationTests.swift
//  ArchiveCoreTests
//
//  OUT-04 / COMP-16, completion directive §2 "Strengthen export
//  reconciliation": the "content checked" statement on an export receipt can
//  never turn an incomplete comparison into a pass. Each required behaviour
//  has its own test; every message is built with
//  `MBOXParser.processRawMessage` so the record's headers and its raw source
//  agree (the only way a round trip can be judged).
//

import XCTest
import Foundation
@testable import ArchiveCore

final class ExportReconciliationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("reconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    // MARK: - Builders

    struct Part { let name: String; let bytes: Data; var cid: String? = nil; var mime = "application/octet-stream" }

    /// A raw RFC 5322 message whose headers and body agree with its source text.
    static func raw(subject: String = "Quarterly Figures", from: String = "Ann <ann@x.com>", to: String = "bob@y.org",
                    cc: String? = nil, bcc: String? = nil, date: String = "Wed, 15 Jan 2025 10:00:30 +0000",
                    messageID: String = "<m1@t>", inReplyTo: String? = nil, references: String? = nil,
                    plain: String = "Line one.\nLine two.", html: String? = nil, parts: [Part] = []) -> String {
        var text = "From: \(from)\r\nTo: \(to)\r\n"
        if let cc { text += "Cc: \(cc)\r\n" }
        if let bcc { text += "Bcc: \(bcc)\r\n" }
        text += "Subject: \(subject)\r\nDate: \(date)\r\nMessage-ID: \(messageID)\r\n"
        if let inReplyTo { text += "In-Reply-To: \(inReplyTo)\r\n" }
        if let references { text += "References: \(references)\r\n" }
        text += "MIME-Version: 1.0\r\n"
        func textParts() -> String {
            if let html {
                return "Content-Type: multipart/alternative; boundary=\"ALT\"\r\n\r\n--ALT\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(plain)\r\n--ALT\r\nContent-Type: text/html; charset=utf-8\r\n\r\n\(html)\r\n--ALT--\r\n"
            }
            return "Content-Type: text/plain; charset=utf-8\r\n\r\n\(plain)\r\n"
        }
        if parts.isEmpty {
            text += textParts()
        } else {
            text += "Content-Type: multipart/mixed; boundary=\"MIX\"\r\n\r\n--MIX\r\n" + textParts()
            for part in parts {
                text += "--MIX\r\nContent-Type: \(part.mime); name=\"\(part.name)\"\r\nContent-Transfer-Encoding: base64\r\n"
                if let cid = part.cid { text += "Content-ID: <\(cid)>\r\nContent-Disposition: inline; filename=\"\(part.name)\"\r\n" }
                else { text += "Content-Disposition: attachment; filename=\"\(part.name)\"\r\n" }
                text += "\r\n\(part.bytes.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn]))\r\n"
            }
            text += "--MIX--\r\n"
        }
        return text
    }

    static func message(_ raw: String) throws -> MBOXParser.RawEmail {
        try MBOXParser.processRawMessage(raw, senderEmail: "")
    }

    /// Writes per-message files and the inventory that ties them to records.
    @discardableResult
    func writeFolder(_ files: [(name: String, data: Data, emailID: UUID?, folder: String?)], written: Int? = nil) throws -> URL {
        let folder = dir.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var entries: [ExportInventory.File] = []
        for file in files {
            let url = folder.appendingPathComponent(file.name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
            entries.append(ExportInventory.File(path: file.name, bytes: file.data.count, sha256: try ExportInventory.sha256(of: url),
                                                emailID: file.emailID?.uuidString, messageID: nil, originalFolder: file.folder, existing: nil))
        }
        let inventory = ExportInventory(createdAt: Date(), layout: "flat", written: written ?? files.count, withheld: 0, skipped: 0,
                                        positionsConsumed: files.count, files: entries)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(inventory).write(to: folder.appendingPathComponent(ExportInventory.filename))
        return folder
    }

    /// A lookup over an in-memory set of records that pages like the store would.
    final class Pages: @unchecked Sendable {
        var calls: [[UUID]] = []
        var hydrations: [UUID] = []
        let lock = NSLock()
        func record(_ ids: [UUID]) { lock.lock(); calls.append(ids); lock.unlock() }
        func hydrated(_ id: UUID) { lock.lock(); hydrations.append(id); lock.unlock() }
    }

    func lookup(_ records: [MBOXParser.RawEmail], pages: Pages = Pages(),
                hydrate: (@Sendable (UUID) async throws -> MBOXParser.RawEmail?)? = nil) -> ExportReconciliation.SourceLookup {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let byMID = Dictionary(records.compactMap { email in email.headers["Message-ID"].map { (ExportReconciliation.identifier($0), email) } },
                               uniquingKeysWith: { a, _ in a })
        return ExportReconciliation.SourceLookup(
            records: { ids in pages.record(ids); return byID.filter { ids.contains($0.key) } },
            recordsByMessageID: { mids in byMID.filter { mids.contains($0.key) } },
            hydrate: hydrate)
    }

    func outcome(_ item: ExportReconciliation.Item, _ field: ExportReconciliation.Field) -> ExportReconciliation.FieldOutcome? {
        item.fields.first { $0.field == field }?.outcome
    }

    func emlFolderReport(output: String, source: MBOXParser.RawEmail, folder: String? = nil) async throws -> ExportReconciliation.ContentReport {
        let folderURL = try writeFolder([("m.eml", Data(output.utf8), source.id, folder)])
        return await ExportReconciliation.reconcile(folder: folderURL, lookup: lookup([source]))
    }

    // MARK: - 2. Deliberate field loss in .eml output, each named

    func testSubjectLoss_isNamedAndCaseIsMeaningful() async throws {
        let source = try Self.message(Self.raw(subject: "Quarterly Figures"))
        let report = try await emlFolderReport(output: Self.raw(subject: "quarterly figures"), source: source)
        XCTAssertEqual(report.outcome, .failed, report.summary)
        XCTAssertEqual(report.mismatched, 1); XCTAssertEqual(report.matching, 0); XCTAssertEqual(report.eligible, 1)
        XCTAssertEqual(report.findings.first?.lostFields, [.subject])
        // Trailing whitespace and folding are the only forgiven subject differences.
        let folded = try Self.message(Self.raw(subject: "Quarterly\r\n Figures  "))
        XCTAssertEqual(ExportReconciliation.compareSubject(output: folded.headers["Subject"], source: source.headers["Subject"],
                                                           rules: .rules(for: .eml)), .unchanged)
    }

    func testDateLoss_isNamed() async throws {
        let source = try Self.message(Self.raw(date: "Wed, 15 Jan 2025 10:00:30 +0000"))
        let report = try await emlFolderReport(output: Self.raw(date: "Wed, 15 Jan 2025 10:00:31 +0000"), source: source)
        XCTAssertEqual(report.outcome, .failed, report.summary)
        XCTAssertEqual(report.findings.first?.lostFields, [.date])
        // A missing Date header is a loss, never "no date to compare".
        let removed = Self.raw().replacingOccurrences(of: "Date: Wed, 15 Jan 2025 10:00:30 +0000\r\n", with: "")
        let gone = try await emlFolderReport(output: removed, source: source)
        XCTAssertEqual(gone.findings.first?.lostFields, [.date])
        XCTAssertEqual(outcome(gone.findings[0], .date), .lost("missing from output"))
    }

    func testDateComparedToTheMinute_isNamedNeverUnchanged() async throws {
        // The record carries no seconds; the output does. Same minute → named precision drop.
        let source = try Self.message(Self.raw(date: "Wed, 15 Jan 2025 10:00 +0000"))
        let report = try await emlFolderReport(output: Self.raw(date: "Wed, 15 Jan 2025 10:00:45 +0000"), source: source)
        XCTAssertEqual(report.outcome, .complete, report.summary)
        XCTAssertEqual(report.transformations, ["date compared to the minute because the record carries no seconds": 1])
        // Same instant to the second, re-expressed in another zone: named, not "unchanged".
        let same = ExportReconciliation.compareDate(output: try Self.message(Self.raw(date: "Wed, 15 Jan 2025 11:00:30 +0100")),
                                                    source: try Self.message(Self.raw()), rules: .rules(for: .eml))
        XCTAssertEqual(same, .permittedTransformation("date re-expressed (same instant to the second)"))
        // Both carry seconds and they differ: lost, even within the same minute.
        let differ = ExportReconciliation.compareDate(output: try Self.message(Self.raw(date: "Wed, 15 Jan 2025 10:00:31 +0000")),
                                                      source: try Self.message(Self.raw()), rules: .rules(for: .eml))
        XCTAssertEqual(differ, .lost("changed"))
    }

    func testRecipientLoss_isNamed() async throws {
        let source = try Self.message(Self.raw(to: "bob@y.org, Cara <cara@z.net>", cc: "dan@w.io"))
        let report = try await emlFolderReport(output: Self.raw(to: "bob@y.org", cc: "dan@w.io"), source: source)
        XCTAssertEqual(report.findings.first?.lostFields, [.to], report.summary)
        // Same addresses re-expressed (names dropped, order changed) is named, not unchanged.
        let re = try await emlFolderReport(output: Self.raw(to: "cara@z.net, bob@y.org", cc: "dan@w.io"), source: source)
        XCTAssertEqual(re.outcome, .complete, re.summary)
        XCTAssertEqual(re.transformations, ["to: same addresses, display names or order re-expressed": 1])
        // A different address of the same shape is a loss.
        let other = try await emlFolderReport(output: Self.raw(to: "bob@y.org, Cara <cara@z.net>", cc: "dana@w.io"), source: source)
        XCTAssertEqual(other.findings.first?.lostFields, [.cc])
    }

    func testBccLoss_isNamedIncludingAbsence() async throws {
        let source = try Self.message(Self.raw(bcc: "hidden@q.org"))
        let report = try await emlFolderReport(output: Self.raw(), source: source)
        XCTAssertEqual(report.outcome, .failed, report.summary)
        XCTAssertEqual(outcome(report.findings[0], .bcc), .lost("missing from output"))
        // The other way round: a Bcc the record never had is "added in output", not ignored.
        let added = try await emlFolderReport(output: Self.raw(bcc: "hidden@q.org"), source: try Self.message(Self.raw()))
        XCTAssertEqual(outcome(added.findings[0], .bcc), .lost("added in output"))
        // Both absent: sourceAbsent, and a clean item.
        let none = try await emlFolderReport(output: Self.raw(), source: try Self.message(Self.raw()))
        XCTAssertEqual(none.outcome, .complete, none.summary)
    }

    func testMessageIDAndThreadHeaders_presenceIsChecked() async throws {
        let source = try Self.message(Self.raw(messageID: "<m1@t>", inReplyTo: "<m0@t>", references: "<a@t> <m0@t>"))
        let noID = Self.raw(inReplyTo: "<m0@t>", references: "<a@t> <m0@t>").replacingOccurrences(of: "Message-ID: <m1@t>\r\n", with: "")
        let report = try await emlFolderReport(output: noID, source: source)
        XCTAssertEqual(outcome(report.findings[0], .messageID), .lost("missing from output"), report.summary)
        let reordered = try await emlFolderReport(output: Self.raw(messageID: "<m1@t>", inReplyTo: "<m0@t>", references: "<m0@t> <a@t>"), source: source)
        XCTAssertEqual(outcome(reordered.findings[0], .references), .lost("changed"))
        let same = try await emlFolderReport(output: Self.raw(messageID: " <m1@t> ", inReplyTo: "<m0@t>", references: "<a@t>  <m0@t>"), source: source)
        XCTAssertEqual(same.outcome, .complete, same.summary)
    }

    func testBodyLoss_isNamedAndRepresentationKept() async throws {
        let source = try Self.message(Self.raw(plain: "Line one.\nLine two."))
        let report = try await emlFolderReport(output: Self.raw(plain: "Line one.\nLine 2."), source: source)
        XCTAssertEqual(report.findings.first?.lostFields, [.plainBody], report.summary)
        // CRLF / LF and trailing whitespace are forgiven; case is not.
        let crlf = try await emlFolderReport(output: Self.raw(plain: "Line one.  \r\nLine two.\r\n\r\n"), source: source)
        XCTAssertEqual(crlf.outcome, .complete, crlf.summary)
        let cased = try await emlFolderReport(output: Self.raw(plain: "line one.\nLine two."), source: source)
        XCTAssertEqual(cased.findings.first?.lostFields, [.plainBody])
    }

    func testHTMLLoss_isComparedSeparatelyFromPlain() async throws {
        let source = try Self.message(Self.raw(plain: "Hello", html: "<p>Hello <b>there</b></p>"))
        let report = try await emlFolderReport(output: Self.raw(plain: "Hello", html: "<p>Hello there</p>"), source: source)
        XCTAssertEqual(report.findings.first?.lostFields, [.htmlBody], report.summary)
        // Dropping the HTML part altogether is a loss even though the plain words survive.
        let dropped = try await emlFolderReport(output: Self.raw(plain: "Hello"), source: source)
        XCTAssertEqual(outcome(dropped.findings[0], .htmlBody), .lost("missing from output"))
    }

    func testCIDLoss_isNamed() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let source = try Self.message(Self.raw(html: "<img src=\"cid:logo@x\">", parts: [Part(name: "logo.png", bytes: png, cid: "logo@x", mime: "image/png")]))
        let changed = Self.raw(html: "<img src=\"cid:logo@x\">", parts: [Part(name: "logo.png", bytes: png, cid: "other@x", mime: "image/png")])
        let report = try await emlFolderReport(output: changed, source: source)
        XCTAssertEqual(report.outcome, .failed, report.summary)
        XCTAssertTrue(report.findings[0].lostFields.contains(.attachmentContentIDs), "\(report.findings[0].fields)")
        // The same bytes written without a Content-ID in .eml output: lost, not forgiven.
        let noCID = Self.raw(html: "<img src=\"cid:logo@x\">", parts: [Part(name: "logo.png", bytes: png, mime: "image/png")])
        let gone = try await emlFolderReport(output: noCID, source: source)
        XCTAssertTrue(gone.findings[0].lostFields.contains(.attachmentContentIDs))
        XCTAssertTrue(gone.findings[0].lostFields.contains(.attachmentDispositions))
    }

    func testAttachmentLoss_isNamed() async throws {
        let a = Part(name: "a.txt", bytes: Data("alpha".utf8)), b = Part(name: "b.txt", bytes: Data("beta".utf8))
        let source = try Self.message(Self.raw(parts: [a, b]))
        let report = try await emlFolderReport(output: Self.raw(parts: [a]), source: source)
        XCTAssertEqual(report.outcome, .failed, report.summary)
        XCTAssertEqual(outcome(report.findings[0], .attachments), .lost("2 in the record, 1 in the output"))
        let renamed = try await emlFolderReport(output: Self.raw(parts: [a, Part(name: "c.txt", bytes: b.bytes)]), source: source)
        XCTAssertEqual(outcome(renamed.findings[0], .attachments), .lost("attachment names differ"))
    }

    // MARK: - 1. Attachments as occurrences

    func testSwappedPayloadsBetweenTwoFilenames_areDetected() async throws {
        let alpha = Data("alpha payload".utf8), beta = Data("beta payload".utf8)
        let source = try Self.message(Self.raw(parts: [Part(name: "a.txt", bytes: alpha), Part(name: "b.txt", bytes: beta)]))
        // Same names, same set of hashes — only the pairing changed. A Set comparison passed this.
        let swapped = Self.raw(parts: [Part(name: "a.txt", bytes: beta), Part(name: "b.txt", bytes: alpha)])
        let report = try await emlFolderReport(output: swapped, source: source)
        XCTAssertEqual(report.outcome, .failed, report.summary)
        XCTAssertEqual(outcome(report.findings[0], .attachments), .lost("same names, different bytes: a.txt, b.txt"))
    }

    func testMultiplicityChange_AAB_vs_ABB_isDetected() async throws {
        let a = Part(name: "a.txt", bytes: Data("alpha".utf8)), b = Part(name: "b.txt", bytes: Data("beta".utf8))
        let source = try Self.message(Self.raw(parts: [a, a, b]))
        let report = try await emlFolderReport(output: Self.raw(parts: [a, b, b]), source: source)
        XCTAssertEqual(report.outcome, .failed, report.summary)
        XCTAssertEqual(outcome(report.findings[0], .attachments), .lost("attachment names differ"))
        // The honest match: the same three occurrences.
        let same = try await emlFolderReport(output: Self.raw(parts: [a, a, b]), source: source)
        XCTAssertEqual(same.outcome, .complete, same.summary)
    }

    func testMissingAttachmentBytes_areUnverifiableNotSilent() async throws {
        let a = Part(name: "a.txt", bytes: Data("alpha".utf8))
        let full = try Self.message(Self.raw(parts: [a]))
        // A record whose attachment bytes cannot be reached: metadata only, no raw source.
        var bare = MBOXParser.RawEmail(headers: full.headers, rawSource: "", messageType: full.messageType,
                                       attachments: [AttachmentMetadata(filename: "a.txt", mimeType: "application/octet-stream", size: 5)],
                                       timestamp: full.timestamp, domains: full.domains, plainBody: full.plainBody, htmlBody: full.htmlBody)
        bare.folderPath = nil
        let report = try await emlFolderReport(output: Self.raw(parts: [a]), source: bare)
        XCTAssertEqual(report.outcome, .partial, report.summary)
        XCTAssertEqual(report.unverifiable, 1); XCTAssertEqual(report.matching, 0)
        XCTAssertEqual(outcome(report.findings[0], .attachments), .unverifiable("attachment bytes could not be read: 1 in the record"))
        // A payload the output lacks entirely is still a loss even without the record's bytes.
        let renamed = try await emlFolderReport(output: Self.raw(parts: [Part(name: "z.txt", bytes: a.bytes)]), source: bare)
        XCTAssertEqual(outcome(renamed.findings[0], .attachments), .lost("attachment names or Content-IDs differ"))
    }

    // MARK: - 5. Denominators and outcomes

    func testMissingSourceRecord_countsAgainstCompleteness() async throws {
        let known = try Self.message(Self.raw(messageID: "<k@t>"))
        let orphan = try Self.message(Self.raw(messageID: "<o@t>"))
        let folder = try writeFolder([("k.eml", Data(known.rawSource.utf8), known.id, nil),
                                      ("o.eml", Data(orphan.rawSource.utf8), orphan.id, nil),
                                      ("n.eml", Data(orphan.rawSource.utf8), nil, nil)])
        let report = await ExportReconciliation.reconcile(folder: folder, lookup: lookup([known]))
        XCTAssertEqual(report.outcome, .failed, report.summary)
        XCTAssertEqual(report.eligible, 3); XCTAssertEqual(report.matching, 1); XCTAssertEqual(report.withoutRecord, 2)
        XCTAssertEqual(report.findings.map(\.status), [.withoutRecord, .withoutRecord])
        XCTAssertTrue(report.reason?.contains("2 output(s) have no archive record") == true, report.reason ?? "")
    }

    func testParseFailure_countsAgainstCompleteness() async throws {
        let source = try Self.message(Self.raw())
        let other = try Self.message(Self.raw(messageID: "<p2@t>"))
        let folder = try writeFolder([("good.eml", Data(source.rawSource.utf8), source.id, nil),
                                      ("bad.msg", Data(repeating: 0x41, count: 600), other.id, nil),
                                      ("bad.eml", Data([0x00, 0x01, 0x02, 0xFF, 0xFE]), other.id, nil)])
        let report = await ExportReconciliation.reconcile(folder: folder, lookup: lookup([source, other]))
        XCTAssertEqual(report.outcome, .failed, report.summary)
        XCTAssertEqual(report.eligible, 3); XCTAssertEqual(report.unparsed, 2); XCTAssertEqual(report.matching, 1)
        XCTAssertEqual(report.findings.map(\.status), [.unparsed, .unparsed])
        XCTAssertNotNil(report.findings[0].reason)
    }

    func testNothingToCheck_isUnavailableWithReason_neverNil() async throws {
        let empty = try writeFolder([("report.csv", Data("a,b\n".utf8), nil, nil)])
        let report = await ExportReconciliation.reconcile(folder: empty, lookup: lookup([]))
        XCTAssertEqual(report.outcome, .unavailable, report.summary)
        XCTAssertEqual(report.notApplicable, 1)
        XCTAssertTrue(report.reason?.contains("none of the 1 listed files") == true, report.reason ?? "")
        let noInventory = await ExportReconciliation.reconcile(folder: dir.appendingPathComponent("missing"), lookup: lookup([]))
        XCTAssertEqual(noInventory.outcome, .unavailable)
        XCTAssertTrue(noInventory.reason?.hasPrefix("no export inventory could be read") == true)
        let singleOther = await ExportReconciliation.reconcile(file: dir.appendingPathComponent("x.pdf"), lookup: lookup([]))
        XCTAssertEqual(singleOther.outcome, .unavailable)
    }

    func testPromisedCountShortfall_isFailedAndNamed() async throws {
        let source = try Self.message(Self.raw())
        let folder = try writeFolder([("m.eml", Data(source.rawSource.utf8), source.id, nil)], written: 2)
        let report = await ExportReconciliation.reconcile(folder: folder, lookup: lookup([source]))
        XCTAssertEqual(report.outcome, .failed, report.summary)
        XCTAssertEqual(report.promised, 2)
        XCTAssertTrue(report.reason?.contains("promised 2 messages, 1 found") == true, report.reason ?? "")
    }

    // MARK: - 4. Header-only records

    func testHeaderOnlySource_withoutHydration_isBodyNotVerifiable() async throws {
        let full = try Self.message(Self.raw(parts: [Part(name: "a.txt", bytes: Data("alpha".utf8))]))
        let headerOnly = MBOXParser.RawEmail(id: full.id, headers: full.headers, rawSource: "", messageType: full.messageType,
                                             attachments: [], timestamp: full.timestamp, domains: full.domains, plainBody: "", htmlBody: "")
        XCTAssertTrue(ExportReconciliation.isHeaderOnly(headerOnly))
        let report = try await emlFolderReport(output: full.rawSource, source: headerOnly)
        XCTAssertEqual(report.outcome, .partial, report.summary)
        XCTAssertEqual(report.unverifiable, 1); XCTAssertEqual(report.matching, 0)
        let item = report.findings[0]
        for field in [ExportReconciliation.Field.plainBody, .htmlBody, .attachments] {
            XCTAssertEqual(outcome(item, field), .unverifiable("the record is header-only (located message) and was not hydrated"), "\(field)")
        }
        // Headers are still compared: a changed subject is a mismatch, not merely "unverifiable".
        let tampered = try await emlFolderReport(output: full.rawSource.replacingOccurrences(of: "Subject: Quarterly", with: "Subject: Altered"), source: headerOnly)
        XCTAssertEqual(tampered.findings[0].status, .mismatched)
    }

    func testHeaderOnlySource_withHydration_isVerified() async throws {
        let full = try Self.message(Self.raw(parts: [Part(name: "a.txt", bytes: Data("alpha".utf8))]))
        let headerOnly = MBOXParser.RawEmail(id: full.id, headers: full.headers, rawSource: "", messageType: full.messageType,
                                             attachments: [], timestamp: full.timestamp, domains: full.domains, plainBody: "", htmlBody: "")
        let pages = Pages()
        let hydrating = lookup([headerOnly], pages: pages, hydrate: { id in pages.hydrated(id); return id == full.id ? full : nil })
        let folder = try writeFolder([("m.eml", Data(full.rawSource.utf8), full.id, nil)])
        let report = await ExportReconciliation.reconcile(folder: folder, lookup: hydrating)
        XCTAssertEqual(report.outcome, .complete, report.summary)
        XCTAssertEqual(pages.hydrations, [full.id])
        // Hydration that yields nothing falls back to "not verifiable", never to a pass.
        let dry = lookup([headerOnly], hydrate: { _ in nil })
        let dryReport = await ExportReconciliation.reconcile(folder: folder, lookup: dry)
        XCTAssertEqual(dryReport.outcome, .partial, dryReport.summary)
        // And a tampered body is caught once hydrated.
        let bad = try writeFolder([("m.eml", Data(full.rawSource.replacingOccurrences(of: "Line two.", with: "Line 2.").utf8), full.id, nil)])
        let badReport = await ExportReconciliation.reconcile(folder: bad, lookup: hydrating)
        XCTAssertEqual(badReport.findings.first?.lostFields, [.plainBody])
    }

    // MARK: - 2/3. .msg output: named writer limits, no silent pass

    func testMSGOutput_namedTransformationsAndDetectedLoss() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 9, 8, 7])
        let source = try Self.message(Self.raw(bcc: "hidden@q.org", inReplyTo: "<m0@t>", references: "<a@t> <m0@t>",
                                               html: "<p>Hi <img src=\"cid:logo@x\"></p>",
                                               parts: [Part(name: "logo.png", bytes: png, cid: "logo@x", mime: "image/png"),
                                                       Part(name: "a.txt", bytes: Data("alpha".utf8))]))
        let msg = try XCTUnwrap(MSGWriter.write(email: source))
        let folder = try writeFolder([("m.msg", msg, source.id, nil)])
        let report = await ExportReconciliation.reconcile(folder: folder, lookup: lookup([source]))
        XCTAssertEqual(report.outcome, .complete, report.summary)
        XCTAssertEqual(report.transformations["the .msg writer does not carry attachment Content-IDs"], 1)
        XCTAssertEqual(report.transformations["the .msg writer does not carry the inline disposition"], 1)
        XCTAssertNotNil(report.transformations.keys.first { $0.hasPrefix("date re-expressed") }, "\(report.transformations)")
        // The same writer limits do not hide a real loss: a record with a different payload.
        let altered = try Self.message(Self.raw(bcc: "hidden@q.org", inReplyTo: "<m0@t>", references: "<a@t> <m0@t>",
                                                html: "<p>Hi <img src=\"cid:logo@x\"></p>",
                                                parts: [Part(name: "logo.png", bytes: png, cid: "logo@x", mime: "image/png"),
                                                        Part(name: "a.txt", bytes: Data("ALPHA".utf8))]))
        let alteredRecord = MBOXParser.RawEmail(id: source.id, headers: altered.headers, rawSource: altered.rawSource, messageType: altered.messageType,
                                                attachments: altered.attachments, timestamp: altered.timestamp, domains: altered.domains,
                                                plainBody: altered.plainBody, htmlBody: altered.htmlBody)
        let caught = await ExportReconciliation.reconcile(folder: folder, lookup: lookup([alteredRecord]))
        XCTAssertEqual(caught.outcome, .failed, caught.summary)
        XCTAssertEqual(outcome(caught.findings[0], .attachments), .lost("same names, different bytes: a.txt"))
        // Bcc dropped from the record's side of the comparison is seen through the .msg too.
        let noBcc = try Self.message(Self.raw(inReplyTo: "<m0@t>", references: "<a@t> <m0@t>", html: "<p>Hi <img src=\"cid:logo@x\"></p>",
                                              parts: [Part(name: "logo.png", bytes: png, cid: "logo@x", mime: "image/png"),
                                                      Part(name: "a.txt", bytes: Data("alpha".utf8))]))
        let noBccRecord = MBOXParser.RawEmail(id: source.id, headers: noBcc.headers, rawSource: noBcc.rawSource, messageType: noBcc.messageType,
                                              attachments: noBcc.attachments, timestamp: noBcc.timestamp, domains: noBcc.domains,
                                              plainBody: noBcc.plainBody, htmlBody: noBcc.htmlBody)
        let extra = await ExportReconciliation.reconcile(folder: folder, lookup: lookup([noBccRecord]))
        XCTAssertEqual(outcome(extra.findings[0], .bcc), .lost("added in output"))
    }

    // MARK: - 6. Container outputs

    func testMBOXOutput_isReconciledPerMessageWithSelection() async throws {
        let emails = try (1...3).map { i in try Self.message(Self.raw(subject: "Mail \(i)", messageID: "<mb\(i)@t>", plain: "Body \(i)",
                                                                        parts: i == 2 ? [Part(name: "f.txt", bytes: Data("file".utf8))] : [])) }
        let mbox = dir.appendingPathComponent("out.mbox")
        let records = await MainActor.run { emails.map { ArchiveExportService.mboxRecord(for: $0) } }
        try records.joined().write(to: mbox, atomically: true, encoding: .utf8)
        let clean = await ExportReconciliation.reconcile(file: mbox, promised: 3, lookup: lookup(emails), pageSize: 2)
        XCTAssertEqual(clean.outcome, .complete, clean.summary)
        XCTAssertEqual(clean.eligible, 3); XCTAssertEqual(clean.matching, 3); XCTAssertEqual(clean.filesReached, 1)
        XCTAssertEqual(clean.transformations["mbox carries no folder path"], nil, "records without a folder have nothing to lose")

        // Tampered body of the second record: named by its position in the file and its Message-ID.
        let text = try String(contentsOf: mbox, encoding: .utf8)
        try text.replacingOccurrences(of: "Body 2", with: "Body two").write(to: mbox, atomically: true, encoding: .utf8)
        let tampered = await ExportReconciliation.reconcile(file: mbox, promised: 3, lookup: lookup(emails), pageSize: 2)
        XCTAssertEqual(tampered.outcome, .failed, tampered.summary)
        XCTAssertEqual(tampered.mismatched, 1); XCTAssertEqual(tampered.matching, 2)
        XCTAssertEqual(tampered.findings[0].path, "out.mbox#2")
        XCTAssertEqual(tampered.findings[0].messageID, "mb2@t")
        XCTAssertEqual(tampered.findings[0].lostFields, [.plainBody])

        // Selection: a record the file lacks is a shortfall; a message with no record is withoutRecord.
        let short = await ExportReconciliation.reconcile(file: mbox, promised: 4, lookup: lookup(emails))
        XCTAssertTrue(short.reason?.contains("promised 4 messages, 3 found") == true, short.reason ?? "")
        let fewer = await ExportReconciliation.reconcile(file: mbox, promised: 3, lookup: lookup(Array(emails.dropLast())))
        XCTAssertEqual(fewer.withoutRecord, 1)
        XCTAssertEqual(fewer.findings.last?.reason, "no record with Message-ID mb3@t is in the archive")
        // A record with a folder: mbox cannot carry it, and that is named rather than passed over.
        var foldered = emails[0]; foldered.folderPath = "Inbox/Clients"
        let named = await ExportReconciliation.reconcile(file: mbox, promised: 3, lookup: lookup([foldered] + emails.dropFirst()))
        XCTAssertEqual(named.transformations["mbox carries no folder path"], 1)
    }

    /// The [MS-PST] writer (`PSTWriterPolicy.useSpecWriter`, the 3.0 default)
    /// round-trips every contract field; the check reads the file back per
    /// message with the bounded PST reader.
    func testPSTOutput_specWriter_isReconciledPerMessage() async throws {
        let (pst, emails) = try await writePST(specWriter: true)
        let report = await ExportReconciliation.reconcile(file: pst, promised: 3, lookup: lookup(emails), pageSize: 2)
        XCTAssertEqual(report.outcome, .complete, "\(report.summary)\n\(report.findings)")
        XCTAssertEqual(report.eligible, 3); XCTAssertEqual(report.matching, 3)
        XCTAssertEqual(report.transformations["the PST export writes every message into its export folder; the source folder path is not carried"], 1)
        try await pstDefectsAreCaught(pst: pst, emails: emails)
    }

    /// The earlier (pre-spec) writer's files come back through mailin's own
    /// reader WITHOUT a delivery time (0001-01-01) and without the sender's
    /// display name. That is a real loss in the output and the check names
    /// it on every message — it is not forgiven as a "permitted transformation".
    func testPSTOutput_legacyWriter_dateLossIsDetectedNotForgiven() async throws {
        let (pst, emails) = try await writePST(specWriter: false)
        let report = await ExportReconciliation.reconcile(file: pst, promised: 3, lookup: lookup(emails), pageSize: 2)
        XCTAssertEqual(report.outcome, .failed, report.summary)
        XCTAssertEqual(report.eligible, 3); XCTAssertEqual(report.mismatched, 3); XCTAssertEqual(report.matching, 0)
        for item in report.findings {
            XCTAssertTrue(item.lostFields.contains(.date), "\(item.path): \(item.fields)")
            XCTAssertEqual(outcome(item, .plainBody), .unchanged, "the body itself survives; only the date is lost")
        }
    }

    private func writePST(specWriter: Bool) async throws -> (URL, [MBOXParser.RawEmail]) {
        let previous = PSTWriterPolicy.useSpecWriter
        PSTWriterPolicy.useSpecWriter = specWriter
        defer { PSTWriterPolicy.useSpecWriter = previous }
        var emails = try (1...3).map { i in try Self.message(Self.raw(subject: "PST \(i)", bcc: i == 3 ? "hidden@q.org" : nil,
                                                                        messageID: "<pst\(i)@t>", plain: "Body \(i)",
                                                                        parts: i == 2 ? [Part(name: "f.txt", bytes: Data("file".utf8))] : [])) }
        emails[0].folderPath = "Inbox/Clients"
        let pst = dir.appendingPathComponent("out-\(specWriter ? "spec" : "legacy").pst")
        let writer = try PSTWriterFactory.make(url: pst)
        for email in emails { try writer.appendMessage(email) }
        XCTAssertEqual(try writer.finalize(), 3)
        return (pst, emails)
    }

    private func pstDefectsAreCaught(pst: URL, emails: [MBOXParser.RawEmail]) async throws {

        // A record that says something else is caught through the PST reader too.
        var altered = emails
        altered[1] = try Self.message(Self.raw(subject: "PST 2", messageID: "<pst2@t>", plain: "Body 2", parts: [Part(name: "f.txt", bytes: Data("FILE".utf8))]))
        let caught = await ExportReconciliation.reconcile(file: pst, promised: 3, lookup: lookup(altered))
        XCTAssertEqual(caught.outcome, .failed, caught.summary)
        XCTAssertEqual(caught.findings[0].path.hasPrefix(pst.lastPathComponent + "#"), true)
        XCTAssertEqual(caught.findings[0].lostFields, [.attachments])
        // A PST that is not a PST: one unparsed output, never a silent nil.
        let garbage = dir.appendingPathComponent("garbage.pst")
        try Data(repeating: 0x5A, count: 4096).write(to: garbage)
        let unparsed = await ExportReconciliation.reconcile(file: garbage, promised: 3, lookup: lookup(emails))
        XCTAssertEqual(unparsed.outcome, .failed, unparsed.summary)
        XCTAssertEqual(unparsed.unparsed, 1)
    }

    // MARK: - 7. Streaming and interruption

    func testSourceRecordsAreLookedUpInBoundedPages() async throws {
        let emails = try (1...7).map { i in try Self.message(Self.raw(subject: "Page \(i)", messageID: "<pg\(i)@t>")) }
        let folder = try writeFolder(emails.enumerated().map { i, e in ("\(i).eml", Data(e.rawSource.utf8), e.id, nil) })
        let pages = Pages()
        let report = await ExportReconciliation.reconcile(folder: folder, lookup: lookup(emails, pages: pages), pageSize: 3)
        XCTAssertEqual(report.outcome, .complete, report.summary)
        XCTAssertEqual(pages.calls.map(\.count), [3, 3, 1])
        XCTAssertEqual(Set(pages.calls.flatMap { $0 }), Set(emails.map(\.id)))
        // Nothing larger than the engine's ceiling is ever asked for.
        let capped = await ExportReconciliation.reconcile(folder: folder, lookup: lookup(emails, pages: Pages()), pageSize: 10_000)
        XCTAssertEqual(capped.outcome, .complete)
        XCTAssertLessThanOrEqual(ExportReconciliation.maxPageSize, 500)
    }

    func testInterruptedVerification_isPartialWithCountsSoFar() async throws {
        let emails = try (1...6).map { i in try Self.message(Self.raw(subject: "Cut \(i)", messageID: "<cut\(i)@t>")) }
        let folder = try writeFolder(emails.enumerated().map { i, e in ("\(i).eml", Data(e.rawSource.utf8), e.id, nil) })
        let byID = Dictionary(uniqueKeysWithValues: emails.map { ($0.id, $0) })
        // The second page blocks until the test has cancelled the run.
        let reached = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let counter = Pages()
        let blocking = ExportReconciliation.SourceLookup(records: { ids in
            counter.record(ids)
            if counter.calls.count == 2 {
                reached.continuation.yield(())
                for await _ in release.stream { break }
                try Task.checkCancellation()
            }
            return byID.filter { ids.contains($0.key) }
        })
        let run = Task { await ExportReconciliation.reconcile(folder: folder, lookup: blocking, pageSize: 2) }
        for await _ in reached.stream { break }
        run.cancel()
        release.continuation.yield(())
        let report = await run.value
        XCTAssertEqual(report.outcome, .partial, report.summary)
        XCTAssertEqual(report.matching, 2)
        XCTAssertEqual(report.checked, 2)
        XCTAssertEqual(report.eligible, 4, "the two files of the interrupted page are counted, not dropped")
        XCTAssertEqual(report.unverifiable, 2)
        XCTAssertEqual(report.eligibleFiles, 6); XCTAssertEqual(report.filesReached, 2)
        XCTAssertTrue(report.reason?.contains("cancelled") == true, report.reason ?? "")
        XCTAssertTrue(report.reason?.contains("2 of 6 files reached") == true, report.reason ?? "")
        XCTAssertFalse(report.isComplete)
    }

    // MARK: - Compatibility shim (the app's current call) is no weaker

    func testCompatibilityShim_isCleanRequiresRecordsAndVerifiableContent() throws {
        let full = try Self.message(Self.raw(parts: [Part(name: "a.txt", bytes: Data("alpha".utf8))]))
        let folder = try writeFolder([("m.eml", Data(full.rawSource.utf8), full.id, nil)])
        let clean = try ExportReconciliation.reconcile(folder: folder, records: [full.id: full])
        XCTAssertTrue(clean.isClean, "\(clean)")
        XCTAssertEqual(clean.checked, 1); XCTAssertEqual(clean.matching, 1)
        // A header-only record cannot be hydrated through this signature: not clean, and it says so.
        let headerOnly = MBOXParser.RawEmail(id: full.id, headers: full.headers, rawSource: "", messageType: full.messageType,
                                             attachments: [], timestamp: full.timestamp, domains: full.domains, plainBody: "", htmlBody: "")
        let unverifiable = try ExportReconciliation.reconcile(folder: folder, records: [full.id: headerOnly])
        XCTAssertFalse(unverifiable.isClean)
        XCTAssertEqual(unverifiable.unverifiable.count, 1)
        XCTAssertEqual(unverifiable.matching, 0)
        // A missing record is not clean either (it used to be ignored by isClean).
        let missing = try ExportReconciliation.reconcile(folder: folder, records: [:])
        XCTAssertFalse(missing.isClean); XCTAssertEqual(missing.withoutRecord, 1)
        // The old helpers still answer as before.
        XCTAssertEqual(ExportReconciliation.addresses("Ann <ann@x.com>, bob@y.org"), ExportReconciliation.addresses("bob@y.org,ANN@x.com"))
        XCTAssertEqual(ExportReconciliation.dateKey("Wed, 15 Jan 2025 10:00:30 +0000", ""), ExportReconciliation.dateKey(nil, "2025-01-15T10:00:00Z"))
    }

    func testByteIntegrityAndContentFidelity_stayTwoStatements() async throws {
        // A file whose bytes changed but whose content did not (CRLF → LF): the
        // inventory says "changed", the content check says "matches" — and the
        // reverse holds for a record the archive changed under an untouched file.
        let source = try Self.message(Self.raw())
        let folder = try writeFolder([("m.eml", Data(source.rawSource.utf8), source.id, nil)])
        let url = folder.appendingPathComponent("m.eml")
        try source.rawSource.replacingOccurrences(of: "\r\n", with: "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ExportInventory.verify(folder: folder).changed, ["m.eml"])
        let content = await ExportReconciliation.reconcile(folder: folder, lookup: lookup([source]))
        XCTAssertEqual(content.outcome, .complete, content.summary)
    }
}
