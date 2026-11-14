//
//  RawSourceRecoveryTests.swift
//  ArchiveCoreTests
//
//  Release audit bf1a5b9 R4 (2026-11-08): Health ▸ Recovery ▸ "Recover
//  missing imported attachments" decides on CONTENT, not on headers alone.
//  Two messages in the source that share Message-ID, subject, second, sender
//  and filenames but carry different payloads are ambiguous; a message whose
//  body differs from the stored body is not written; a changed source (hash
//  mismatch) is written from only when the content the row keeps confirms the
//  match, and the provenance header says so. The end-to-end recovery tests
//  (testRECOVER_*) live in the app's V2CutoverTests. Generated mail only.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class RawSourceRecoveryTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RawSourceRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// One message: the same Message-ID, subject, second, sender, recipient and attachment
    /// filename every time; the body and the attachment payload are what the caller varies.
    private static func raw(body: String, payload: String) -> String {
        """
        From: Ann <ann@example.com>
        To: bob@example.com
        Subject: Quarterly figures
        Date: Wed, 15 Jan 2025 10:02:00 +0000
        Message-ID: <twin@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        \(body)
        --B
        Content-Type: application/octet-stream; name="figures.bin"
        Content-Disposition: attachment; filename="figures.bin"
        Content-Transfer-Encoding: base64

        \(Data(payload.utf8).base64EncodedString())
        --B--
        """
    }

    private static let payloadA = String(repeating: "A", count: 600)
    private static let payloadB = String(repeating: "B", count: 600)   // same size, other bytes

    private func writePST(_ name: String, _ raws: [String]) throws -> URL {
        let url = root.appendingPathComponent(name)
        let writer = try PSTWriterFactory.make(url: url)
        for raw in raws { try writer.appendMessage(try MBOXParser.processRawMessage(raw, senderEmail: "")) }
        _ = try writer.finalize()
        return url
    }

    /// The message as an import of a PST holding it would have stored it.
    private func imported(_ raw: String) throws -> MBOXParser.RawEmail {
        let url = try writePST("import-\(UUID().uuidString).pst", [raw])
        defer { try? FileManager.default.removeItem(at: url) }
        var email = try XCTUnwrap(try ParserFactory.parse(fileURL: url, senderEmail: "").first)
        for a in email.attachments { if let u = a.fileURL { try? FileManager.default.removeItem(at: u) } }
        email.folderPath = "Inbox/Figures"
        return email
    }

    private struct Archive {
        let store: SQLiteEmailStore
        let id: UUID
        let sourceFile: URL
        let registeredHash: String
    }

    /// One damaged archive record of "two.pst": imported from `stored`, then its raw source lost (the
    /// pre-2026-11-07 state). `sourceRaws` is what the file on disk holds now. When `verified`, the file
    /// is the registered source (and the archive has its copy); otherwise the registered hash is another
    /// file's and the file on disk is a changed source.
    private func archive(stored: String, sourceRaws: [String], verified: Bool, storedOrdinal: Int?) async throws -> Archive {
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let file = try writePST("two.pst", sourceRaws)
        let fileHash = try ExportInventory.sha256(of: file)
        let registered = verified ? fileHash : String(repeating: "f", count: 64)
        let sourceID = try await store.registerSource(SQLiteEmailStore.SourceDescriptor(sha256: registered, filename: "two.pst", byteSize: 0, parser: "pst", sourceKind: "pst"))
        if verified { _ = try SourceCopies.copyIntoArchive(original: file, sha256: fileHash, storeDirectory: store.storeDirectory) }
        let email = try imported(stored)
        _ = try await store.insertBatch([email], sourceFileHash: registered, accountID: nil, sourceID: sourceID, firstOrdinal: storedOrdinal,
                                        dedupPolicy: .messageID, batchSize: 10, progress: nil)
        try await store.userTagAdd("figures", ids: [email.id])
        try await store.annotationSet("check the totals", id: email.id)
        _ = try await store.legalHoldsAdd([email.id], matter: "M-4")
        try await store.replaceRawSource(emailID: email.id, rawSource: "")
        return Archive(store: store, id: email.id, sourceFile: file, registeredHash: registered)
    }

    private func group(_ plan: RawSourceRecovery.Plan) throws -> RawSourceRecovery.SourceGroup {
        try XCTUnwrap(plan.groups.first { $0.filename == "two.pst" })
    }

    // MARK: - Two content-distinct proposals

    /// The audit's native negative test: one damaged record; two messages in the source with the same
    /// Message-ID, subject, second, sender and filenames but different payloads. No automatic write,
    /// the ambiguity is in the receipt (with both positions), record ID / note / hold / folders / tags
    /// unchanged.
    func testTwoProposalsSameHeadersDifferentPayloads_ambiguous_nothingWritten() async throws {
        let body = "Totals attached."
        let a = try await archive(stored: Self.raw(body: body, payload: Self.payloadA),
                                  sourceRaws: [Self.raw(body: body, payload: Self.payloadA), Self.raw(body: body, payload: Self.payloadB)],
                                  verified: true, storedOrdinal: nil)
        let before = try await a.store.recoveryInvariants(id: a.id)
        XCTAssertEqual(before?.note, "check the totals"); XCTAssertEqual(before?.held, true)
        XCTAssertEqual(before?.tags, ["figures"]); XCTAssertFalse(before?.folderIDs.isEmpty ?? true)
        let plan = try await RawSourceRecovery.plan(store: a.store)
        XCTAssertEqual(try group(plan).count, 1)
        XCTAssertNotNil(try group(plan).fileURL, "the verified copy is in the archive")

        let receipts = RawSourceRecoveryReceiptStore(directory: root.appendingPathComponent("receipts"))
        let receipt = await RawSourceRecovery.run(store: a.store, plan: plan, receipts: receipts)
        XCTAssertEqual(receipt.recovered, 0, receipt.line)
        XCTAssertEqual(receipt.ambiguous, 1, receipt.line)
        XCTAssertEqual(receipt.wrongSources, [])
        XCTAssertEqual(receipt.ambiguousItems.count, 1)
        let item = receipt.ambiguousItems[0]
        XCTAssertEqual(item.emailID, a.id)
        XCTAssertTrue(item.reason.contains("body or attachment content differs"), item.reason)
        XCTAssertEqual(item.fileOrdinals, [0, 1], "both messages in the file are listed")
        XCTAssertTrue(item.fileSubject.hasPrefix("2 messages in the file"), item.fileSubject)
        let saved = try receipts.load(try XCTUnwrap(receipts.list().first))
        XCTAssertEqual(saved.ambiguousItems, receipt.ambiguousItems, "the ambiguity is in the receipt on disk")

        let rowOptional = try await a.store.fullEmail(id: a.id)
        let row = try XCTUnwrap(rowOptional)
        XCTAssertTrue(row.rawSource.isEmpty, "nothing was written")
        let after = try await a.store.recoveryInvariants(id: a.id)
        XCTAssertEqual(after, before, "record ID, note, hold, folders and tags unchanged")
        await a.store.reopenConnection()
    }

    /// The same two messages in the VERIFIED source, and the row keeps its source ordinal: the import's
    /// own position names exactly one of them, so that one is written — and it is the right payload.
    func testTwoProposals_verifiedSourceOrdinalNamesOne_writtenWithItsPayload() async throws {
        let body = "Totals attached."
        let a = try await archive(stored: Self.raw(body: body, payload: Self.payloadA),
                                  sourceRaws: [Self.raw(body: body, payload: Self.payloadA), Self.raw(body: body, payload: Self.payloadB)],
                                  verified: true, storedOrdinal: 0)
        let before = try await a.store.recoveryInvariants(id: a.id)
        XCTAssertEqual(before?.sourceOrdinal, 0)
        let plan = try await RawSourceRecovery.plan(store: a.store)
        let receipt = await RawSourceRecovery.run(store: a.store, plan: plan)
        XCTAssertEqual(receipt.recovered, 1, receipt.line)
        XCTAssertEqual(receipt.ambiguous, 0, receipt.line)
        let rowOptional = try await a.store.fullEmail(id: a.id)
        let row = try XCTUnwrap(rowOptional)
        let bytes = AttachmentHydrator.data(for: try XCTUnwrap(row.attachments.first), index: 0, email: row)
        XCTAssertEqual(bytes, Data(Self.payloadA.utf8), "the message at the stored position, not its twin")
        XCTAssertFalse(RawSourceProvenance.label(for: row.rawSource).fromUnverifiedFile)
        let after = try await a.store.recoveryInvariants(id: a.id)
        XCTAssertEqual(after, before)
        await a.store.reopenConnection()
    }

    // MARK: - Body differs from the stored body

    func testProposalWhoseBodyDiffersFromStoredBody_notWritten() async throws {
        let a = try await archive(stored: Self.raw(body: "The total is 4,100.", payload: Self.payloadA),
                                  sourceRaws: [Self.raw(body: "The total is 9,900.", payload: Self.payloadA)],
                                  verified: true, storedOrdinal: 0)
        let before = try await a.store.recoveryInvariants(id: a.id)
        let plan = try await RawSourceRecovery.plan(store: a.store)
        let receipt = await RawSourceRecovery.run(store: a.store, plan: plan)
        XCTAssertEqual(receipt.recovered, 0, receipt.line)
        XCTAssertEqual(receipt.ambiguous, 1, receipt.line)
        let item = try XCTUnwrap(receipt.ambiguousItems.first)
        XCTAssertEqual(item.emailID, a.id)
        XCTAssertTrue(item.reason.hasPrefix("Message-ID matches but"), item.reason)
        XCTAssertTrue(item.reason.contains("body"), item.reason)
        let rowOptional = try await a.store.fullEmail(id: a.id)
        let row = try XCTUnwrap(rowOptional)
        XCTAssertTrue(row.rawSource.isEmpty)
        let after = try await a.store.recoveryInvariants(id: a.id)
        XCTAssertEqual(after, before)
        await a.store.reopenConnection()
    }

    // MARK: - Changed source

    /// A file whose SHA-256 differs from the registered import, holding the message with the same
    /// body and attachment: written, and the provenance header says the file differed AND that the
    /// match was made on content.
    func testChangedSourceWithContentMatch_written_provenanceSaysSo() async throws {
        let raw = Self.raw(body: "Totals attached.", payload: Self.payloadA)
        let a = try await archive(stored: raw, sourceRaws: [raw], verified: false, storedOrdinal: 0)
        let before = try await a.store.recoveryInvariants(id: a.id)
        let plan = try await RawSourceRecovery.plan(store: a.store)
        let g = try group(plan)
        XCTAssertNil(g.fileURL, "no verified copy")
        let receipt = await RawSourceRecovery.run(store: a.store, plan: plan, files: [g.id: a.sourceFile])
        XCTAssertEqual(receipt.wrongSources, ["two.pst"], receipt.line)
        XCTAssertEqual(receipt.recovered, 1, receipt.line)
        XCTAssertNotNil(receipt.snapshotPath)
        let rowOptional = try await a.store.fullEmail(id: a.id)
        let row = try XCTUnwrap(rowOptional)
        let label = RawSourceProvenance.label(for: row.rawSource)
        XCTAssertTrue(label.isReconstructed)
        XCTAssertTrue(label.fromUnverifiedFile)
        XCTAssertTrue(label.matchedByContent, row.rawSource.prefix(300).description)
        XCTAssertTrue(row.rawSource.contains(RawSourceProvenance.unverifiedSuffix))
        XCTAssertEqual(AttachmentHydrator.data(for: try XCTUnwrap(row.attachments.first), index: 0, email: row), Data(Self.payloadA.utf8))
        let after = try await a.store.recoveryInvariants(id: a.id)
        XCTAssertEqual(after, before)
        await a.store.reopenConnection()
    }

    /// A changed source whose message has the same headers but another body is never written from.
    func testChangedSourceWithBodyMismatch_notWritten() async throws {
        let a = try await archive(stored: Self.raw(body: "The total is 4,100.", payload: Self.payloadA),
                                  sourceRaws: [Self.raw(body: "The total is 9,900.", payload: Self.payloadA)],
                                  verified: false, storedOrdinal: 0)
        let plan = try await RawSourceRecovery.plan(store: a.store)
        let g = try group(plan)
        let receipt = await RawSourceRecovery.run(store: a.store, plan: plan, files: [g.id: a.sourceFile])
        XCTAssertEqual(receipt.recovered, 0, receipt.line)
        XCTAssertEqual(receipt.ambiguous, 1, receipt.line)
        let rowOptional = try await a.store.fullEmail(id: a.id)
        XCTAssertTrue(try XCTUnwrap(rowOptional).rawSource.isEmpty)
        await a.store.reopenConnection()
    }

    // MARK: - Matcher

    /// Corroboration uses everything the row keeps: body, recipients, attachment sizes and hashes; a
    /// changed file with no stored body or attachment hash to compare is refused.
    func testMatcher_corroboratesAgainstStoredBodyRecipientsSizesHashes() throws {
        let content = RawSourceRecovery.RecoveryContent(try MBOXParser.processRawMessage(Self.raw(body: "Totals attached.", payload: Self.payloadA), senderEmail: ""))
        let parsed = try MBOXParser.processRawMessage(Self.raw(body: "Totals attached.", payload: Self.payloadA), senderEmail: "")
        func candidate(body: String?, recipients: String = "Bob <bob@example.com>", size: Int = 600, hash: String = "") -> SQLiteEmailStore.RecoveryCandidate {
            var c = SQLiteEmailStore.RecoveryCandidate(id: UUID(), messageID: "<twin@example.com>", subject: "Quarterly figures", date: 1_736_935_320,
                                                       from: "ann@example.com", sourceHash: "h", sourceOrdinal: nil, attachmentNames: ["figures.bin"], hasRawSource: false)
            c.recipients = recipients
            c.bodyFingerprint = body.flatMap { RawSourceRecovery.RecoveryContent.bodyFingerprint(plain: $0, html: "") }
            c.attachmentSizes = [size]
            c.attachmentHashes = [hash]
            return c
        }
        XCTAssertEqual(content.attachments.first?.size, 600)
        let payloadHash = try XCTUnwrap(content.attachments.first?.sha256)
        let good = candidate(body: "Totals   attached.\n")   // whitespace is normalised
        XCTAssertEqual(RawSourceRecovery.Matcher(candidates: [good], verifiedFile: true).match(parsed, ordinal: 0), .match(good, strong: true))

        for (bad, what) in [(candidate(body: "Other text."), "body"),
                            (candidate(body: "Totals attached.", recipients: "carol@example.com"), "recipients"),
                            (candidate(body: "Totals attached.", size: 601), "attachments"),
                            (candidate(body: "Totals attached.", hash: String(repeating: "0", count: 64)), "attachments")] {
            guard case .ambiguous(let item) = RawSourceRecovery.Matcher(candidates: [bad], verifiedFile: true).match(parsed, ordinal: 0) else {
                XCTFail("\(what) differs: must not match"); continue
            }
            XCTAssertTrue(item.reason.contains(what), item.reason)
        }
        // A changed file: confirmed by the stored body, or by stored attachment hashes; refused with neither.
        XCTAssertEqual(RawSourceRecovery.Matcher(candidates: [good], verifiedFile: false).match(parsed, ordinal: 0), .match(good, strong: true))
        let hashOnly = candidate(body: nil, hash: payloadHash)
        let bodyless = try MBOXParser.processRawMessage(Self.raw(body: "", payload: Self.payloadA), senderEmail: "")
        XCTAssertNil(RawSourceRecovery.RecoveryContent(bodyless).body, "an empty text part is no body")
        do {
            XCTAssertEqual(RawSourceRecovery.Matcher(candidates: [hashOnly], verifiedFile: false).match(bodyless, ordinal: 0), .match(hashOnly, strong: true))
            let nothing = candidate(body: nil)
            guard case .ambiguous(let refused) = RawSourceRecovery.Matcher(candidates: [nothing], verifiedFile: false).match(bodyless, ordinal: 0) else {
                return XCTFail("a changed file with nothing to compare must not be written from")
            }
            XCTAssertTrue(refused.reason.contains("keeps no body or attachment fingerprint"), refused.reason)
            XCTAssertEqual(RawSourceRecovery.Matcher(candidates: [nothing], verifiedFile: true).match(bodyless, ordinal: 0), .match(nothing, strong: true),
                           "the verified source still matches on headers when the row keeps nothing more")
        }

        // Proposal identity: same headers, different payload → different key; a copy → same key.
        let twin = RawSourceRecovery.RecoveryContent(try MBOXParser.processRawMessage(Self.raw(body: "Totals attached.", payload: Self.payloadB), senderEmail: ""))
        XCTAssertNotEqual(content.identityKey, twin.identityKey)
        XCTAssertEqual(content.identityKey, RawSourceRecovery.RecoveryContent(parsed).identityKey)
    }
}
