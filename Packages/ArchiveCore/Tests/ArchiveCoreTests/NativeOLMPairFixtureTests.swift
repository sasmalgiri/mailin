//
//  NativeOLMPairFixtureTests.swift
//  ArchiveCoreTests
//
//  CLOSE-04 (plan §8.1; directive 2026-11-07 §3 row 6): the native OLM.
//
//  The owner's supplied pack (ZIP SHA-256 3b4f0413…7b71e, staged as
//  <root>/native-pack-20261003/, apart from owner-pack/) holds ONE synthetic
//  mail exported natively twice — by Microsoft Outlook for Mac 16.112.4
//  (Legacy mode) as `native-outlook.olm` and by Apple Mail 16.0 as an MBOX
//  export (`mail/Root/mbox.mbox/mbox`, plus an unrelated child mailbox) —
//  and `paired-mail/native-mail.eml`, extracted from that MBOX with Python's
//  mailbox reader (derived, not a separate Outlook export).
//
//  What the pair covers, and nothing more (oracles/native_cross_format.json):
//  decoded subject, From, To, the HTML body (terminal line endings aside),
//  the two attachments' names, bytes and SHA-256, and the inline CID. The
//  native MBOX has NO Date and NO Message-ID while the OLM has both — these
//  tests never invent equality for them. The OLM's declared attachment sizes
//  ("9,4E1", "5,7E1") differ from the real payload lengths; the real bytes
//  are hashed. The OLM's contact and appointment and the MBOX's child
//  message are not shared. It is not an OLM of owner-pack/native/'s six
//  messages, and no native PST/OST/NSF of this mail exists.
//
//  Each source goes through the PRODUCTION path: BulkImportCoordinator
//  import → store → FTS search → ArchiveExportService.exportEMLFiles, and the
//  exported .eml is parsed back. The oracle and the producer manifest are
//  read first and checked against the pack's SHA256SUMS.
//

import XCTest
import Foundation
import CryptoKit
@testable import ArchiveCore

final class NativeOLMPairFixtureTests: XCTestCase {

    static let pack = "native-pack-20261003"
    static let olmPath = "\(pack)/native-apple-20261003/outlook/native-outlook.olm"
    static let rootMBOXPath = "\(pack)/native-apple-20261003/mail/Root/mbox.mbox/mbox"
    static let childMBOXPath = "\(pack)/native-apple-20261003/mail/Root/Child/mbox.mbox/mbox"
    static let emlPath = "\(pack)/paired-mail/native-mail.eml"
    static let oraclePath = "\(pack)/oracles/native_cross_format.json"
    static let manifestPath = "\(pack)/native-apple-20261003/manifest.json"

    // MARK: - Oracle and producer manifest (read first)

    struct Oracle: Decodable {
        struct Message: Decodable { let subject: String; let html: String; let message_id: String; let sent_time: String; let from: String; let to: String }
        struct Attachment: Decodable { let filename: String; let bytes: Int; let sha256: String; let cid: String?; let declared_size_text: String }
        struct Derived: Decodable { let path: String; let origin: String; let sha256: String }
        let producers: [String: String]
        let native_olm_email_count: Int
        let matched: [String]
        let message: Message
        let attachments: [Attachment]
        let mbox_missing_headers: [String]
        let limitations: [String]
        let derived_eml: Derived
    }

    struct Manifest: Decodable {
        struct File: Decodable { let path: String; let sha256: String }
        let producers: [String: String]
        let files: [File]
        let attachmentHashes: [String]
    }

    func url(_ path: String) throws -> URL { try ExternalFixtures.shared.require(path) }

