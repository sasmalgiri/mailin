//
//  RealCorpusMatrixTests.swift
//  ArchiveCoreTests
//
//  Gate 2 (2026-11-18): the 100 MB format matrix on a REAL corpus. The matrix of OPEN-06
//  (`HundredMegabyteFormatMatrixTests`, app target) generates synthetic mail; this runs the same
//  shape on real messages: Enron custodian maildirs (CMU enron_mail_20150507), prepared by
//  `Scripts/gate2_build_real_corpus.py` as an mbox (mboxrd framing only), the original files as a
//  folder tree (hard links, bytes unchanged) and a ZIP of that tree, with an independent manifest
//  written by Python (no mailin code): message total, per-folder counts, Message-IDs, the messages
//  that contain each search phrase.
//
//  For every source: import through the production `BulkImportCoordinator`, then stored = the
//  manifest's total, every Message-ID present once, search coverage = stored rows, nothing damaged;
//  for the folder tree and the ZIP every folder holds exactly its own count; on the folder-tree
//  archive every search phrase finds every message the manifest lists. That archive is exported as
//  mbox, as .eml files and as PST (mailin's own writers); the mbox and the .eml folder are verified
//  against the archive (`ExportReconciliation`), the PST (spec writer, as the app ships it) is
//  imported again and counted.
//
//  Opt-in: MAILIN_REAL_CORPUS=<dir with manifest.json>. MAILIN_REAL_CORPUS_OUT=<dir> keeps the
//  three exports for the independent Python / readpst check.
//

import XCTest
import Foundation
@preconcurrency @testable import ArchiveCore

final class RealCorpusMatrixTests: XCTestCase {

    struct Manifest: Decodable {
        let source: String
        let files: Int
        let sourceBytes: Int
        let mboxBytes: Int
        let zipBytes: Int
        let distinctMessageIDs: Int
        let folders: [String: Int]
        let search: [String: [String]]
    }

    private struct Run {
        let label: String
        let sourceBytes: Int64
        let firstSeconds: Double
        let seconds: Double
        let peakDeltaMB: Double
        let storeBytes: Int64
        let ftsBytes: Int64
        let stored: Int
        let ftsRows: Int
        let summary: BulkImportCoordinator.RunSummary
        let root: URL
        let store: SQLiteEmailStore
        let fts: FTSSearchIndex
        let archive: ArchiveDataService
    }

