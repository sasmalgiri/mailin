//
//  RecoveryTests.swift
//  ArchiveCoreTests
//
//  3.1 R1–R4, R9–R11: deleted-email recovery — detectors, schema v20 store,
//  search filters, carving, report pages and deletion analysis. Generated
//  messages only; never real mail.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class RecoveryTests: XCTestCase {
    private var wasEnabled = false
    private var wasDeep = false
    private var dir: URL!

    override func setUp() {
        super.setUp()
        wasEnabled = RecoveryPolicy.isEnabled
        wasDeep = RecoveryPolicy.deepRecoveryEnabled
        RecoveryPolicy.isEnabled = true
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        RecoveryPolicy.isEnabled = wasEnabled
        RecoveryPolicy.deepRecoveryEnabled = wasDeep
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func message(_ n: Int, extra: String = "", date: String = "Mon, 6 Jan 2025 10:00:00 +0000") -> String {
        """
        From: Sender \(n) <sender\(n)@example.com>
        To: someone@example.org
        Subject: Message \(n)
        Date: \(date)
        Message-ID: <msg\(n)@example.com>
        \(extra)Content-Type: text/plain

        Body of message \(n).

        """
    }

    // MARK: R3/R4 detectors

    func testMozillaExpungedBit_isUnpurged_withFlagAsEvidence() throws {
        let e = try MBOXParser.processRawMessage(message(1, extra: "X-Mozilla-Status: 0009\n"), senderEmail: "")
        XCTAssertEqual(e.recovery?.state, .unpurged)
        XCTAssertEqual(e.recovery?.method, "x-mozilla-status")
        XCTAssertTrue(e.recovery?.evidence.contains("0009") ?? false)
    }

    func testMozillaReadOnly_isLive() throws {
        let e = try MBOXParser.processRawMessage(message(2, extra: "X-Mozilla-Status: 0001\n"), senderEmail: "")
        XCTAssertNil(e.recovery)
    }

    func testXStatusD_isFlaggedDeleted() {
        let r = RecoveryDetector.fromHeaders(["X-Status": "RD"], labels: [])
        XCTAssertEqual(r?.state, .flaggedDeleted)
    }

    func testGmailTrashLabel_isDeletedFolder() {
        let r = RecoveryDetector.fromHeaders([:], labels: ["Inbox", "Trash"])
        XCTAssertEqual(r?.state, .deletedFolder)
        XCTAssertEqual(r?.folder, "Trash")
    }

    func testDeletedFolderNames_areMultilingual_andPathAware() {
        XCTAssertTrue(DeletedFolderNames.isDeleted(path: "Top of Personal Folders/Deleted Items"))
        XCTAssertTrue(DeletedFolderNames.isDeleted(path: "Recoverable Items/Purges"))
        XCTAssertFalse(DeletedFolderNames.isDeleted(path: "Inbox/Projects"))
    }

    func testEMLXDeletedFlag() {
        XCTAssertEqual(RecoveryDetector.fromEMLX(flags: 0x02, mailboxPath: "INBOX")?.state, .flaggedDeleted)
        XCTAssertEqual(RecoveryDetector.fromEMLX(flags: 0, mailboxPath: "Deleted Messages")?.state, .deletedFolder)
        XCTAssertNil(RecoveryDetector.fromEMLX(flags: 0, mailboxPath: "INBOX"))
    }

    func testPolicyOff_detectsNothing() throws {
        RecoveryPolicy.isEnabled = false
        let e = try MBOXParser.processRawMessage(message(3, extra: "X-Mozilla-Status: 0009\n"), senderEmail: "")
        XCTAssertNil(e.recovery, "default imports are unchanged while the switch is off")
    }

    // MARK: R2 search syntax

    func testQuerySyntax() {
        XCTAssertEqual(ArchiveQueryCompiler.compile("is:recovered").recovery, "any")
        XCTAssertEqual(ArchiveQueryCompiler.compile("recovery:unpurged").recovery, RecoveryState.unpurged.rawValue)
        XCTAssertEqual(ArchiveQueryCompiler.compile("recovery:deletionStub").recovery, RecoveryState.deletionStub.rawValue)
        let neg = ArchiveQueryCompiler.compile("-is:recovered", exclusions: true)
        XCTAssertEqual(neg.exclusions?.first?.field, .recovered)
    }

    // MARK: R1/R2/R10/R11 store

    private func seededStore() async throws -> (SQLiteEmailStore, [MBOXParser.RawEmail]) {
        let store = SQLiteEmailStore(directory: dir)
        var emails: [MBOXParser.RawEmail] = []
        emails.append(try MBOXParser.processRawMessage(message(1, date: "Mon, 6 Jan 2025 10:00:00 +0000"), senderEmail: ""))
        emails.append(try MBOXParser.processRawMessage(message(2, extra: "X-Mozilla-Status: 0009\n", date: "Tue, 7 Jan 2025 10:00:00 +0000"), senderEmail: ""))
        emails.append(try MBOXParser.processRawMessage(message(3, extra: "X-Status: D\n", date: "Wed, 8 Jan 2025 10:00:00 +0000"), senderEmail: ""))
        var carved = try MBOXParser.processRawMessage(message(4, date: "Sat, 1 Mar 2025 10:00:00 +0000"), senderEmail: "")
        carved.recovery = RecoveryInfo(state: .carved, method: "mime-carve", evidence: "byte 99", offset: 99, partial: true)
        emails.append(carved)
        _ = try await store.insertBatch(emails, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                        dedupPolicy: .messageID, batchSize: 100, progress: nil)
        return (store, emails)
    }

    func testStore_countsByKind_andFilters() async throws {
        let (store, emails) = try await seededStore()
        let c = try await store.recoveryCounts()
        XCTAssertEqual(c[.live], 1)
        XCTAssertEqual(c[.unpurged], 1)
        XCTAssertEqual(c[.flaggedDeleted], 1)
        XCTAssertEqual(c[.carved], 1)
        XCTAssertEqual(c.recovered, 3)
        XCTAssertEqual(c.partial, 1)

        var any = EmailQuery(); any.recovery = "any"
        let anyCount = try await store.filteredCount(any)
        XCTAssertEqual(anyCount, 3)
        var unpurged = EmailQuery(); unpurged.recovery = RecoveryState.unpurged.rawValue
        let unpurgedCount = try await store.filteredCount(unpurged)
        XCTAssertEqual(unpurgedCount, 1)
        var notRecovered = EmailQuery(); notRecovered.exclusions = [EmailExclusion(field: .recovered, value: "")]
        let liveCount = try await store.filteredCount(notRecovered)
        XCTAssertEqual(liveCount, 1)

        let info = try await store.recovery(for: [emails[3].id])
        XCTAssertEqual(info[emails[3].id]?.offset, 99)
        XCTAssertEqual(info[emails[3].id]?.partial, true)
    }

    func testReportPages_coverEveryRecoveredEmail_inDateOrder() async throws {
        let (store, _) = try await seededStore()
        var seen: [RecoveryReportRow] = []
        try await store.forEachRecovered(pageSize: 1) { seen += $0 }
        XCTAssertEqual(seen.count, 3, "paging by one row still returns every recovered email")
        XCTAssertEqual(seen.map(\.date), seen.map(\.date).sorted())
        XCTAssertEqual(Set(seen.map(\.info.state)), [.unpurged, .flaggedDeleted, .carved])
    }

    func testDeletionAnalysis_countsRecoveredMailDatedBeforeTheHold() async throws {
        let (store, emails) = try await seededStore()
        // Hold placed now on the live email: all three recovered emails (2025) are dated before it.
        _ = try await store.legalHoldsAdd([emails[0].id, emails[1].id], matter: "Matter A", sync: true)
        let a = try await store.deletionAnalysis()
        XCTAssertEqual(a.recovered, 3)
        XCTAssertEqual(a.recoveredOnHold, 1)
        XCTAssertEqual(a.matters.first?.matter, "Matter A")
        XCTAssertEqual(a.matters.first?.recoveredBeforeHold, 3)
        XCTAssertEqual(a.byMonth["2025-01"], 2)
        XCTAssertEqual(a.byMonth["2025-03"], 1)
    }

    // MARK: R9 carving

    func testCarver_findsEmbeddedMessages_andNothingInRandomBytes() async throws {
        var blob = Data((0..<300_000).map { _ in UInt8.random(in: 0...255) })
        blob.append(Data(("\n" + message(10)).utf8))
        blob.append(Data((0..<200_000).map { _ in UInt8.random(in: 0...255) }))
        blob.append(Data(("\n" + message(11)).utf8))
        blob.append(Data((0..<100_000).map { _ in UInt8.random(in: 0...255) }))
        let url = dir.appendingPathComponent("blob.bin")
        try blob.write(to: url)

        var emitted: [MBOXParser.RawEmail] = []
        let r = try await MIMECarver.carve(url: url, batchSize: 1, emit: { emitted += $0 })
        XCTAssertEqual(r.kept, 2)
        XCTAssertTrue(r.emails.isEmpty, "with emit, nothing is held")
        XCTAssertEqual(Set(emitted.compactMap { $0.headers["Subject"] }), ["Message 10", "Message 11"])
        XCTAssertTrue(emitted.allSatisfy { $0.recovery?.state == .carved && ($0.recovery?.offset ?? 0) > 0 })
    }

    func testCarver_randomDataOnly_yieldsNothing() async throws {
        let url = dir.appendingPathComponent("random.bin")
        try Data((0..<2_000_000).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        let r = try await MIMECarver.carve(url: url)
        XCTAssertEqual(r.kept, 0, "zero false positives on random data")
    }

    func testCarver_damagedMbox_everyMessageFound() async throws {
        var text = ""
        for n in 20..<25 { text += "From sender\(n)@example.com Mon Jan  6 10:00:00 2025\n" + message(n) + "\n" }
        // Damage: cut the middle of the file's first separator line.
        text.removeSubrange(text.startIndex..<text.index(text.startIndex, offsetBy: 10))
        let url = dir.appendingPathComponent("damaged.mbox")
        try Data(text.utf8).write(to: url)
        let r = try await MIMECarver.carve(url: url)
        XCTAssertEqual(r.kept, 5)
        XCTAssertEqual(Set(r.emails.compactMap { $0.headers["Subject"] }).count, 5)
    }

    func testCarvingTemplate_hexMarkers() {
        XCTAssertEqual(CarvingTemplate.bytes("hex:0A 0b"), [0x0A, 0x0B])
        XCTAssertEqual(CarvingTemplate.bytes("ab"), [0x61, 0x62])
    }
}
