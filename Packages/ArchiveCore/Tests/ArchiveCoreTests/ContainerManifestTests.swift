//
//  ContainerManifestTests.swift
//  ArchiveCoreTests
//
//  Release audit bf1a5b9 R3 (container outputs reconciled one-to-one against
//  the export's frozen selection) and R8 / OUT-06a (an interrupted
//  single-file export recovered to a verified boundary and resumed exactly).
//  The drive-removal row itself is `DriveRemovalProcessTests` (MAILIN_SCALE=1).
//
//  Run: cd Packages/ArchiveCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//         xcrun swift test --filter ContainerManifestTests
//

import XCTest
import Foundation
@testable import ArchiveCore

final class ContainerManifestTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteEmailStore!
    private var fts: FTSSearchIndex!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Builders

    /// A message; `messageID: nil` writes none at all.
    static func mail(_ i: Int, subject: String? = nil, messageID: String?, body: String? = nil,
                     folder: String? = nil, labels: [String] = []) throws -> MBOXParser.RawEmail {
        var raw = ExportReconciliationTests.raw(subject: subject ?? "Mail \(i)",
                                                date: String(format: "Wed, 15 Jan 2025 10:%02d:%02d +0000", i / 60, i % 60),
                                                messageID: messageID ?? "<drop@me>", plain: body ?? "Body of message \(i).")
        if messageID == nil { raw = raw.replacingOccurrences(of: "Message-ID: <drop@me>\r\n", with: "") }
        var email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        email.folderPath = folder
        email.tags = labels
        return email
    }

    func insert(_ emails: [MBOXParser.RawEmail]) async throws {
        _ = try await store.insertBatch(emails, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                        dedupPolicy: .preserveAll, batchSize: 100, progress: nil)
    }

    @MainActor
    func service() -> ArchiveExportService {
        ArchiveExportService(archive: ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)))
    }

    /// The app's lookup shape: records by ID a page at a time; Message-ID only as the store answers it.
    func lookup() -> ExportReconciliation.SourceLookup {
        let store = self.store!
        return ExportReconciliation.SourceLookup(
            records: { ids in
                var out: [UUID: MBOXParser.RawEmail] = [:]
                for id in ids { if let e = try await store.fullEmail(id: id) { out[id] = e } }
                return out
            },
            recordsByMessageID: { mids in
                var out: [String: MBOXParser.RawEmail] = [:]
                for (key, id) in try await store.emailIDs(forMessageIDs: mids) { if let e = try await store.fullEmail(id: id) { out[key] = e } }
                return out
            })
    }

    @MainActor
    func exportMBOX(_ ids: [UUID], name: String = "out.mbox") async throws -> URL {
        let url = root.appendingPathComponent(name)
        let r = try await service().exportMBOXArchive(scope: .explicit(Set(ids)), to: url)
        XCTAssertTrue(r.completed)
        XCTAssertNil(r.inventoryFailure)
        return url
    }

    @MainActor
    func exportPST(_ ids: [UUID], name: String = "out.pst") async throws -> URL {
        let url = root.appendingPathComponent(name)
        _ = try await service().exportPST(scope: .explicit(Set(ids)), to: url)
        return url
    }

    /// The mbox record bytes in output order, cut at the offsets the manifest recorded.
    func records(of mbox: URL) throws -> [Data] {
        let data = try Data(contentsOf: mbox)
        var out: [Data] = []
        try ContainerManifest.forEachLine(url: ContainerManifest.url(for: mbox)) { line, _ in
            if line.kind == .record, let o = line.offset, let n = line.length { out.append(data[Int(o)..<Int(o + n)]) }
            return true
        }
        return out
    }

    /// The archive IDs in the order the export wrote them.
    func manifestOrder(of output: URL) throws -> [UUID] {
        var out: [UUID] = []
        try ContainerManifest.forEachLine(url: ContainerManifest.url(for: output)) { line, _ in
            if line.kind == .record, let id = line.emailID.flatMap(UUID.init(uuidString:)) { out.append(id) }
            return true
        }
        return out
    }

    func rewrite(_ mbox: URL, _ parts: [Data]) throws {
        try parts.reduce(Data(), +).write(to: mbox)
    }

    func reconcile(_ file: URL, promised: Int) async -> ExportReconciliation.ContentReport {
        await ExportReconciliation.reconcile(file: file, promised: promised, lookup: lookup(), pageSize: 2)
    }

    // MARK: - R3: one-to-one against the frozen selection

    func testR3_mbox_AplusB_tamperedToAplusA_failsNamingBMissing() async throws {
        let a = try Self.mail(1, messageID: "<a@t>"), b = try Self.mail(2, messageID: "<b@t>")
        try await insert([a, b])
        let mbox = try await exportMBOX([a.id, b.id])

        let clean = await reconcile(mbox, promised: 2)
        XCTAssertEqual(clean.outcome, .complete, "\(clean.summary)\n\(clean.findings)")
        XCTAssertEqual(clean.selection?.manifests, 1)
        XCTAssertEqual(clean.selection?.expected, 2)
        XCTAssertEqual(clean.selection?.paired, 2)
        XCTAssertEqual(clean.selection?.pairedOutOfOrder, 0, "an untampered export pairs in step, one pass")

        let parts = try records(of: mbox)
        let order = try manifestOrder(of: mbox)
        XCTAssertEqual(Set(order), [a.id, b.id])
        let (first, second) = order[0] == a.id ? (a, b) : (b, a)
        try rewrite(mbox, [parts[0], parts[0]])
        let tampered = await reconcile(mbox, promised: 2)
        XCTAssertEqual(tampered.outcome, .failed, tampered.summary)
        XCTAssertEqual(tampered.eligible, 2, "the count alone would have passed")
        XCTAssertEqual(tampered.matching, 1)
        XCTAssertEqual(tampered.selection?.missing, 1)
        XCTAssertEqual(tampered.selection?.extra, 1)
        let missing = try XCTUnwrap(tampered.findings.first { $0.status == .missing })
        XCTAssertEqual(missing.emailID, second.id, "the record the copy displaced is named as missing")
        XCTAssertEqual(missing.messageID, ExportReconciliation.identifier(second.headers["Message-ID"] ?? ""))
        let extra = try XCTUnwrap(tampered.findings.first { $0.status == .extra })
        XCTAssertEqual(extra.path, "out.mbox#2")
        XCTAssertEqual(extra.emailID, first.id)
        XCTAssertTrue(extra.reason?.contains("a second copy") == true, extra.reason ?? "")
        XCTAssertTrue(tampered.reason?.contains(second.id.uuidString) == true, tampered.reason ?? "")

        // Reordered (B, A): every record is still there exactly once — complete, paired out of order.
        try rewrite(mbox, [parts[1], parts[0]])
        let swapped = await reconcile(mbox, promised: 2)
        XCTAssertEqual(swapped.outcome, .complete, "\(swapped.summary)\n\(swapped.findings)")
        XCTAssertEqual(swapped.selection?.pairedOutOfOrder, 2)
        XCTAssertEqual(swapped.matching, 2)
    }

    func testR3_duplicateMessageIDsAcrossDifferentRecords_areTiedByContentNotByID() async throws {
        let a = try Self.mail(1, subject: "First of two", messageID: "<same@t>", body: "Alpha text.")
        let b = try Self.mail(2, subject: "Second of two", messageID: "<same@t>", body: "Beta text.")
        try await insert([a, b])
        let mbox = try await exportMBOX([a.id, b.id])

        let clean = await reconcile(mbox, promised: 2)
        XCTAssertEqual(clean.outcome, .complete, "\(clean.summary)\n\(clean.findings)")
        XCTAssertEqual(clean.matching, 2, "each output is compared with ITS record, not the first with that Message-ID")

        let parts = try records(of: mbox)
        let order = try manifestOrder(of: mbox)
        try rewrite(mbox, [parts[0], parts[0]])
        let tampered = await reconcile(mbox, promised: 2)
        XCTAssertEqual(tampered.outcome, .failed, tampered.summary)
        XCTAssertEqual(tampered.findings.first { $0.status == .missing }?.emailID, order[1])
        XCTAssertEqual(tampered.selection?.extra, 1)

        // The old route (no manifest) cannot see this, and now says so.
        try FileManager.default.removeItem(at: ContainerManifest.url(for: mbox))
        let old = await reconcile(mbox, promised: 2)
        XCTAssertEqual(old.selection?.withoutManifest, 1)
        XCTAssertTrue(old.reason?.contains("no manifest — checked by Message-ID only") == true, old.reason ?? "")
    }

    func testR3_messagesWithoutMessageID_areReconciled() async throws {
        let a = try Self.mail(1, messageID: nil), b = try Self.mail(2, messageID: nil)
        try await insert([a, b])
        let mbox = try await exportMBOX([a.id, b.id])

        let clean = await reconcile(mbox, promised: 2)
        XCTAssertEqual(clean.outcome, .complete, "\(clean.summary)\n\(clean.findings)")
        XCTAssertEqual(clean.matching, 2)
        XCTAssertEqual(clean.withoutRecord, 0, "no Message-ID is needed to tie a record")

        let parts = try records(of: mbox)
        let order = try manifestOrder(of: mbox)
        try rewrite(mbox, [parts[0], parts[0]])
        let tampered = await reconcile(mbox, promised: 2)
        XCTAssertEqual(tampered.outcome, .failed, tampered.summary)
        XCTAssertEqual(tampered.findings.first { $0.status == .missing }?.emailID, order[1])

        // A changed body of a message without Message-ID is a named difference, at its place.
        let text = String(decoding: parts[1], as: UTF8.self).replacingOccurrences(of: "Body of message [0-9]+\\.", with: "Body changed.", options: .regularExpression)
        try rewrite(mbox, [parts[0], Data(text.utf8)])
        let changed = await reconcile(mbox, promised: 2)
        XCTAssertEqual(changed.outcome, .failed, changed.summary)
        XCTAssertEqual(changed.mismatches.first?.emailID, order[1])
        XCTAssertEqual(changed.mismatches.first?.lostFields, [.plainBody])
        XCTAssertEqual(changed.selection?.missing, 0)
    }

    func testR3_outputHoldingAnUnselectedArchiveRecord_fails() async throws {
        let a = try Self.mail(1, messageID: "<a@t>"), b = try Self.mail(2, messageID: "<b@t>"), c = try Self.mail(3, messageID: "<c@t>")
        try await insert([a, b, c])
        let mbox = try await exportMBOX([a.id, b.id])
        let other = try await exportMBOX([c.id], name: "c.mbox")
        let parts = try records(of: mbox), cPart = try records(of: other)[0]

        try rewrite(mbox, [parts[0], cPart])
        let report = await reconcile(mbox, promised: 2)
        XCTAssertEqual(report.outcome, .failed, report.summary)
        XCTAssertEqual(report.findings.first { $0.status == .missing }?.emailID, try manifestOrder(of: mbox)[1])
        let extra = try XCTUnwrap(report.findings.first { $0.status == .extra })
        XCTAssertEqual(extra.emailID, c.id)
        XCTAssertEqual(extra.reason, "matches archive record \(c.id.uuidString), which is not in this export's selection")
    }

    func testR3_extraRecord_isNeverComplete() async throws {
        let a = try Self.mail(1, messageID: "<a@t>"), b = try Self.mail(2, messageID: "<b@t>"), c = try Self.mail(3, messageID: "<c@t>")
        try await insert([a, b, c])
        let mbox = try await exportMBOX([a.id, b.id])
        let other = try await exportMBOX([c.id], name: "c.mbox")
        let parts = try records(of: mbox)
        try rewrite(mbox, parts + [try records(of: other)[0]])
        let withManifest = await reconcile(mbox, promised: 2)
        XCTAssertEqual(withManifest.outcome, .failed, withManifest.summary)
        XCTAssertEqual(withManifest.matching, 2)
        XCTAssertEqual(withManifest.selection?.extra, 1)
        XCTAssertEqual(withManifest.selection?.missing, 0)

        // Parsed > promised fails on the old route too (it used to be "complete").
        try FileManager.default.removeItem(at: ContainerManifest.url(for: mbox))
        let old = await reconcile(mbox, promised: 2)
        XCTAssertEqual(old.matching, 3)
        XCTAssertEqual(old.outcome, .failed, old.summary)
        XCTAssertTrue(old.reason?.contains("3 messages found, the export promised 2") == true, old.reason ?? "")
    }

    /// OUT-02 occurrences: a message in two folders written once per folder
    /// passes exactly — files, promise and occurrences agree — and a
    /// container's manifest records the folder each record was written for.
    func testR3_folderOccurrenceExport_passesExactly() async throws {
        let both = try Self.mail(1, messageID: "<both@t>", folder: "Inbox", labels: ["Projects/Alpha"])
        let one = try Self.mail(2, messageID: "<one@t>", folder: "Inbox")
        try await insert([both, one])
        var each = ExportWriteOptions(); each.layout = .sourceFolders; each.folderOccurrences = true
        let folder = root.appendingPathComponent("each", isDirectory: true)
        let result = try await service().exportEMLFiles(scope: .explicit([both.id, one.id]), to: folder, write: each)
        XCTAssertEqual(result.recordsWritten, 3); XCTAssertEqual(result.extraCopies, 1)
        let report = await ExportReconciliation.reconcile(folder: folder, lookup: lookup())
        XCTAssertEqual(report.outcome, .complete, "\(report.summary)\n\(report.findings)")
        XCTAssertEqual(report.eligible, 3); XCTAssertEqual(report.promised, 3); XCTAssertEqual(report.matching, 3)

        let mbox = try await exportMBOX([both.id, one.id])
        var folders: [String?] = []
        try ContainerManifest.forEachLine(url: ContainerManifest.url(for: mbox)) { line, _ in
            if line.kind == .record { folders.append(line.folder) }
            return true
        }
        XCTAssertEqual(folders, ["Inbox", "Inbox"])
        let container = await reconcile(mbox, promised: 2)
        XCTAssertEqual(container.outcome, .complete, "\(container.summary)\n\(container.findings)")
    }

    func testR3_pst_AplusB_tamperedToAplusA_failsNamingBMissing() async throws {
        let a = try Self.mail(1, messageID: "<pa@t>"), b = try Self.mail(2, messageID: "<pb@t>")
        try await insert([a, b])
        // The [MS-PST] writer, the 3.0 default (the app sets it at launch).
        let previous = PSTWriterPolicy.useSpecWriter
        PSTWriterPolicy.useSpecWriter = true
        defer { PSTWriterPolicy.useSpecWriter = previous }
        let pst = try await exportPST([a.id, b.id])
        let scan = try ContainerManifest.scan(url: ContainerManifest.url(for: pst))
        XCTAssertEqual(scan.recordLines, 2); XCTAssertNotNil(scan.end)

        let clean = await reconcile(pst, promised: 2)
        XCTAssertEqual(clean.outcome, .complete, "\(clean.summary)\n\(clean.findings.map { "\($0.path) \($0.differences)" })")
        XCTAssertEqual(clean.selection?.paired, 2)
        XCTAssertEqual(clean.selection?.pairedOutOfOrder, 0)

        // The same file name, rewritten holding A twice; the manifest stays.
        let storedA = try await store.fullEmail(id: a.id)
        let fullA = try XCTUnwrap(storedA)
        try FileManager.default.removeItem(at: pst)
        let writer = try PSTWriterFactory.make(url: pst)
        try writer.appendMessage(fullA); try writer.appendMessage(fullA)
        XCTAssertEqual(try writer.finalize(), 2)
        let tampered = await reconcile(pst, promised: 2)
        XCTAssertEqual(tampered.outcome, .failed, tampered.summary)
        XCTAssertEqual(tampered.findings.first { $0.status == .missing }?.emailID, try manifestOrder(of: pst).first { $0 != a.id })
        XCTAssertEqual(tampered.selection?.extra, 1)

        // A PST part renamed to the user's name keeps its manifest.
        let renamed = root.appendingPathComponent("named.pst")
        try FileManager.default.moveItem(at: pst, to: renamed)
        try ContainerManifest.moveSidecar(from: pst, to: renamed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ContainerManifest.url(for: renamed).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ContainerManifest.url(for: pst).path))
    }

    /// R3 (iOS): a container handed on alone keeps its manifest with the
    /// receipt; verification uses that copy when none is beside the file.
    func testR3_manifestKeptElsewhere_isUsedByVerification() async throws {
        let mails = try (0..<5).map { try Self.mail($0, messageID: "<kept-\($0)@t>") }
        try await insert(mails)
        let mbox = try await exportMBOX(mails.map(\.id), name: "kept.mbox")
        let kept = root.appendingPathComponent("receipts/export-x.mailin-manifest")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: ContainerManifest.url(for: mbox), to: kept)

        let without = await ExportReconciliation.reconcile(file: mbox, promised: 5, lookup: lookup())
        XCTAssertEqual(without.selection?.withoutManifest, 1, "no sidecar and no kept manifest: Message-ID only")
        XCTAssertEqual(without.selection?.manifests, 0)

        let with = await ExportReconciliation.reconcile(file: mbox, promised: 5, manifest: kept, lookup: lookup())
        XCTAssertEqual(with.selection?.manifests, 1)
        XCTAssertEqual(with.selection?.withoutManifest, 0)
        XCTAssertEqual(with.selection?.paired, 5)
        XCTAssertEqual(with.outcome, .complete, "\(with.summary)")
    }

    // MARK: - R8: recover an interrupted export to a verified boundary, then resume exactly

    func testR8_interruptedExport_recoversToVerifiedBoundary_andResumesExactly() async throws {
        let total = 450
        try await insert(try (0..<total).map { try Self.mail($0, messageID: "<r8-\($0)@t>") })
        let mbox = root.appendingPathComponent("cut.mbox")
        let full = try await service().exportMBOXArchive(scope: .query(.all, exclusions: []), to: mbox)
        XCTAssertEqual(full.recordsWritten, total)
        let manifestURL = ContainerManifest.url(for: mbox)
        let scan = try ContainerManifest.scan(url: manifestURL)
        XCTAssertEqual(scan.checkpoints.map { $0.line.positions }, [200, 400, 450], "one durable checkpoint per batch")
        let parts = try records(of: mbox)
        XCTAssertEqual(parts.count, total)

        // What a pulled drive leaves: the manifest durable up to the first
        // checkpoint, the file 50 complete records past it and the 51st cut.
        let boundary = try XCTUnwrap(scan.checkpoints.first)
        let m = try FileHandle(forWritingTo: manifestURL)
        try m.truncate(atOffset: boundary.manifestEnd); try m.close()
        let cutAt = parts[0..<250].reduce(0) { $0 + $1.count } + parts[250].count / 2
        let f = try FileHandle(forWritingTo: mbox)
        try f.truncate(atOffset: UInt64(cutAt)); try f.close()

        // A resume from a boundary the file no longer ends at is refused.
        var stale = ExportWriteOptions(); stale.append = true; stale.skipFirst = 200; stale.keepPartialOnCancel = true
        stale.expectedAppendOffset = boundary.line.bytes; stale.expectedAppendSHA256 = boundary.line.sha256
        do {
            _ = try await service().exportMBOXArchive(scope: .query(.all, exclusions: []), to: mbox, write: stale)
            XCTFail("appending after an unrecovered tail must be refused")
        } catch let error as ArchiveExportError {
            guard case .partialArtifactChanged = error else { return XCTFail("\(error)") }
        }

        let recovery = try ContainerManifest.recover(output: mbox)
        XCTAssertEqual(recovery.positions, 200)
        XCTAssertEqual(recovery.records, 200)
        XCTAssertEqual(recovery.offset, boundary.line.bytes)
        XCTAssertEqual(recovery.tailRecords, 51)
        XCTAssertTrue(recovery.tailLastRecordCut)
        XCTAssertEqual(recovery.tailCompleteRecords, 50)
        XCTAssertEqual(recovery.checkpointsRejected, 0)
        XCTAssertEqual(recovery.summary, "recovered to a verified boundary: 200 record(s) at byte \(recovery.offset), SHA-256 of the prefix verified; past it \(recovery.tailBytes) byte(s): 50 complete record(s) and 1 cut record the receipt never counted — removed, the resume writes them again")
        // The cut-back file parses to exactly the vouched records.
        var parsed = 0
        try await ExportReconciliation.readContainer(mbox, kind: .mbox, batchSize: 100) { parsed += $0.count }
        XCTAssertEqual(parsed, recovery.records)

        let resumed = try await service().exportMBOXArchive(scope: .query(.all, exclusions: []), to: mbox, write: .resuming(from: recovery))
        XCTAssertTrue(resumed.completed)
        XCTAssertEqual(resumed.recordsWritten, total, "the receipt says \(total) of \(total)")
        XCTAssertEqual(resumed.sha256Hex, full.sha256Hex, "byte for byte the file an uninterrupted run writes")
        XCTAssertEqual(ContainerManifest.hex(try ArchiveExportService.sha256(ofFile: mbox)), resumed.sha256Hex)
        let after = try ContainerManifest.scan(url: manifestURL)
        XCTAssertEqual(after.recordLines, total); XCTAssertEqual(after.end?.records, total); XCTAssertEqual(after.end?.sha256, resumed.sha256Hex)
        XCTAssertNil(after.inconsistent)
        let report = await ExportReconciliation.reconcile(file: mbox, promised: total, lookup: lookup())
        XCTAssertEqual(report.outcome, .complete, "\(report.summary)\n\(report.findings.prefix(3))")
        XCTAssertEqual(report.selection?.paired, total); XCTAssertEqual(report.selection?.pairedOutOfOrder, 0)
    }

    func testR8_recovery_refusesAPrefixThatNoLongerVerifies_andLeavesTheFile() async throws {
        try await insert(try (0..<250).map { try Self.mail($0, messageID: "<v-\($0)@t>") })
        let mbox = root.appendingPathComponent("v.mbox")
        _ = try await service().exportMBOXArchive(scope: .query(.all, exclusions: []), to: mbox)
        let manifestURL = ContainerManifest.url(for: mbox)
        let boundary = try XCTUnwrap(try ContainerManifest.scan(url: manifestURL).checkpoints.first)
        let m = try FileHandle(forWritingTo: manifestURL)
        try m.truncate(atOffset: boundary.manifestEnd); try m.close()
        var data = try Data(contentsOf: mbox)
        data[100] = data[100] == 0x41 ? 0x42 : 0x41
        try data.write(to: mbox)
        XCTAssertThrowsError(try ContainerManifest.recover(output: mbox)) { error in
            XCTAssertEqual(error as? ContainerManifest.RecoveryError, .noVerifiedBoundary("no checkpoint's prefix hash matches the file"))
        }
        XCTAssertEqual(try Data(contentsOf: mbox), data, "nothing is cut when nothing verifies")
        // A finished export has nothing to recover.
        let done = root.appendingPathComponent("done.mbox")
        _ = try await service().exportMBOXArchive(scope: .query(.all, exclusions: []), to: done)
        XCTAssertThrowsError(try ContainerManifest.recover(output: done)) { XCTAssertEqual($0 as? ContainerManifest.RecoveryError, .alreadyFinished) }
    }
}