    private final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private let start = Date()
        private(set) var first: Double?
        private(set) var peak: UInt64
        init(baseline: UInt64) { peak = baseline }
        func record(_ count: Int) {
            let f = CarverScaleTests.footprint()
            lock.lock(); defer { lock.unlock() }
            if first == nil, count > 0 { first = Date().timeIntervalSince(start) }
            peak = max(peak, f)
        }
    }

    private static func bytes(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    private func importMeasured(_ url: URL, label: String) async throws -> Run {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("realcorpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        let baseline = CarverScaleTests.footprint()
        let sampler = Sampler(baseline: baseline)
        var callbacks = BulkImportCoordinator.Callbacks()
        callbacks.onCommittedBatch = { batch in sampler.record(batch.count) }
        let start = Date()
        let summary = try await coordinator.runImport(urls: [url], options: options, callbacks: callbacks)
        let seconds = Date().timeIntervalSince(start)
        try? await store.checkpoint()
        let stored = try await store.totalCount()
        let ftsRows = try await fts.rowCount()
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        return Run(label: label, sourceBytes: Self.bytes(url), firstSeconds: sampler.first ?? seconds, seconds: seconds,
                   peakDeltaMB: Double(sampler.peak - min(sampler.peak, baseline)) / 1_048_576,
                   storeBytes: Self.bytes(root.appendingPathComponent("store")), ftsBytes: Self.bytes(root.appendingPathComponent("fts")),
                   stored: stored, ftsRows: ftsRows, summary: summary, root: root, store: store, fts: fts, archive: archive)
    }

    /// Every Message-ID in the archive, by paging the whole list (no cap).
    private func messageIDs(_ archive: ArchiveDataService, query: EmailQuery = .all) async throws -> [String] {
        var out: [String] = []
        var cursor: EmailPageCursor? = nil
        repeat {
            let page = try await archive.page(query: query, cursor: cursor, limit: 1_000)
            out += page.summaries.map { ($0.messageID ?? "").trimmingCharacters(in: .whitespaces) }
            cursor = page.nextCursor
        } while cursor != nil
        return out
    }

    /// Folder path below the imported root → direct message count, matched to the manifest's
    /// "custodian/folder/…" keys (a ZIP adds its own top directory, an import may prefix the root).
    private func folderCounts(_ store: SQLiteEmailStore, manifest: Manifest) async throws -> (matched: [String: Int], unmatched: [String: Int]) {
        let nodes = try await store.folderNodes().filter { $0.messageCount > 0 }
        var matched: [String: Int] = [:], unmatched: [String: Int] = [:]
        for node in nodes {
            let path = node.path
            if let key = manifest.folders.keys.first(where: { path == $0 || path.hasSuffix("/" + $0) }) {
                matched[key, default: 0] += node.messageCount
            } else {
                unmatched[path, default: 0] += node.messageCount
            }
        }
        return (matched, unmatched)
    }

    private func lookup(_ store: SQLiteEmailStore) -> ExportReconciliation.SourceLookup {
        ExportReconciliation.SourceLookup(
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

    private func row(_ r: Run) -> String {
        let mb = { (b: Int64) in String(format: "%.1f", Double(b) / 1_000_000) }
        return "| \(r.label) | \(mb(r.sourceBytes)) MB | \(r.stored) | \(String(format: "%.2f", r.firstSeconds)) s | \(String(format: "%.1f", r.seconds)) s | "
            + "\(String(format: "%.0f", r.peakDeltaMB)) MB | \(mb(r.storeBytes)) / \(mb(r.ftsBytes)) MB | discovered \(r.summary.discovered), parsed \(r.summary.parsed), "
            + "damaged \(r.summary.damaged), persist failed \(r.summary.persistFailed), FTS rows \(r.ftsRows) |"
    }

    func testRealCorpus_matrix_mbox_emlTree_zip_pst_countsFoldersSearchExportReconcile() async throws {
        guard let dirPath = ProcessInfo.processInfo.environment["MAILIN_REAL_CORPUS"], !dirPath.isEmpty else {
            throw XCTSkip("opt-in: MAILIN_REAL_CORPUS=<dir from Scripts/gate2_build_real_corpus.py>")
        }
        setvbuf(stdout, nil, _IOLBF, 0)   // rows appear as they are measured
        // The shipped app writes PST with the MS-PST spec writer (`v3PSTSpecWriter`, stable, on).
        let specWas = PSTWriterPolicy.useSpecWriter
        PSTWriterPolicy.useSpecWriter = true
        defer { PSTWriterPolicy.useSpecWriter = specWas }
        // ...and streams binary formats in batches (`streamingBinaryParsers`, stable, on). The package
        // default (off) is the previous path that reads a whole PST's messages into an array first:
        // the 764 MB PST of this corpus then took 870 MB over baseline (run 2026-11-18).
        let streamingWas = StreamingParserPolicy.binaryStreaming
        StreamingParserPolicy.binaryStreaming = true
        defer { StreamingParserPolicy.binaryStreaming = streamingWas }
        // MAILIN_REAL_CORPUS_STEPS=mbox,eml,zip,pst (default all): a re-run of some rows; "pst"
        // without "eml" imports the PST kept in MAILIN_REAL_CORPUS_OUT by an earlier run.
        let steps = Set((ProcessInfo.processInfo.environment["MAILIN_REAL_CORPUS_STEPS"] ?? "mbox,eml,zip,pst")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertGreaterThanOrEqual(manifest.sourceBytes, 100_000_000, "a real corpus of at least 100 MB")
        let keep = ProcessInfo.processInfo.environment["MAILIN_REAL_CORPUS_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let fm = FileManager.default
        var runs: [Run] = []
        defer { for r in runs { try? fm.removeItem(at: r.root) } }
        var notes: [String] = []
        print("REALCORPUS: \(manifest.source): \(manifest.files) messages, \(manifest.sourceBytes) bytes, \(manifest.folders.count) folders")

        func checkRun(_ r: Run, folders: Bool) async throws {
            print("REALCORPUS row " + row(r))
            XCTAssertEqual(r.stored, manifest.files, "\(r.label): every source message stored once")
            XCTAssertEqual(r.ftsRows, r.stored, "\(r.label): search coverage = stored rows")
            XCTAssertEqual(r.summary.damaged, 0, r.label)
            XCTAssertEqual(r.summary.persistFailed, 0, r.label)
            XCTAssertLessThan(r.peakDeltaMB, 600, "\(r.label): the footprint never approaches the source size")
            let ids = try await messageIDs(r.archive)
            XCTAssertEqual(ids.count, manifest.files, "\(r.label): listed rows")
            XCTAssertEqual(Set(ids).count, manifest.distinctMessageIDs, "\(r.label): every Message-ID once")
            if folders {
                let (matched, unmatched) = try await folderCounts(r.store, manifest: manifest)
                XCTAssertEqual(matched, manifest.folders, "\(r.label): every folder with exactly its own messages")
                XCTAssertTrue(unmatched.isEmpty, "\(r.label): folders not in the source: \(unmatched)")
                notes.append("\(r.label): \(matched.count) of \(manifest.folders.count) folders, each with its own count; unmatched \(unmatched.count)")
            }
        }

        // 1. mbox (one file; folders are not part of an mbox).
        if steps.contains("mbox") {
        let mboxRun = try await importMeasured(dir.appendingPathComponent("enron.mbox"), label: "mbox (real, mboxrd)")
        runs.append(mboxRun)
        try await checkRun(mboxRun, folders: false)
        try? fm.removeItem(at: mboxRun.root)
        }

        let exportRoot = keep ?? fm.temporaryDirectory.appendingPathComponent("realcorpus-export-\(UUID().uuidString)", isDirectory: true)
        defer { if keep == nil { try? fm.removeItem(at: exportRoot) } }
        let pstOut = exportRoot.appendingPathComponent("export.pst")
        // 2. The original files as a folder tree.
        if steps.contains("eml") {
        let emlRun = try await importMeasured(dir.appendingPathComponent("eml", isDirectory: true), label: "eml folder tree (real files)")
        runs.append(emlRun)
        try await checkRun(emlRun, folders: true)

        // 3. Search: every message the independent scan found must be found.
        for (phrase, expected) in manifest.search.sorted(by: { $0.key < $1.key }) {
            var q = EmailQuery.all
            q.text = phrase.contains(" ") || phrase.contains("&") || phrase.contains("-") ? "\"\(phrase)\"" : phrase
            let found = Set(try await messageIDs(emlRun.archive, query: q))
            let missing = Set(expected).subtracting(found)
            XCTAssertTrue(missing.isEmpty, "search \(phrase): \(missing.count) of \(expected.count) expected messages not found, e.g. \(missing.sorted().prefix(5))")
            notes.append("search \(q.text ?? ""): independent scan \(expected.count), mailin \(found.count), missing \(missing.count)")
            print("REALCORPUS " + notes.last!)
        }

        // 4. Export the folder-tree archive three ways and verify.
        try? fm.removeItem(at: exportRoot)
        try fm.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let service = await ArchiveExportService(archive: emlRun.archive)
        let scope = ArchiveSelectionScope.query(.all, exclusions: [])
        var t = Date()
        let mboxOut = exportRoot.appendingPathComponent("export.mbox")
        let mboxResult = try await service.exportMBOXArchive(scope: scope, to: mboxOut)
        let mboxExportSeconds = Date().timeIntervalSince(t)
        XCTAssertEqual(mboxResult.recordsWritten, manifest.files, "mbox export")
        t = Date()
        let emlOut = exportRoot.appendingPathComponent("eml", isDirectory: true)
        let emlResult = try await service.exportEMLFiles(scope: scope, to: emlOut)
        let emlExportSeconds = Date().timeIntervalSince(t)
        XCTAssertEqual(emlResult.recordsWritten, manifest.files, ".eml export")
        t = Date()
        let pstWritten = try await service.exportPST(scope: scope, to: pstOut)
        let pstExportSeconds = Date().timeIntervalSince(t)
        XCTAssertEqual(pstWritten, manifest.files, "PST export")

        t = Date()
        let mboxReport = await ExportReconciliation.reconcile(file: mboxOut, promised: manifest.files, lookup: lookup(emlRun.store))
        let mboxVerifySeconds = Date().timeIntervalSince(t)
        t = Date()
        let emlReport = await ExportReconciliation.reconcile(folder: emlOut, lookup: lookup(emlRun.store))
        let emlVerifySeconds = Date().timeIntervalSince(t)
        for (label, r) in [("mbox", mboxReport), (".eml folder", emlReport)] {
            XCTAssertEqual(r.outcome, .complete, "\(label) export verification: \(r.reason ?? "")")
            XCTAssertEqual(r.matching, manifest.files, "\(label): every output matches its record")
            XCTAssertEqual(r.mismatched + r.withoutRecord + r.unparsed + r.unverifiable, 0, label)
            notes.append("verify \(label): \(r.outcome.rawValue), eligible \(r.eligible), checked \(r.checked), matching \(r.matching), mismatched \(r.mismatched), "
                         + "unverifiable \(r.unverifiable), without record \(r.withoutRecord), unparsed \(r.unparsed); transformations \(r.transformations)")
        }
        print("REALCORPUS exports written and verified")
        notes.append(String(format: "export seconds: mbox %.1f, eml %.1f, pst %.1f; verify seconds: mbox %.1f, eml %.1f",
                            mboxExportSeconds, emlExportSeconds, pstExportSeconds, mboxVerifySeconds, emlVerifySeconds))
        notes.append("export sizes: mbox \(Self.bytes(mboxOut)) B, eml \(Self.bytes(emlOut)) B, pst \(Self.bytes(pstOut)) B")
        try? fm.removeItem(at: emlRun.root)
        }

        // 5. The ZIP of the tree, and mailin's PST imported back.
        if steps.contains("zip") {
        let zipRun = try await importMeasured(dir.appendingPathComponent("enron-maildir.zip"), label: "zip of the tree (real files)")
        runs.append(zipRun)
        try await checkRun(zipRun, folders: true)
        try? fm.removeItem(at: zipRun.root)
        }
        if steps.contains("pst") {
        XCTAssertTrue(fm.fileExists(atPath: pstOut.path), "a PST to import: \(pstOut.path)")
        let pstRun = try await importMeasured(pstOut, label: "pst (mailin writer, from the real archive)")
        runs.append(pstRun)
        try await checkRun(pstRun, folders: false)
        }

        print("""

        ## REALCORPUS rows — \(manifest.source)

        | Source | Size | Messages stored | First message | Total | Peak footprint over baseline | Store / FTS on disk | Reconciliation |
        |---|---|---|---|---|---|---|---|
        \(runs.map(row).joined(separator: "\n"))

        \(notes.map { "- " + $0 }.joined(separator: "\n"))

        """)
    }
}
