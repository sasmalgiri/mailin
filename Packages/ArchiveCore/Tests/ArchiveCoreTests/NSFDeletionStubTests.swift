//
//  NSFDeletionStubTests.swift
//  ArchiveCoreTests
//
//  3.0 B3: Lotus Notes deletion stubs, on synthetic NSF files written here
//  (owner, 2026-10-14: "do it yourself with your synthetic document"). Two
//  databases with a known number of deleted documents: the stub count must
//  equal it, the content of no live email may be lost or marked, and with
//  recovery off the import is exactly what it was before.
//
//  The files use the item-record layout mailin's NSF reader reads (type,
//  name length, value length, name, value) and the public stub facts
//  (RRV_DELETED = 0x80000000 in the note ID; identity only). They prove the
//  pipeline, not compatibility with a database written by HCL Notes.
//

import XCTest
@testable import ArchiveCore

final class NSFDeletionStubTests: XCTestCase {
    private var dir: URL!
    private var wasRecovery = false

    override func setUpWithError() throws {
        wasRecovery = RecoveryPolicy.isEnabled
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nsfstub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        RecoveryPolicy.isEnabled = wasRecovery
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: Synthetic NSF writer

    private static func item(_ name: String, _ value: String, type: UInt16 = 0x0500) -> Data {
        var d = Data()
        let n = Data(name.utf8), v = Data(value.utf8)
        withUnsafeBytes(of: type.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(n.count).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(v.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(n); d.append(v)
        return d
    }

    private static func unid(_ i: Int, _ salt: Int) -> String { String(format: "%016X%016X", 0xA1B2_0000 + salt, i) }

    /// `mails` mail documents with `stubs` deletion stubs spread between them
    /// (every n-th position); `identityOnlyStub` adds one stub without the
    /// deleted bit at the end of the file.
    static func writeNSF(to url: URL, mails: Int, stubs: Int, identityOnlyStub: Bool = false, salt: Int) throws {
        var file = Data([0x1A, 0x00])
        file.append(Data(repeating: 0, count: 254))
        // Offset 0x28: where the note records begin.
        let start = UInt32(256)
        withUnsafeBytes(of: start.littleEndian) { file.replaceSubrange(0x28..<0x2C, with: $0) }
        var stubPositions = Set<Int>()
        if stubs > 0 { for k in 0..<stubs { stubPositions.insert(k * mails / stubs) } }
        var noteID: UInt32 = 0x0000_0102
        for i in 0..<mails {
            if stubPositions.contains(i) {
                let deletedID = String(format: "0x%08X", noteID | NSFDeletionStub.rrvDeleted)
                file.append(item("UNID", unid(i, salt + 1)))
                file.append(item("$Seq", "\(3 + i % 4)"))
                file.append(item("$Modified", String(format: "03/%02d/2024 10:15:00", 1 + i % 28)))
                file.append(item("$NoteID", deletedID))
                noteID += 4
            }
            file.append(item("Subject", "Quarterly report \(i)"))
            file.append(item("From", "CN=Sender \(i % 25)/O=Acme"))
            file.append(item("SendTo", "CN=Team/O=Acme"))
            file.append(item("DeliveredDate", String(format: "02/%02d/2024 09:%02d:00", 1 + i % 28, i % 60)))
            file.append(item("$MessageID", "<nsf-\(salt)-\(i)@acme.example>"))
            file.append(item("UNID", unid(i, salt)))
            file.append(item("Body", "Body of document \(i)."))
            file.append(item("Form", "Memo"))
            noteID += 4
        }
        if identityOnlyStub {
            file.append(item("UNID", unid(999_999, salt + 2)))
            file.append(item("$Seq", "9"))
            file.append(item("$DeletedDate", "04/01/2024 08:00:00"))
        }
        file.append(Data(repeating: 0, count: 128))
        try file.write(to: url)
    }

    // MARK: Tests

    func testDeletionStubs_twoDatabases_countsEqualTheDeletedDocuments() throws {
        RecoveryPolicy.isEnabled = true
        for (name, stubs, identityOnly) in [("purge-on.nsf", 37, false), ("purge-off.nsf", 120, true)] {
            let url = dir.appendingPathComponent(name)
            try Self.writeNSF(to: url, mails: 1_000, stubs: stubs, identityOnlyStub: identityOnly, salt: stubs)
            let rows = try NSFParser.parse(fileURL: url, senderEmail: "")
            let marked = rows.filter { $0.recovery?.state == .deletionStub }
            let expected = stubs + (identityOnly ? 1 : 0)
            XCTAssertEqual(marked.count, expected, "\(name): one row per deleted document")
            XCTAssertTrue(marked.allSatisfy { $0.recovery?.partial == true && $0.plainBody.isEmpty }, name)
            XCTAssertEqual(marked.filter { $0.recovery?.evidence.contains("RRV_DELETED") == true }.count, stubs, name)
            if identityOnly {
                XCTAssertEqual(marked.filter { $0.recovery?.evidence.contains("identity") == true }.count, 1, name)
            }
            // Every stub keeps its UNID; no two stubs share one.
            let unids = marked.compactMap { $0.headers["X-Notes-UNID"] }
            XCTAssertEqual(Set(unids).count, expected, name)

            // Live mail: all 1,000, none marked, nothing lost to a neighbouring stub.
            let live = rows.filter { $0.recovery == nil }
            XCTAssertEqual(live.count, 1_000, name)
            XCTAssertEqual(Set(live.map { $0.headers["Subject"] ?? "" }).count, 1_000, name)
            XCTAssertTrue(live.allSatisfy { $0.plainBody.hasPrefix("Body of document") }, name)
        }
    }

    func testDeletionStubs_recoveryOff_importIsUnchanged() throws {
        let url = dir.appendingPathComponent("off.nsf")
        try Self.writeNSF(to: url, mails: 1_000, stubs: 37, identityOnlyStub: true, salt: 7)
        RecoveryPolicy.isEnabled = false
        let rows = try NSFParser.parse(fileURL: url, senderEmail: "")
        XCTAssertEqual(rows.count, 1_000, "stubs are not imported while recovery is off")
        XCTAssertTrue(rows.allSatisfy { $0.recovery == nil })
        XCTAssertEqual(Set(rows.map { $0.headers["Message-ID"] ?? "" }).count, 1_000)
    }

    func testDeletionStubs_stored_countedAndFoundByQuery() async throws {
        RecoveryPolicy.isEnabled = true
        let url = dir.appendingPathComponent("store.nsf")
        try Self.writeNSF(to: url, mails: 1_000, stubs: 37, salt: 11)
        let rows = try NSFParser.parse(fileURL: url, senderEmail: "")
        let store = SQLiteEmailStore(directory: dir.appendingPathComponent("store", isDirectory: true))
        _ = try await store.insertBatch(rows, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                        dedupPolicy: .messageID, batchSize: 250, progress: nil)
        let counts = try await store.recoveryCounts()
        XCTAssertEqual(counts[.deletionStub], 37)
        XCTAssertEqual(counts.partial, 37)
        let found = try await store.filteredCount(ArchiveQueryCompiler.compile("recovery:stub"))
        XCTAssertEqual(found, 37)
        let total = try await store.count(after: nil, before: nil)
        XCTAssertEqual(total, 1_037)
    }

    func testNoteID_deletedBit() {
        XCTAssertTrue(NSFDeletionStub.isDeletedID("0x8000010A"))
        XCTAssertTrue(NSFDeletionStub.isDeletedID("8000010A"))
        XCTAssertFalse(NSFDeletionStub.isDeletedID("0x0000010A"))
        XCTAssertFalse(NSFDeletionStub.isDeletedID("266"))
        XCTAssertFalse(NSFDeletionStub.isDeletedID(nil))
    }
}
