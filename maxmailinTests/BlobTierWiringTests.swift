//
//  BlobTierWiringTests.swift
//  maxmailinTests
//
//  S3b: proof that the raw-MIME blob tier is wired through EVERY path that
//  touches `email_bodies.raw`, not just the writer.
//
//  Why each of these exists rather than one happy-path test: the danger in
//  S3b was never "the blob does not store". It was that a blob-backed row
//  would look to the other six call sites like a row with NO raw source —
//  which would have made every large message invisible to the fidelity,
//  header-recovery, attachment-text and participants passes, and would have
//  let `healFidelity` OVERWRITE a stored message it believed was empty. Each
//  test below pins one of those sites against a blob-backed row.
//
//  NOT YET EXECUTED — written under an instruction to implement first and
//  test afterwards.
//

import XCTest
@testable import maxmailin

final class BlobTierWiringTests: XCTestCase {

    private var directory: URL!
    private var store: SQLiteEmailStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blobtier-\(UUID().uuidString)", isDirectory: true)
        store = SQLiteEmailStore(directory: directory)
    }

    // Deliberately NOT removing the directory in teardown: an earlier test in
    // this project deleted a temp store while a deferred restore task still
    // held handles. Temp directories are reclaimed by the OS; a flaky teardown
    // is worse than a few megabytes.

    // MARK: - Fixtures

    /// Raw MIME comfortably above `BlobStore.inlineThresholdBytes` (8 MiB), so
    /// the tier decision is unambiguous. The padding is deterministic, so the
    /// content hash is stable across runs.
    private func largeRawSource(marker: String, mib: Int = 10) -> String {
        let body = String(repeating: "\(marker)-0123456789ab", count: (mib * 1_048_576) / 16)
        return """
        From sender@example.com Tue Mar 14 09:41:00 2017
        From: sender@example.com
        To: recipient@example.com
        Subject: \(marker)
        Message-ID: <\(marker)@example.com>
        Date: Tue, 14 Mar 2017 09:41:00 +0000
        MIME-Version: 1.0
        Content-Type: text/plain; charset=utf-8

        \(body)
        """
    }

    private func email(rawSource: String,
                       marker: String,
                       messageType: String = "email",
                       attachments: [AttachmentMetadata] = []) -> MBOXParser.RawEmail {
        MBOXParser.RawEmail(
            headers: [
                "From": "sender@example.com",
                "To": "recipient@example.com",
                "Subject": marker,
                "Message-ID": "<\(marker)@example.com>",
                "Date": "Tue, 14 Mar 2017 09:41:00 +0000"
            ],
            rawSource: rawSource,
            messageType: messageType,
            attachments: attachments,
            timestamp: "Tue, 14 Mar 2017 09:41:00 +0000",
            domains: ["example.com"],
            plainBody: "body of \(marker)",
            htmlBody: ""
        )
    }

    @discardableResult
    private func insert(_ emails: [MBOXParser.RawEmail]) async throws -> BatchInsertResult {
        try await store.insertBatch(
            emails,
            sourceFileHash: "test-source",
            accountID: nil,
            sourceID: nil,
            firstOrdinal: nil,
            dedupPolicy: .messageID,
            batchSize: 50,
            progress: nil)
    }

    // MARK: - Site 1: the writer

    /// The case that is impossible without the blob tier: a message far larger
    /// than a comfortable row stores and reads back byte-identical.
    func testLargeMessage_storesAndReadsBackByteIdentical() async throws {
        let raw = largeRawSource(marker: "large-roundtrip")
        let probe = email(rawSource: raw, marker: "large-roundtrip")

        let result = try await insert([probe])
        XCTAssertEqual(result.insertedIDs, [probe.id])

        let readBack = try await store.fullEmail(id: probe.id)
        XCTAssertEqual(readBack?.rawSource, raw,
                       "a blob-backed message must read back byte-identical")
        XCTAssertEqual(readBack?.anomalies ?? ["missing"], [],
                       "a healthy blob read must record no anomaly")
    }

    /// A short message must stay inline — the blob tier is for the cases that
    /// need it, and paying a file open for every ordinary email would be a
    /// regression dressed up as a feature.
    func testSmallMessage_staysInline() async throws {
        let probe = email(rawSource: "From: a@b.c\nSubject: tiny\n\nshort body",
                          marker: "tiny")
        try await insert([probe])

        let digests = try await store.referencedBlobDigests()
        XCTAssertTrue(digests.isEmpty, "a short message must not create a blob; got \(digests)")
        let readBack = try await store.fullEmail(id: probe.id)
        XCTAssertEqual(readBack?.rawSource, probe.rawSource)
    }

    /// Content addressing: two messages with identical raw source share one
    /// blob rather than storing the bytes twice.
    func testIdenticalBodies_storeOneBlob() async throws {
        let raw = largeRawSource(marker: "shared")
        var first = email(rawSource: raw, marker: "shared")
        var second = email(rawSource: raw, marker: "shared")
        // Distinct Message-IDs, so dedup does not drop the second row.
        first.headers["Message-ID"] = "<shared-1@example.com>"
        second.headers["Message-ID"] = "<shared-2@example.com>"

        try await insert([first, second])

        let digests = try await store.referencedBlobDigests()
        XCTAssertEqual(digests.count, 1,
                       "identical bodies must be stored once; got \(digests.count)")
        // Hoisted: XCTAssert* arguments are autoclosures and cannot await.
        let firstRaw = try await store.fullEmail(id: first.id)?.rawSource
        let secondRaw = try await store.fullEmail(id: second.id)?.rawSource
        XCTAssertEqual(firstRaw, raw)
        XCTAssertEqual(secondRaw, raw)
    }

    // MARK: - Sites 2–3: full-email reads

    /// `emails(withIDs:)` is a separate query from `fullEmail(id:)` and had to
    /// be fixed separately — a blob-backed row must hydrate on both.
    func testBatchRead_hydratesBlobBackedRows() async throws {
        let rawA = largeRawSource(marker: "batch-a")
        let rawB = largeRawSource(marker: "batch-b")
        let a = email(rawSource: rawA, marker: "batch-a")
        let b = email(rawSource: rawB, marker: "batch-b")
        try await insert([a, b])

        let fetched = try await store.emails(withIDs: [a.id, b.id])
        XCTAssertEqual(fetched.count, 2)
        let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0.rawSource) })
        XCTAssertEqual(byID[a.id], rawA)
        XCTAssertEqual(byID[b.id], rawB)
    }

    // MARK: - Site 4: fidelity backfill

    /// A legacy row (`message_type == ''`) whose raw source is in the blob tier
    /// must appear as a CANDIDATE, never on the rawless list. Getting this
    /// wrong marks the message 'unknown' forever.
    func testFidelityBackfill_seesBlobBackedRowAsCandidate() async throws {
        let raw = largeRawSource(marker: "fidelity")
        let probe = email(rawSource: raw, marker: "fidelity", messageType: "")
        try await insert([probe])

        let (candidates, rawless) = try await store.fidelityBackfillCandidates(limit: 10)
        XCTAssertTrue(rawless.isEmpty, "a blob-backed row is NOT rawless; got \(rawless)")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.id, probe.id)
        XCTAssertEqual(candidates.first?.raw, raw,
                       "the candidate must carry the full raw source from the blob")
    }

    /// The page must never come back empty while work remains, and each
    /// candidate must carry real bytes. (The budget itself is checked against
    /// `raw_blob_length` from the row, so a huge body is skipped without ever
    /// being opened.)
    func testFidelityBackfill_pagesBlobBackedRowsWithoutEmptyPages() async throws {
        let first = email(rawSource: largeRawSource(marker: "budget-1"),
                          marker: "budget-1", messageType: "")
        let second = email(rawSource: largeRawSource(marker: "budget-2"),
                           marker: "budget-2", messageType: "")
        try await insert([first, second])

        let (candidates, rawless) = try await store.fidelityBackfillCandidates(limit: 10)
        XCTAssertTrue(rawless.isEmpty, "\(rawless)")
        XCTAssertGreaterThanOrEqual(candidates.count, 1,
                                    "a page must never come back empty while work remains")
        for candidate in candidates {
            XCTAssertFalse(candidate.raw.isEmpty, "every candidate must carry its bytes")
        }
    }

    // MARK: - Site 5: header-recovery predicate

    /// `headerFidelityCandidates` looks for rows with NO raw MIME. A
    /// blob-backed row HAS raw MIME, so it must be excluded — otherwise every
    /// large message gets "recovered" headers it already had.
    func testHeaderRecovery_excludesBlobBackedRows() async throws {
        let probe = email(rawSource: largeRawSource(marker: "headers"), marker: "headers")
        try await insert([probe])

        let candidates = try await store.headerFidelityCandidates(afterID: nil, limit: 50)
        XCTAssertFalse(candidates.contains { $0.id == probe.id },
                       "a blob-backed row must not be treated as having no raw MIME")
    }

    // MARK: - Site 6: healFidelity

    /// The promise `healFidelity` makes is "rows that already carry raw source
    /// are left alone". With a length check that ignored the blob tier, every
    /// large message read as length 0 and would have been OVERWRITTEN.
    func testHealFidelity_doesNotOverwriteABlobBackedRow() async throws {
        let original = largeRawSource(marker: "heal")
        let probe = email(rawSource: original, marker: "heal")
        try await insert([probe])

        // A re-parse of the "same" message carrying different bytes.
        var replacement = probe
        replacement.rawSource = largeRawSource(marker: "heal", mib: 9) + "\nX-Tampered: yes"

        let result = try await store.healFidelity(from: [replacement])
        XCTAssertEqual(result.alreadyFull, 1,
                       "the stored row must be recognised as already having raw source")
        XCTAssertEqual(result.healed, 0, "nothing should have been healed")

        let readBack = try await store.fullEmail(id: probe.id)
        XCTAssertEqual(readBack?.rawSource, original, "the stored bytes must be untouched")
    }

    /// And heal must still WORK for a row that genuinely has no raw source,
    /// including when the healing source is itself large enough to need the
    /// blob tier — otherwise the heal would fail on the row-size limit.
    func testHealFidelity_healsARawlessRowIntoTheBlobTier() async throws {
        let rawless = email(rawSource: "", marker: "rawless")
        try await insert([rawless])

        let full = largeRawSource(marker: "rawless")
        var healingSource = rawless
        healingSource.rawSource = full

        let result = try await store.healFidelity(from: [healingSource])
        XCTAssertEqual(result.healed, 1, "a row with no raw source must be healed")

        let readBack = try await store.fullEmail(id: rawless.id)
        XCTAssertEqual(readBack?.rawSource, full,
                       "the healed row must read back byte-identical from the blob tier")
    }

    // MARK: - Site 7a: attachment text

    func testAttachmentText_seesBlobBackedRowAsCandidate() async throws {
        let attachment = AttachmentMetadata(
            filename: "report.pdf", mimeType: "application/pdf",
            size: 1024, isInline: false, contentID: nil)
        let probe = email(rawSource: largeRawSource(marker: "attach"),
                          marker: "attach", attachments: [attachment])
        try await insert([probe])

        let (candidates, rawless) = try await store.attachmentTextCandidates(limit: 10)
        XCTAssertTrue(rawless.isEmpty, "a blob-backed row is NOT rawless; got \(rawless)")
        XCTAssertEqual(candidates.first?.id, probe.id)
        XCTAssertFalse(candidates.first?.raw.isEmpty ?? true)
    }

    // MARK: - Site 7b: participants backfill

    func testParticipantsBackfill_seesBlobBackedRowAsCandidate() async throws {
        let raw = largeRawSource(marker: "participants")
        let probe = email(rawSource: raw, marker: "participants")
        try await insert([probe])

        // Import extracts participants, so clear them to recreate the state
        // this work list exists for: classified, but never extracted.
        try await store.clearParticipantsForTesting()

        let (candidates, rawless) = try await store.participantsBackfillCandidates(limit: 10)
        XCTAssertTrue(rawless.isEmpty, "a blob-backed row is NOT rawless; got \(rawless)")
        XCTAssertEqual(candidates.first?.id, probe.id)
        XCTAssertEqual(candidates.first?.raw, raw)
    }

    // MARK: - Orphan collection

    /// Orphan GC must never delete a blob a row still references. That
    /// asymmetry is the whole point: an orphan costs disk, a
    /// deleted-but-referenced blob loses evidence.
    func testOrphanCollection_neverDeletesAReferencedBlob() async throws {
        let raw = largeRawSource(marker: "orphan-keep")
        let probe = email(rawSource: raw, marker: "orphan-keep")
        try await insert([probe])

        // An unreferenced blob, as a crash between blob write and row commit
        // would leave behind.
        let blobs = store.blobStore
        let strayData = Data(repeating: 0x5A, count: 64)
        let stray = try blobs.write(strayData)

        let (deleted, reclaimed) = try await store.collectBlobOrphans()
        XCTAssertEqual(deleted, 1, "exactly the stray blob should be collected")
        XCTAssertEqual(reclaimed, Int64(strayData.count))
        XCTAssertFalse(blobs.exists(stray))

        let survivingRaw = try await store.fullEmail(id: probe.id)?.rawSource
        XCTAssertEqual(survivingRaw, raw,
                       "the referenced blob must survive collection")
    }

    // MARK: - Footprint

    /// A footprint that counted only `emails.db` would understate a
    /// blob-backed archive by orders of magnitude.
    func testArchiveFootprint_countsTheBlobTier() async throws {
        let probe = email(rawSource: largeRawSource(marker: "footprint"), marker: "footprint")
        try await insert([probe])

        let footprint = StoragePlanner.archiveFootprint(storeDirectory: directory)
        XCTAssertGreaterThan(footprint.blobBytes, 8 * 1_048_576,
                             "the blob tier must be counted: \(footprint.summary)")
        XCTAssertGreaterThan(footprint.databaseBytes, 0)
        XCTAssertGreaterThan(footprint.total, footprint.databaseBytes,
                             "the total must exceed the database alone")
    }

    // MARK: - Damage is reported, not hidden

    /// A row that references bytes which are gone must report the damage, not
    /// silently present the message as having no source — that would send the
    /// backfills off to "heal" a row that is merely unreadable.
    func testMissingBlob_isReportedAsAnAnomaly() async throws {
        let probe = email(rawSource: largeRawSource(marker: "damaged"), marker: "damaged")
        try await insert([probe])

        let digests = try await store.referencedBlobDigests()
        let digest = try XCTUnwrap(digests.first)
        try FileManager.default.removeItem(at: store.blobStore.url(for: digest))

        let readBack = try await store.fullEmail(id: probe.id)
        XCTAssertNotNil(readBack, "the message must still open")
        XCTAssertTrue(readBack?.rawSource.isEmpty ?? false,
                      "there are no bytes to show")
        XCTAssertFalse(readBack?.anomalies.isEmpty ?? true,
                       "a missing blob must be recorded as an anomaly, not hidden")
    }
}
