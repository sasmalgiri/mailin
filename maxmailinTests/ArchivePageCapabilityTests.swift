//
//  ArchivePageCapabilityTests.swift
//  maxmailinTests
//
//  Answers the direct question: on Page 1 (Archive), can a user READ an
//  attachment, SEARCH, and EXPORT — against the real owner-supplied corpus,
//  through the production import path, with the archive read back from the
//  store rather than from the parser's in-memory output.
//
//  Reading from the STORE is the point. A test that checks the parser's output
//  proves nothing about the archive, because parse-time attachment temp files
//  do not survive and the store deliberately keeps only the raw MIME.
//

import XCTest
@testable import maxmailin

final class ArchivePageCapabilityTests: XCTestCase {

    /// Temp roots created by this test case, removed in `tearDown`.
    ///
    /// Each test used to leak its root — three ~300 MB SQLite + FTS trees per
    /// run — with a comment explaining that deleting it races
    /// BulkImportCoordinator's deferred budget-restore Task. True, but leaking
    /// was worse: the roots live under the app container's tmp, which macOS
    /// treats as purgeable, so the OS unlinked those files WHILE SQLite still
    /// had them open. libsqlite3 logged "vnode unlinked while in use" and the
    /// next statement failed as `step("disk I/O error")` — which reads as a
    /// store bug and is not one, the exact misreading the export test's own
    /// comment warns about. It made the suite fail intermittently depending on
    /// how much garbage previous runs had left behind.
    ///
    /// Removing them here instead, after a grace period for that deferred
    /// Task, keeps the cleanup deterministic and off the critical path.
    private var roots: [URL] = []