    func oracle() throws -> Oracle { try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: try url(Self.oraclePath))) }

    func testOracleAndProducerManifest_agreeWithThePackAndWithEachOther() throws {
        let oracle = try oracle()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: try url(Self.manifestPath)))
        XCTAssertEqual(oracle.producers["outlook"], "Microsoft Outlook for Mac 16.112.4 (16.112.26090911), Legacy mode")
        XCTAssertEqual(oracle.producers["mail"], "Apple Mail 16.0 (3901.100.1.1.12)")
        XCTAssertEqual(manifest.producers, oracle.producers, "one producer record")
        XCTAssertEqual(oracle.native_olm_email_count, 1)
        XCTAssertEqual(Set(oracle.mbox_missing_headers), ["Message-ID", "Date"])
        XCTAssertEqual(Set(manifest.attachmentHashes), Set(oracle.attachments.map(\.sha256)))
        // The producer manifest's file hashes are the pack's (verified) bytes.
        for file in manifest.files where ["outlook/native-outlook.olm", "mail/Root/mbox.mbox/mbox", "mail/Root/Child/mbox.mbox/mbox"].contains(file.path) {
            let actual = try ExternalFixtures.sha256Hex(of: try url("\(Self.pack)/native-apple-20261003/\(file.path)"))
            XCTAssertEqual(actual, file.sha256, file.path)
        }
        XCTAssertEqual(try ExternalFixtures.sha256Hex(of: try url(Self.emlPath)), oracle.derived_eml.sha256, "the derived EML is the oracle's")
        XCTAssertEqual(oracle.derived_eml.path, "paired-mail/native-mail.eml")
    }

    // MARK: - Production import → store → search → export

    struct Imported {
        let raws: [MBOXParser.RawEmail]
        let archive: ArchiveDataService
        let service: ArchiveExportService
        let store: SQLiteEmailStore
        let work: URL
    }

    func importThroughProduction(_ source: URL) async throws -> Imported {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("native-pair-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let store = SQLiteEmailStore(directory: work.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: work.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        _ = try await coordinator.runImport(urls: [source], options: options)
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        var raws: [MBOXParser.RawEmail] = []
        var cursor: EmailPageCursor?
        repeat {
            let page = try await archive.page(query: .all, cursor: cursor, limit: 100)
            raws += try await store.emails(withIDs: page.summaries.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil
        return Imported(raws: raws, archive: archive, service: await ArchiveExportService(archive: archive), store: store, work: work)
    }

    /// The comparable content of one message, as the oracle lists it.
    struct Content: Equatable, CustomStringConvertible {
        var subject: String
        var from: String
        var to: String
        var html: String
        var attachments: [String]        // "name bytes sha256 cid", sorted
        var description: String { "\(subject) | \(from) → \(to) | \(attachments) | html \(html.count) chars" }
    }

    static func bareAddress(_ header: String?) -> String {
        let h = header ?? ""
        if let lt = h.lastIndex(of: "<"), let gt = h.lastIndex(of: ">"), lt < gt { return String(h[h.index(after: lt)..<gt]).lowercased() }
        return h.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func trimmedHTML(_ s: String) -> String {
        var t = s
        while let last = t.last, last == "\n" || last == "\r" { t.removeLast() }
        return t
    }

    static func attachmentLine(name: String, data: Data?, contentID: String?) -> String {
        let cid = (contentID ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        return "\(name) \(data?.count ?? -1) \(data.map(ExternalFixtures.sha256Hex(of:)) ?? "no-bytes") cid=\(cid)"
    }

    /// Content from the stored raw MIME, decoded by the production extractor
    /// (the bytes the archive keeps), cross-checked with the stored metadata.
    func content(of raw: MBOXParser.RawEmail, file: StaticString = #filePath, line: UInt = #line) throws -> Content {
        XCTAssertFalse(raw.rawSource.isEmpty, "raw MIME kept", file: file, line: line)
        let decoded = try EmailBodyExtractor.extractContents(from: raw.rawSource)
        XCTAssertEqual(decoded.attachments.map(\.filename).sorted(), raw.attachments.map(\.filename).sorted(), "stored names = decoded names", file: file, line: line)
        let atts = decoded.attachments.map { a -> String in
            let data = a.base64.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } ?? a.fileURL.flatMap { try? Data(contentsOf: $0) }
            return Self.attachmentLine(name: a.filename, data: data, contentID: a.contentID)
        }.sorted()
        let html = raw.htmlBody.isEmpty ? decoded.htmlBody : raw.htmlBody
        return Content(subject: raw.headers["Subject"] ?? "", from: Self.bareAddress(raw.headers["From"]), to: Self.bareAddress(raw.headers["To"]),
                       html: Self.trimmedHTML(html), attachments: atts)
    }

    func expected(_ oracle: Oracle) -> Content {
        Content(subject: oracle.message.subject, from: oracle.message.from, to: oracle.message.to, html: Self.trimmedHTML(oracle.message.html),
                attachments: oracle.attachments.map { "\($0.filename) \($0.bytes) \($0.sha256) cid=\($0.cid ?? "")" }.sorted())
    }

    func header(_ raw: MBOXParser.RawEmail, _ name: String) -> String? {
        raw.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Search (FTS) finds the message by its subject word and its Unicode body text; export writes it back out
    /// as .eml whose parsed content is the same.
    func assertSearchAndExport(_ imported: Imported, shared raw: MBOXParser.RawEmail, expected: Content,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        for term in ["OfficeIMO", "Zażółć", "synthetic"] {
            var q = EmailQuery.all; q.text = term
            let hits = try await imported.archive.page(query: q, limit: 50).summaries.map(\.id)
            XCTAssertTrue(hits.contains(raw.id), "search “\(term)” finds the message", file: file, line: line)
        }
        var miss = EmailQuery.all; miss.text = "lighthousequorumxyz"
        let none = try await imported.archive.page(query: miss, limit: 50).summaries
        XCTAssertTrue(none.isEmpty, "a word not in the message finds nothing", file: file, line: line)

        let out = imported.work.appendingPathComponent("export-eml", isDirectory: true)
        let result = try await imported.service.exportEMLFiles(scope: .query(.all, exclusions: []), to: out)
        XCTAssertEqual(result.recordsWritten, imported.raws.count, file: file, line: line)
        let files = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).filter { $0.pathExtension == "eml" }
        var reparsed: [Content] = []
        for f in files {
            let source = String(decoding: try Data(contentsOf: f), as: UTF8.self)
            let parsed = try ParserFactory.parse(fileURL: f, senderEmail: "")
            XCTAssertFalse(source.isEmpty)
            for p in parsed { reparsed.append(try content(of: p, file: file, line: line)) }
        }
        XCTAssertTrue(reparsed.contains(expected), "the exported .eml parses back to the oracle's content: \(reparsed)", file: file, line: line)
    }

    // MARK: - OLM (Outlook for Mac 16.112.4, native)

    func testNativeOLM_productionImport_matchesOracle_searchAndExportRoundTrip() async throws {
        let oracle = try oracle()
        let imported = try await importThroughProduction(try url(Self.olmPath))
        XCTAssertEqual(imported.raws.count, oracle.native_olm_email_count, "one mail record; the contact and appointment are not mail")
        let raw = try XCTUnwrap(imported.raws.first)
        XCTAssertEqual(try content(of: raw), expected(oracle), "OLM vs oracle")
        // The OLM HAS Message-ID and a date — they are its own, kept as written.
        XCTAssertEqual(header(raw, "Message-ID").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }, oracle.message.message_id)
        XCTAssertTrue(raw.timestamp.hasPrefix("2026-10-03"), "sent time from the record: \(raw.timestamp)")
        // Real payload sizes, not the OLM's declared size strings.
        XCTAssertEqual(raw.attachments.map(\.size).sorted(), oracle.attachments.map(\.bytes).sorted(), "declared \(oracle.attachments.map(\.declared_size_text)) not used")
        try await assertSearchAndExport(imported, shared: raw, expected: expected(oracle))
    }

    // MARK: - Apple Mail 16.0 MBOX export (native) and the EML derived from it

    func testNativeAppleMailMBOX_productionImport_matchesOracle_noDateOrMessageIDInvented() async throws {
        let oracle = try oracle()
        let rootMBOX = try url(Self.rootMBOXPath)
        _ = try url(Self.childMBOXPath)
        // The whole Mail export (Root + Root/Child) — the folders are kept; only Root's message is shared.
        let mailExport = rootMBOX.deletingLastPathComponent().deletingLastPathComponent()
        let imported = try await importThroughProduction(mailExport)
        XCTAssertEqual(imported.raws.count, 2, "Root's message + the child mailbox's own: \(imported.raws.map { $0.headers["Subject"] ?? "" })")
        let shared = try XCTUnwrap(imported.raws.first { $0.headers["Subject"] == oracle.message.subject })
        XCTAssertTrue(imported.raws.contains { $0.headers["Subject"] == "OfficeIMO child mailbox" }, "the child message is not the shared one")
        XCTAssertEqual(try content(of: shared), expected(oracle), "MBOX vs oracle")
        let folders = try await imported.store.folderNodes().filter { $0.messageCount > 0 }
        XCTAssertEqual(folders.count, 2, "Root and Root/Child kept apart: \(folders.map { "\($0.path)=\($0.messageCount)" })")

        // The source has no Message-ID and no Date header; mailin must not claim the OLM's.
        let source = String(decoding: try Data(contentsOf: rootMBOX), as: UTF8.self)
        XCTAssertFalse(source.lowercased().contains("\nmessage-id:"), "native MBOX has no Message-ID")
        XCTAssertFalse(source.lowercased().contains("\ndate:"), "native MBOX has no Date header")
        XCTAssertNotEqual(header(shared, "Message-ID").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }, oracle.message.message_id,
                          "no equality invented with the OLM's Message-ID")
        XCTAssertFalse(shared.rawSource.lowercased().contains("message-id: <\(oracle.message.message_id.lowercased())>"))
        try await assertSearchAndExport(imported, shared: shared, expected: expected(oracle))
    }

    func testDerivedEML_productionImport_matchesOracle() async throws {
        let oracle = try oracle()
        let eml = try url(Self.emlPath)
        let imported = try await importThroughProduction(eml)
        XCTAssertEqual(imported.raws.count, 1)
        let raw = try XCTUnwrap(imported.raws.first)
        XCTAssertEqual(try content(of: raw), expected(oracle), "derived EML vs oracle")
        XCTAssertNotEqual(header(raw, "Message-ID").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }, oracle.message.message_id)
        try await assertSearchAndExport(imported, shared: raw, expected: expected(oracle))
    }

    /// The cross-format statement itself: OLM, MBOX and EML give mailin the
    /// same oracle fields — and only those are compared.
    func testCrossFormat_OLMvsAppleMail_sameSubjectAddressesBodyAttachmentsCIDs() async throws {
        let oracle = try oracle()
        let olm = try await importThroughProduction(try url(Self.olmPath))
        let mbox = try await importThroughProduction(try url(Self.rootMBOXPath).deletingLastPathComponent())
        let eml = try await importThroughProduction(try url(Self.emlPath))
        let a = try content(of: try XCTUnwrap(olm.raws.first))
        let b = try content(of: try XCTUnwrap(mbox.raws.first { $0.headers["Subject"] == oracle.message.subject }))
        let c = try content(of: try XCTUnwrap(eml.raws.first))
        XCTAssertEqual(a, b, "OLM vs Apple Mail MBOX")
        XCTAssertEqual(b, c, "MBOX vs the EML derived from it")
        XCTAssertTrue(a.attachments.contains { $0.hasPrefix("pixel.png ") && $0.hasSuffix("cid=synthetic-pixel") }, "\(a.attachments)")
        XCTAssertTrue(a.html.contains("cid:synthetic-pixel"), "the HTML references the inline part")
    }
}
