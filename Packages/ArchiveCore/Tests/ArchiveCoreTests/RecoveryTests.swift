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

// MARK: - R5/R6 PST folder tree and orphans (fixture written by PSTStreamWriter)

final class PSTRecoveryTests: XCTestCase {
    private var was = false
    override func setUp() { super.setUp(); was = RecoveryPolicy.isEnabled; RecoveryPolicy.isEnabled = true }
    override func tearDown() { RecoveryPolicy.isEnabled = was; super.tearDown() }

    private func email(_ n: Int) throws -> MBOXParser.RawEmail {
        try MBOXParser.processRawMessage("""
            From: s\(n)@example.com
            To: r@example.org
            Subject: PST \(n)
            Date: Mon, 6 Jan 2025 10:00:00 +0000
            Message-ID: <pst\(n)@example.com>
            Content-Type: text/plain

            body \(n)
            """, senderEmail: "")
    }

    func testFolderPaths_deletedItems_andOrphans_matchTheFixture() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString).pst")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try PSTStreamWriter(url: url)
        let inbox = w.appendFolder(name: "Inbox")
        let deleted = w.appendFolder(name: "Deleted Items")
        let purges = w.appendFolder(name: "Purges", parent: w.appendFolder(name: "Recoverable Items"))
        try w.append(email: try email(1), folder: inbox)
        try w.append(email: try email(2), folder: inbox)
        try w.append(email: try email(3), folder: deleted)
        try w.append(email: try email(4), folder: purges)
        try w.append(email: try email(5), folder: (0x7777 << 5) | 0x02)   // its folder is gone
        try w.finalize()

        let emails = try PSTParser.parse(fileURL: url, senderEmail: "")
        let bySubject = Dictionary(uniqueKeysWithValues: emails.compactMap { e in e.headers["Subject"].map { ($0, e) } })
        XCTAssertEqual(emails.count, 5)
        XCTAssertNil(bySubject["PST 1"]?.recovery, "Inbox mail is live")
        XCTAssertEqual(bySubject["PST 3"]?.recovery?.state, .deletedFolder)
        XCTAssertEqual(bySubject["PST 3"]?.recovery?.folder, "Top of Personal Folders/Deleted Items")
        XCTAssertEqual(bySubject["PST 4"]?.recovery?.state, .deletedFolder, "Recoverable Items/Purges counts as deleted")
        XCTAssertEqual(bySubject["PST 5"]?.recovery?.state, .orphan)
    }

    func testOldStylePST_withoutParents_claimsNothing() throws {
        // A PST whose messages carry nidParent 0 (as written before 3.1) is not called orphaned.
        RecoveryPolicy.isEnabled = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString).pst")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try PSTWriter.write(emails: [try email(9)], to: url)
        RecoveryPolicy.isEnabled = true
        let emails = try PSTParser.parse(fileURL: url, senderEmail: "")
        XCTAssertEqual(emails.count, 1)
        XCTAssertNil(emails.first?.recovery, "messages in the root folder are live")
    }
}

// MARK: - R10/S5 receipt fields, R11 custodian bursts

final class RecoveryReceiptTests: XCTestCase {
    func testReceipt_recoveryScriptsAndHeaderOnlyCount_surviveSaveAndVerify() throws {
        var r = ImportReceipt(startedAt: Date(timeIntervalSince1970: 1_700_000_000), completedAt: Date(timeIntervalSince1970: 1_700_000_100))
        var rec = RecoveryCounts()
        rec.byState = [.unpurged: 3, .carved: 2, .deletedFolder: 5]
        rec.partial = 1
        r.recovery = rec
        r.scriptActions = ["Date filter v1: 12 exclude"]
        r.bodiesNotDecoded = 4
        try r.finalize()
        // Encoding is stable (the dictionary is a sorted JSON object), so the
        // hash is the same every time.
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        for _ in 0..<5 {
            let back = try dec.decode(ImportReceipt.self, from: try enc.encode(r))
            XCTAssertEqual(back.recovery, rec)
            XCTAssertEqual(back.scriptActions, ["Date filter v1: 12 exclude"])
            XCTAssertEqual(back.bodiesNotDecoded, 4, "was dropped on decode before 3.1")
            XCTAssertTrue(back.verify(), "a reloaded receipt still verifies")
        }
    }

    func testCustodianBurst() async throws {
        let was = RecoveryPolicy.isEnabled
        RecoveryPolicy.isEnabled = true
        defer { RecoveryPolicy.isEnabled = was }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SQLiteEmailStore(directory: dir)
        var emails: [MBOXParser.RawEmail] = []
        // Ann: 12 deleted in one week (burst) + 2 spread out. Bo: 3 spread out.
        func make(_ n: Int, _ date: String) throws -> MBOXParser.RawEmail {
            try MBOXParser.processRawMessage("From: x\(n)@example.com\nSubject: m\(n)\nDate: \(date)\nMessage-ID: <b\(n)@x>\nX-Mozilla-Status: 0009\n\nb\n", senderEmail: "")
        }
        for i in 0..<12 { emails.append(try make(i, "Tue, \(4 + i % 3) Jun 2024 10:00:00 +0000")) }
        emails.append(try make(20, "Mon, 5 Feb 2024 10:00:00 +0000"))
        emails.append(try make(21, "Mon, 7 Oct 2024 10:00:00 +0000"))
        for i in 30..<33 { emails.append(try make(i, "Mon, \(i - 28) Jan 2024 10:00:00 +0000")) }
        _ = try await store.insertBatch(emails, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                        dedupPolicy: .messageID, batchSize: 100, progress: nil)
        var map: [UUID: String] = [:]
        for e in emails.prefix(14) { map[e.id] = "Ann" }
        for e in emails.suffix(3) { map[e.id] = "Bo" }
        _ = try await store.custodiansAssign(map)
        let a = try await store.deletionAnalysis()
        let ann = try XCTUnwrap(a.custodians.first { $0.custodian == "Ann" })
        XCTAssertEqual(ann.recovered, 14)
        XCTAssertEqual(ann.busiestWeekCount, 12)
        XCTAssertTrue(ann.isBurst)
        let bo = try XCTUnwrap(a.custodians.first { $0.custodian == "Bo" })
        XCTAssertFalse(bo.isBurst)
    }
}
