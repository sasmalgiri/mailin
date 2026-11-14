//
//  ResumeContinuationTests.swift
//  ArchiveCoreTests
//
//  R5 (audit bf1a5b9): the package side of a continuing Resume round.
//   - the container reader lists a file an earlier round read whole and does
//     not extract it again, so the round's budget goes to what stopped;
//   - the store carries that file's row and indexed text to its new place,
//     inside SQLite, while the other files are rewritten;
//   - message depth is its own ceiling and grows one level per round;
//   - the coverage file records a kept Unlock (and gains the column in place).
//  The job-level rows (Resume / Unlock end to end) are testR5_* in the app's
//  V2CutoverTests.
//

import XCTest
import Foundation
import SQLite3
@preconcurrency @testable import ArchiveCore

final class ResumeContinuationTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("r5-continue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ExtractionLimits.baseOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }

    /// A stored (uncompressed) ZIP.
    private static func zip(_ members: [(name: String, data: Data)]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        var local = Data(), central = Data()
        for m in members {
            let name = Array(m.name.utf8)
            let crc = crc32(m.data)
            let size = UInt32(m.data.count)
            let offset = UInt32(local.count)
            local.append(contentsOf: le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                         + le32(crc) + le32(size) + le32(size) + le16(name.count) + le16(0) + name)
            local.append(m.data)
            central.append(contentsOf: le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(crc) + le32(size) + le32(size) + le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(0) + le32(offset) + name)
        }
        var file = local
        file.append(central)
        file.append(contentsOf: le32(0x06054b50) + le16(0) + le16(0) + le16(members.count) + le16(members.count)
                    + le32(UInt32(central.count)) + le32(UInt32(local.count)) + le16(0))
        return file
    }

    private static let members: [(name: String, data: Data)] = [
        ("a.txt", Data((String(repeating: "alpha filler ", count: 68) + "aardvarkword").utf8)),
        ("b.txt", Data((String(repeating: "bravo filler ", count: 68) + "bisonword").utf8)),
        ("c.txt", Data((String(repeating: "charlie fill ", count: 68) + "caracalword").utf8)),
    ]

    func testR5_aCompletedFileIsListedNotReadAgain_soTheRoundsBudgetReachesWhatStopped() throws {
        let url = root.appendingPathComponent("three.zip")
        try Self.zip(Self.members).write(to: url)
        ExtractionLimits.baseOverride = ExtractionLimits(partBytes: 1_000, totalArchiveBytes: 1_000, archiveDepth: 3)
        let round0 = try DocumentTextExtractor.extract(fileURL: url, kind: .zip)
        XCTAssertEqual(round0.children.map { "\($0.path)|\($0.state.rawValue)" }, ["a.txt|extracted", "b.txt|unsupported", "c.txt|unsupported"])

        let round1 = ExtractionLimits.round(1)
        // From the start again: a.txt spends the doubled budget a second time and c.txt still stops.
        let restarted = try ExtractionLimits.$current.withValue(round1) { try DocumentTextExtractor.extract(fileURL: url, kind: .zip) }
        XCTAssertEqual(restarted.children.map(\.state), [.extracted, .extracted, .unsupported])
        // Continuing: a.txt is carried, the budget reads b.txt and c.txt.
        let continued = try ExtractionLimits.$current.withValue(round1) {
            try ExtractionContinuation.$completedPaths.withValue(["a.txt"]) { try DocumentTextExtractor.extract(fileURL: url, kind: .zip) }
        }
        XCTAssertEqual(continued.children.map { "\($0.path)|\($0.state.rawValue)|\($0.carried)" },
                       ["a.txt|extracted|true", "b.txt|extracted|false", "c.txt|extracted|false"])
        XCTAssertNil(continued.children[0].text, "not read again")
        XCTAssertTrue(continued.children[2].text?.contains("caracalword") == true)
        XCTAssertFalse(continued.partial)
        XCTAssertTrue(continued.text.contains("a.txt"), "the listing still names every file")

        // Only completed, unambiguous paths are carried.
        let rows = [("a.txt", "extracted"), ("b.txt", "noText"), ("c.txt", "unsupported"), ("d.txt", "extracted"), ("d.txt", "extracted"), ("e.txt", "locked")]
            .enumerated().map { AttachmentChildRow(emailID: UUID(), position: 0, childIndex: $0.offset, path: $0.element.0, filename: $0.element.0,
                                                   kind: "txt", sha256: "", bytes: 1, state: $0.element.1, note: nil) }
        XCTAssertEqual(ExtractionContinuation.carriablePaths(rows), ["a.txt", "b.txt"])
    }

    func testR5_theStoreCarriesAFilesRowAndTextToItsNewPlace_andRewritesTheRest() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        SearchChunkPolicy.isEnabled = true
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let email = MBOXParser.RawEmail(headers: ["Message-ID": "<r5-carry@x>", "Subject": "Carry", "Date": "Thu, 16 Mar 2017 11:00:00 +0000"],
                                        rawSource: "raw", messageType: "email", attachments: [], timestamp: "", domains: [],
                                        plainBody: "body", htmlBody: "")
        _ = try await store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                        dedupPolicy: .messageID, batchSize: 10, progress: nil)
        func row(_ index: Int, _ path: String, _ state: String, sha: String = "") -> AttachmentChildRow {
            AttachmentChildRow(emailID: email.id, position: 2, childIndex: index, path: path, filename: path, kind: "txt",
                               sha256: sha, bytes: 10, state: state, note: nil)
        }
        try await store.recordAttachmentChildren(emailID: email.id, position: 2,
                                                 children: [row(0, "x.txt", "extracted", sha: "SHA-X"), row(1, "y.txt", "unsupported")],
                                                 texts: [0: "kept words for x", 1: nil], states: [0: .complete, 1: .unsupported], extractorVersion: 9)
        // The next round lists a new file first; x.txt moves from index 0 to 1 and is carried.
        try await store.recordAttachmentChildrenContinuing(
            emailID: email.id, position: 2,
            children: [row(0, "new.txt", "extracted"), row(1, "x.txt", "extracted", sha: "SHA-X"), row(2, "y.txt", "extracted")],
            carriedFrom: [1: 0], texts: [0: "fresh words", 2: "now read words"], states: [0: .complete, 2: .complete], extractorVersion: 10)
        let children = try await store.attachmentChildren(forEmailID: email.id)
        XCTAssertEqual(children.map { "\($0.childIndex)|\($0.path)|\($0.state)|\($0.sha256)" },
                       ["0|new.txt|extracted|", "1|x.txt|extracted|SHA-X", "2|y.txt|extracted|"])
        let carried = try await store.searchChunks(emailID: email.id, kind: .childText, ordinal: SearchDocKind.childOrdinal(parent: 2, child: 1))
        XCTAssertEqual(carried, ["kept words for x"], "the carried file's indexed text moved with it")
        let fresh = try await store.searchChunks(emailID: email.id, kind: .childText, ordinal: SearchDocKind.childOrdinal(parent: 2, child: 0))
        XCTAssertEqual(fresh, ["fresh words"])
        let read = try await store.searchChunks(emailID: email.id, kind: .childText, ordinal: SearchDocKind.childOrdinal(parent: 2, child: 2))
        XCTAssertEqual(read, ["now read words"])
        let stale = try await store.searchChunks(emailID: email.id, kind: .childText, ordinal: SearchDocKind.childOrdinal(parent: 2, child: 3))
        XCTAssertTrue(stale.isEmpty)
    }

    func testR5_messageDepthIsItsOwnCeiling_growingOneLevelPerRound() {
        XCTAssertEqual(ExtractionLimits.base.messageDepth, 3)
        XCTAssertEqual(ExtractionLimits.round(0).messageDepth, 3)
        XCTAssertEqual(ExtractionLimits.round(3).messageDepth, 6)
        XCTAssertEqual(ExtractionLimits.round(3).archiveDepth, 6)
        XCTAssertEqual(ExtractionLimits.effective.messageDepth, 3)
        XCTAssertEqual(ExtractionLimits.$current.withValue(ExtractionLimits.round(2)) { ExtractionLimits.effective.messageDepth }, 5)
        XCTAssertTrue(ExtractionLimits.base.summary.hasSuffix("3 levels, 3 message levels"), ExtractionLimits.base.summary)
        XCTAssertTrue(ExtractionLimits.noteNamesALimit("not read: x.eml (a message nested deeper than 3 levels)"))
    }

    func testR5_coverageRecordsAKeptUnlock_andAnOlderFileGainsTheColumn() throws {
        // A coverage file as written before R5: no `unlocked` column.
        let url = root.appendingPathComponent("coverage.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE coverage(email_id TEXT NOT NULL, ordinal INTEGER NOT NULL, filename TEXT NOT NULL, mime_type TEXT NOT NULL,
                state TEXT NOT NULL, extractor TEXT NOT NULL, extractor_version INTEGER NOT NULL, characters INTEGER NOT NULL DEFAULT 0,
                note TEXT, updated_at INTEGER NOT NULL, resume_round INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(email_id, ordinal));
            INSERT INTO coverage VALUES ('00000000-0000-0000-0000-000000000001', 0, 'old.zip', 'application/zip', 'partial', 'archive', 9, 5, 'n', 0, 1);
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let coverage = try AttachmentCoverageStore(url: url)
        let old = try XCTUnwrap(try coverage.rows(for: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!).first)
        XCTAssertEqual(old.resumeRound, 1, "the earlier row is kept")
        XCTAssertFalse(old.unlockedWithPassword)
        let id = UUID()
        var row = AttachmentCoverageRow(emailID: id, ordinal: 3, filename: "s.zip", mimeType: "application/zip", state: .partial,
                                        extractor: "archive", extractorVersion: 10, characters: 4, note: nil, resumeRound: 2)
        row.unlockedWithPassword = true
        try coverage.record(row: row)
        XCTAssertEqual(try coverage.rows(for: id).first?.unlockedWithPassword, true)
        try coverage.record(emailID: id, rows: [row])
        XCTAssertEqual(try coverage.rows(for: id).first, row)
    }
}
