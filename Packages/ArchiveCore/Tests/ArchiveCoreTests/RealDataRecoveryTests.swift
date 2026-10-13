//
//  RealDataRecoveryTests.swift
//  ArchiveCoreTests
//
//  Recovery against REAL public mail: Digital Corpora "filetypes1" Outlook PSTs
//  and Thunderbird mailboxes (free to use, digitalcorpora.org). The files are
//  not committed; `Scripts/fetch_open_fixtures.sh` downloads them, and
//  `MAILIN_REAL_FIXTURES=<dir>` turns the tests on. The expected numbers in
//  Fixtures/real/ were produced by independent tools — `readpst -D -S`
//  (libpst) for the PSTs, and a separate X-Mozilla-Status scan for Thunderbird —
//  never by mailin itself.
//

import XCTest
import Foundation
import CryptoKit
@testable import ArchiveCore

final class RealDataRecoveryTests: XCTestCase {
    private var root: URL?
    private var was = false
    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAILIN_REAL_FIXTURES"] else {
            throw XCTSkip("opt-in: MAILIN_REAL_FIXTURES=<dir> (see Scripts/fetch_open_fixtures.sh)")
        }
        root = URL(fileURLWithPath: dir)
        was = RecoveryPolicy.isEnabled
        RecoveryPolicy.isEnabled = true
    }
    override func tearDown() { RecoveryPolicy.isEnabled = was; super.tearDown() }

    private func manifest<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/real/\(name)")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    func testThunderbird_unpurgedCountsEqualTheIndependentScan() throws {
        struct Entry: Decodable { let messages: Int; let expunged: Int }
        let expected = try manifest("tbird-manifest.json", as: [String: Entry].self)
        var report: [String] = []
        for (file, e) in expected.sorted(by: { $0.key < $1.key }) where e.messages > 0 {
            let url = root!.appendingPathComponent("Tbird/Tbird/\(file)")
            let emails = try MBOXParser.parse(fileURL: url, senderEmail: "")
            let unpurged = emails.filter { $0.recovery?.state == .unpurged }.count
            if emails.count != e.messages || unpurged != e.expunged {
                report.append("\(file): messages \(emails.count)/\(e.messages), unpurged \(unpurged)/\(e.expunged)")
            }
        }
        XCTAssertTrue(report.isEmpty, report.joined(separator: "\n"))
    }

    func testOutlookPSTs_deletedItemsEqualReadpst() throws {
        let expected = try manifest("pst-readpst-manifest.json", as: [String: [String: Int]].self)
        var report: [String] = []
        for (file, folders) in expected.sorted(by: { $0.key < $1.key }) {
            let url = root!.appendingPathComponent("PST/PST/\(file)")
            let emails = try PSTParser.parse(fileURL: url, senderEmail: "")
            // Items readpst found in deleted-items folders (Deleted Items, [Gmail]/Trash).
            let deletedExpected = folders.filter { DeletedFolderNames.isDeleted(path: $0.key) }.values.reduce(0, +)
            let deletedFound = emails.filter { $0.recovery?.state == .deletedFolder }.count
            // Manifest = `readpst -t e` (email items only). readpst also writes the one
            // hidden associated "IPM" placeholder item some stores keep; mailin does
            // not import associated (folder-configuration) items, so it may read one fewer.
            let totalExpected = folders.values.reduce(0, +)
            let gap = totalExpected - emails.count
            if deletedFound != deletedExpected || !(0...1).contains(gap) {
                report.append("\(file): deleted-folder \(deletedFound)/\(deletedExpected), items \(emails.count) (readpst \(totalExpected))")
            }
        }
        XCTAssertTrue(report.isEmpty, report.joined(separator: "\n"))
    }

    func testDeepRecovery_onRealPSTs_neverInventsOrDuplicates() throws {
        let deepWas = RecoveryPolicy.deepRecoveryEnabled
        RecoveryPolicy.deepRecoveryEnabled = true
        defer { RecoveryPolicy.deepRecoveryEnabled = deepWas }
        let files = try FileManager.default.contentsOfDirectory(at: root!.appendingPathComponent("PST/PST"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pst" }
        var carvedTotal = 0
        for url in files {
            let emails = try PSTParser.parse(fileURL: url, senderEmail: "")
            let carved = emails.filter { $0.recovery?.state == .carved }
            let listed = Set(emails.filter { $0.recovery?.state != .carved }.compactMap { $0.headers["Subject"] })
            for c in carved {
                XCTAssertEqual(c.recovery?.partial, true)
                XCTAssertGreaterThan(c.recovery?.offset ?? 0, 0)
                // Text must be readable (no binary noise passed off as mail).
                let text = (c.headers["Subject"] ?? "") + c.plainBody
                XCTAssertFalse(text.unicodeScalars.contains { $0.value < 0x09 }, "\(url.lastPathComponent): carved item contains control bytes")
            }
            carvedTotal += carved.count
            print("DEEP \(url.lastPathComponent): \(emails.count - carved.count) listed, \(carved.count) carved (\(carved.filter { listed.contains($0.headers["Subject"] ?? "") }.count) with a listed subject)")
        }
        print("DEEP total carved: \(carvedTotal)")
    }

    func testThunderbird_throughTheRealImporter_bothEngines() async throws {
        struct Entry: Decodable { let messages: Int; let expunged: Int }
        let expected = try manifest("tbird-manifest.json", as: [String: Entry].self)
        let files = expected.filter { $0.value.messages > 0 }.keys.sorted().map { root!.appendingPathComponent("Tbird/Tbird/\($0)") }
        // The importer skips a source file it has already imported byte for
        // byte (stated in the receipt); the sample set has four such twins.
        var seenHashes = Set<String>()
        var total = 0, unpurged = 0, twins = 0
        for url in files {
            let hash = Data(SHA256.hash(data: try Data(contentsOf: url))).map { String(format: "%02x", $0) }.joined()
            let e = expected[url.lastPathComponent]!
            if seenHashes.insert(hash).inserted { total += e.messages; unpurged += e.expunged } else { twins += 1 }
        }
        for offset in [false, true] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbird-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = SQLiteEmailStore(directory: dir.appendingPathComponent("store", isDirectory: true))
            let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts", isDirectory: true))
            let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                          requiresStorageActivation: false)
            var options = BulkImportCoordinator.Options()
            options.enforceStoragePreflight = false
            options.useOffsetEngine = offset
            options.recordLocators = offset
            options.dedupPolicy = .preserveAll
            let summary = try await coordinator.runImport(urls: files, options: options)
            let stored = try await store.filteredCount(.all)
            let c = try await store.recoveryCounts()
            XCTAssertEqual(stored, total, "offset \(offset): every message imported")
            XCTAssertEqual(c[.unpurged], unpurged, "offset \(offset): unpurged equals the independent scan")
            XCTAssertEqual(summary.receipt?.recovery?[.unpurged], unpurged)
            XCTAssertEqual(summary.receipt?.skipped, twins, "byte-identical files are skipped and counted")
        }
    }

    func testOutlookPSTs_throughTheRealImporter() async throws {
        let expected = try manifest("pst-readpst-manifest.json", as: [String: [String: Int]].self)
        var seen = Set<String>()
        var files: [URL] = []
        var deletedExpected = 0, mailExpected = 0
        for name in expected.keys.sorted() {
            let url = root!.appendingPathComponent("PST/PST/\(name)")
            let hash = Data(SHA256.hash(data: try Data(contentsOf: url))).map { String(format: "%02x", $0) }.joined()
            guard seen.insert(hash).inserted else { continue }
            files.append(url)
            deletedExpected += expected[name]!.filter { DeletedFolderNames.isDeleted(path: $0.key) }.values.reduce(0, +)
            mailExpected += try PSTParser.parse(fileURL: url, senderEmail: "").count
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pstimp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SQLiteEmailStore(directory: dir.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.dedupPolicy = .preserveAll
        let summary = try await coordinator.runImport(urls: files, options: options)
        let stored = try await store.filteredCount(.all)
        let c = try await store.recoveryCounts()
        XCTAssertEqual(stored, mailExpected, "every mail item the reader finds is stored")
        XCTAssertEqual(c[.deletedFolder], deletedExpected, "deleted-items mail equals readpst")
        XCTAssertTrue(summary.receipt?.verify() ?? false)
        print("PST-IMPORT: \(files.count) files, \(stored) stored, \(c[.deletedFolder]) in deleted folders")
    }

    /// Content check against readpst: same Message-IDs, same subjects, senders read.
    func testOutlookPSTs_sameMessagesAsReadpst() throws {
        struct Entry: Decodable { let messageIDs: [String]; let subjects: [String]; let withSender: Int; let count: Int }
        let expected = try manifest("pst-readpst-ids.json", as: [String: Entry].self)
        func norm(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var report: [String] = []
        for (file, e) in expected.sorted(by: { $0.key < $1.key }) {
            let emails = try PSTParser.parse(fileURL: root!.appendingPathComponent("PST/PST/\(file)"), senderEmail: "")
            let ours = Set(emails.compactMap { $0.headers["Message-ID"]?.trimmingCharacters(in: .whitespaces) })
            let missingIDs = Set(e.messageIDs).subtracting(ours)
            let oursSubjects = Set(emails.map { norm($0.headers["Subject"] ?? "") })
            let missingSubjects = Set(e.subjects.map(norm).filter { !$0.isEmpty }).subtracting(oursSubjects)
            let withSender = emails.filter { !($0.headers["From"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.count
            if !missingIDs.isEmpty || !missingSubjects.isEmpty || withSender < min(e.withSender, emails.count) {
                report.append("\(file): \(missingIDs.count) Message-IDs missing; subjects missing \(Array(missingSubjects).prefix(5)); senders \(withSender) (readpst \(e.withSender))")
            }
        }
        XCTAssertTrue(report.isEmpty, report.joined(separator: "\n"))
    }

    /// Real Gmail and Yahoo mail (2009–2011): no message in the public set is
    /// flagged as missing a DKIM signature — Sent and All Mail copies are
    /// unsigned by nature and must not count as evidence against the sender.
    func testMissingDKIM_onRealThunderbirdMail_flagsNothing() throws {
        let dir = root!.appendingPathComponent("Tbird/Tbird")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension != "msf" }
        var judged = 0, flagged: [String] = []
        for url in files {
            guard let emails = try? MBOXParser.parse(fileURL: url, senderEmail: "") else { continue }
            for e in emails where (e.headers["From"] ?? "").lowercased().contains("@gmail.com") || (e.headers["From"] ?? "").lowercased().contains("@yahoo.com") {
                judged += 1
                let date = e.headers["Date"].flatMap(RFC5322Date.parse)
                if let why = DKIMExpectations.missingSignature(headers: e.headers, rawSource: e.rawSource, date: date) {
                    flagged.append("\(url.lastPathComponent): \(why)")
                }
            }
        }
        XCTAssertGreaterThan(judged, 200)
        XCTAssertTrue(flagged.isEmpty, flagged.prefix(5).joined(separator: "\n"))
    }

    /// No public PST uses cyclic encoding (bCryptMethod 2), so each real
    /// permute-encoded file is re-encoded block by block with [MS-PST] 5.2
    /// CryptCyclic and its method byte set to 2. The reader must read back
    /// exactly the messages it reads from the original.
    func testOutlookPSTs_reEncodedCyclic_readTheSameMessages() throws {
        let files = try FileManager.default.contentsOfDirectory(at: root!.appendingPathComponent("PST/PST"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pst" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var converted = 0
        for url in files {
            var bytes = [UInt8](try Data(contentsOf: url))
            let spec = try PSTSpecReader(data: Data(bytes))
            guard spec.crypt == 1 else { continue }
            for (bid, b) in spec.blocks where bid & 2 == 0 {
                let o = Int(b.ib)
                guard o >= 0, b.cb > 0, o + b.cb <= bytes.count else { continue }
                var d = Array(bytes[o..<(o + b.cb)])
                PSTSpec.decodePermute(&d)
                PSTSpec.cyclic(&d, key: UInt32(truncatingIfNeeded: bid))
                bytes.replaceSubrange(o..<(o + b.cb), with: d)
            }
            bytes[spec.unicode ? 513 : 461] = 2
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("cyclic-\(UUID().uuidString).pst")
            try Data(bytes).write(to: out)
            defer { try? FileManager.default.removeItem(at: out) }

            let cyclic = try PSTParser.parse(fileURL: out, senderEmail: "")
            // A file with no mail items reads as the earlier reader when permute-
            // encoded, but must stay with the spec reader (and read nothing,
            // not fail) once cyclic.
            guard spec.nodes.values.contains(where: { $0.nid & 0x1F == PSTSpecReader.nidTypeMessage }) else {
                XCTAssertEqual(cyclic.count, 0, url.lastPathComponent)
                converted += 1
                continue
            }
            let original = try PSTParser.parse(fileURL: url, senderEmail: "")
            XCTAssertEqual(cyclic.count, original.count, url.lastPathComponent)
            XCTAssertEqual(Set(cyclic.compactMap { $0.headers["Message-ID"] }), Set(original.compactMap { $0.headers["Message-ID"] }), url.lastPathComponent)
            XCTAssertEqual(cyclic.map { $0.headers["Subject"] ?? "" }.sorted(), original.map { $0.headers["Subject"] ?? "" }.sorted(), url.lastPathComponent)
            XCTAssertEqual(cyclic.map(\.plainBody).sorted(), original.map(\.plainBody).sorted(), url.lastPathComponent)
            converted += 1
        }
        XCTAssertGreaterThan(converted, 0, "at least one permute-encoded PST was converted")
        print("CYCLIC: \(converted) files re-encoded and read back identically")
    }
}

/// [MS-PST] 5.1 tables: CryptCyclic is its own inverse only if the middle
/// table is an involution and the last is the inverse of the first.
final class PSTCyclicTableTests: XCTestCase {
    func testCyclicEncoding_isItsOwnInverse() {
        let r = Array(PSTSpec.crypt[0..<256]), s = Array(PSTSpec.crypt[256..<512]), i = Array(PSTSpec.crypt[512..<768])
        for x in 0..<256 {
            XCTAssertEqual(Int(s[Int(s[x])]), x, "S is an involution")
            XCTAssertEqual(Int(i[Int(r[x])]), x, "I is the inverse of R")
        }
        var bytes = (0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let plain = bytes
        PSTSpec.cyclic(&bytes, key: 0x0001_2344)
        XCTAssertNotEqual(bytes, plain)
        PSTSpec.cyclic(&bytes, key: 0x0001_2344)
        XCTAssertEqual(bytes, plain)
    }
}