    override func tearDown() async throws {
        // Let the coordinator's deferred budget-restore finish before the
        // directory goes away underneath it.
        try? await Task.sleep(nanoseconds: 500_000_000)
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    private static var fixtureURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Mail/Sent.mbox")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Imports the fixture through the production coordinator into disposable
    /// storage and returns the live store/index.
    private func importFixture() async throws
        -> (store: SQLiteEmailStore, fts: FTSSearchIndex, root: URL, summary: BulkImportCoordinator.RunSummary) {
        guard let fixture = Self.fixtureURL else {
            throw XCTSkip("fixture ~/Downloads/Mail/Sent.mbox not present")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-caps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try MailinStorageEnvironment.assertNotProduction(root)
        roots.append(root)

        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let checkpoints = ImportCheckpointStore(storeURL: root.appendingPathComponent("cp.json"))
        let coordinator = await BulkImportCoordinator(
            store: store, fts: fts, checkpoints: checkpoints,
            requiresStorageActivation: false)
        let summary = try await coordinator.runImport(urls: [fixture])
        return (store, fts, root, summary)
    }

    // MARK: - 1. Read an attachment out of the archive

    func testArchive_canReadAttachmentBytesFromStoredEmail() async throws {
        let (store, _, root, _) = try await importFixture()
        // `root` is removed in tearDown — see the note on `roots`.

        // Find a STORED email that has attachments, reading it back the way the
        // detail view does.
        var subject: MBOXParser.RawEmail?
        var cursorDate: Date?
        var cursorID: UUID?
        pages: for _ in 0..<10 {
            let page = try await store.summaryPage(
                after: nil, before: nil,
                cursorDate: cursorDate, cursorID: cursorID, limit: 200)
            if page.isEmpty { break }
            for summaryRow in page {
                if let full = try await store.fullEmail(id: summaryRow.id),
                   !full.attachments.isEmpty {
                    subject = full
                    break pages
                }
            }
            cursorDate = page.last?.date
            cursorID = page.last?.id
        }

        let email = try XCTUnwrap(subject, "the fixture should contain attachments")
        XCTAssertFalse(email.rawSource.isEmpty, "the store must persist raw MIME")

        // The pre-fix behaviour: a stored attachment has no live temp file and
        // no inline payload, which is exactly why reads used to fail.
        let att = email.attachments[0]
        XCTAssertNil(att.base64, "stored attachments carry no inline payload")

        // The fix: bytes are recovered from the raw MIME.
        let cache = AttachmentHydrator.Cache()
        let data = AttachmentHydrator.data(for: att, index: 0, email: email, cache: cache)
        let bytes = try XCTUnwrap(data, "attachment bytes must be recoverable from the archive")
        XCTAssertGreaterThan(bytes.count, 0)
        XCTAssertTrue(AttachmentHydrator.canRead(att, index: 0, email: email))

        print("""
        ARCHIVE-CAPABILITY attachment filename=\(att.filename) \
        declaredSize=\(att.size) recoveredBytes=\(bytes.count)
        """)
    }

    // MARK: - 2. Search the archive

    func testArchive_searchFindsStoredMessages() async throws {
        let (store, fts, root, _) = try await importFixture()
        // `root` is removed in tearDown — see the note on `roots`.

        let total = try await store.totalCount()
        XCTAssertGreaterThan(total, 0)

        // Index coverage first: a search cannot be honest if the index is behind.
        let indexed = try await fts.rowCount()
        XCTAssertEqual(indexed, total, "every stored message must be searchable")

        // Take a real token from a real stored message, then find it by search.
        let page = try await store.summaryPage(
            after: nil, before: nil, cursorDate: nil, cursorID: nil, limit: 1)
        let firstID: UUID = try XCTUnwrap(page.first?.id)
        let fetched = try await store.fullEmail(id: firstID)
        let first = try XCTUnwrap(fetched)
        let token = (first.headers["Subject"] ?? "")
            .components(separatedBy: .whitespaces)
            .first { $0.count > 4 && $0.allSatisfy(\.isLetter) }

        if let token {
            let hits = try await fts.searchRaw(FTSQueryBuilder.escapeTerm(token), limit: 50)
            XCTAssertFalse(hits.isEmpty, "a token from a stored subject must be findable")
            print("ARCHIVE-CAPABILITY search token=\(token) hits=\(hits.count) of \(total)")
        } else {
            print("ARCHIVE-CAPABILITY search skipped — no alphabetic subject token in the first message")
        }
    }

    // MARK: - 3. Export the archive

    func testArchive_exportsMBOXThatReparses() async throws {
        // Imports ~95 MB and exports ~95 MB through SQLite. On a full volume
        // this failed as `step("disk I/O error")`, which reads as a store bug
        // and is not one — see TestPreconditions.
        try TestPreconditions.requireFreeSpace(TestPreconditions.referenceFixtureBudget)
        let (store, fts, root, _) = try await importFixture()
        // `root` is removed in tearDown — see the note on `roots`.

        let repo = EmailStoreRepository(store: store, fts: fts)
        let service = await ArchiveExportService(archive: ArchiveDataService(repository: repo))
        let out = root.appendingPathComponent("export.mbox")

        // Whole archive: every message matching an unconstrained query.
        let wholeArchive = ArchiveSelectionScope.query(EmailQuery(), exclusions: [])
        let result = try await service.exportMBOXArchive(scope: wholeArchive, to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))

        // Round-trip: the export must re-parse to the same message count, which
        // is the only claim that means anything for a handoff file.
        var reparsed = 0
        _ = try await MBOXParser.parseStreamingCallback(
            fileURL: out, senderEmail: "", batchSize: 200
        ) { batch in reparsed += batch.count }

        let stored = try await store.totalCount()
        XCTAssertEqual(reparsed, stored, "export must round-trip every stored message")

        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.intValue ?? 0
        print("""
        ARCHIVE-CAPABILITY export requested=\(stored) written=\(result.recordsWritten) sha=\(result.sha256Hex?.prefix(12) ?? "none") \
        reparsed=\(reparsed) bytes=\(size)
        """)
    }
}
