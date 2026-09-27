@testable import ArchiveCore
//
//  HandoffRoundTripHarness.swift
//  maxmailin
//
//  H2: source → archive → mbox → re-parse, compared by message identity,
//  count, attachment identity and original hash. The harness is what makes
//  an "Export to Apple Mail / Thunderbird" claim checkable: the mbox mailin
//  writes must give back every message the archive holds, with the same
//  attachments, before anyone is told to import it into a mail client.
//
//  Release-safe, disposable storage only (the environment root is gated by
//  `MailinStorageEnvironment.assertNotProduction`).
//

import Foundation
import CryptoKit

struct HandoffRoundTripReport: Codable, Sendable, Equatable {
    struct AttachmentIdentity: Codable, Hashable, Sendable {
        var messageID: String
        var filename: String
        var size: Int
    }

    var sourceNames: [String]
    var imported: Int
    var exportedRecords: Int
    var exportedBytes: Int64
    var reparsed: Int
    var reparseFailed: Int
    var partitions: Int

    var identitiesInArchive: Int
    var identitiesAfterRoundTrip: Int
    var missingAfterRoundTrip: [String]     // first 20 Message-IDs
    var unexpectedAfterRoundTrip: [String]  // first 20
    var attachmentsInArchive: Int
    var attachmentsAfterRoundTrip: Int
    var attachmentMismatches: [AttachmentIdentity]  // first 20
    var rawHashesCompared: Int
    var rawHashesMatched: Int

    var seconds: Double
    var notes: [String]

    /// Every identity survived, every attachment identity survived, counts
    /// agree, and every raw message that could be compared is byte-identical.
    var passed: Bool {
        imported == reparsed
            && reparseFailed == 0
            && missingAfterRoundTrip.isEmpty
            && unexpectedAfterRoundTrip.isEmpty
            && attachmentMismatches.isEmpty
            && rawHashesCompared == rawHashesMatched
    }

    var verdictLine: String {
        passed
            ? "Round trip complete — \(imported) messages, \(attachmentsInArchive) attachments, \(rawHashesMatched) raw messages byte-identical."
            : "Round trip did NOT reconcile — imported \(imported), re-parsed \(reparsed); \(missingAfterRoundTrip.count) identities missing, \(attachmentMismatches.count) attachment mismatches, \(rawHashesCompared - rawHashesMatched) raw mismatches."
    }
}

enum HandoffRoundTripHarness {

    /// Import `sources` into a disposable environment under `root`, export it
    /// as mbox partitions into `root/export`, re-parse the partitions, and
    /// compare. The caller owns `root`.
    @MainActor
    static func run(sources: [URL], root: URL,
                    partitionBytes: Int = 2 * 1_073_741_824,
                    onProgress: (@MainActor (String) -> Void)? = nil) async throws -> HandoffRoundTripReport {
        try MailinStorageEnvironment.assertNotProduction(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clock = ContinuousClock()
        let start = clock.now
        var notes: [String] = []

        // 1. Import through the production path.
        onProgress?("Importing…")
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let coordinator = BulkImportCoordinator(store: store, fts: fts,
                                                checkpoints: ImportCheckpointStore(store: store),
                                                requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.useOffsetEngine = true
        options.recordLocators = true
        let summary = try await coordinator.runImport(urls: sources, options: options)
        notes.append(contentsOf: summary.warnings)
        let imported = try await store.totalCount()

        // 2. What the archive holds: identities, attachment identities, raw hashes.
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        var identities = Set<String>()
        var attachments = Set<HandoffRoundTripReport.AttachmentIdentity>()
        var rawHashes: [String: String] = [:]
        for try await batch in archive.streamSelected(scope: .query(.all, exclusions: []), batchSize: 200) {
            for email in batch {
                let id = identity(of: email)
                identities.insert(id)
                for att in email.attachments {
                    attachments.insert(.init(messageID: id, filename: att.filename, size: att.size))
                }
                if !email.rawSource.isEmpty { rawHashes[id] = sha256Hex(email.rawSource) }
            }
        }

        // 3. Export as mbox partitions.
        onProgress?("Exporting mbox…")
        let exportDir = root.appendingPathComponent("export", isDirectory: true)
        let exporter = ArchiveExportService(archive: archive)
        let results = try await exporter.exportMBOXPartitions(scope: .query(.all, exclusions: []),
                                                              toDirectory: exportDir,
                                                              baseName: "mailin-handoff",
                                                              partitionBytes: partitionBytes)
        let exportedRecords = results.last?.recordsWritten ?? 0
        let exportedBytes = results.reduce(Int64(0)) { $0 + Int64($1.bytesWritten) }
        let partitionFiles = ((try? FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mbox" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // 4. Re-parse every partition and compare.
        onProgress?("Re-parsing the export…")
        var reparsed = 0, reparseFailed = 0
        var seen = Set<String>()
        var attachmentsAfter = Set<HandoffRoundTripReport.AttachmentIdentity>()
        var hashesMatched = 0
        for partition in partitionFiles {
            let report = try await ParserFactory.parseStreamingCallback(fileURL: partition, senderEmail: "", batchSize: 200) { emails in
                for email in emails {
                    reparsed += 1
                    let id = identity(of: email)
                    seen.insert(id)
                    for att in email.attachments {
                        attachmentsAfter.insert(.init(messageID: id, filename: att.filename, size: att.size))
                    }
                    if let original = rawHashes[id], !email.rawSource.isEmpty, sha256Hex(email.rawSource) == original {
                        hashesMatched += 1
                    }
                }
            }
            reparseFailed += report.failed
        }

        let missing = identities.subtracting(seen)
        let unexpected = seen.subtracting(identities)
        let mismatched = attachments.symmetricDifference(attachmentsAfter)
        let elapsed = start.duration(to: clock.now).components
        if rawHashes.count < identities.count {
            notes.append("\(identities.count - rawHashes.count) messages had no stored raw source (reconstructed MIME on export); their hashes are not compared.")
        }
        return HandoffRoundTripReport(
            sourceNames: sources.map(\.lastPathComponent),
            imported: imported,
            exportedRecords: exportedRecords,
            exportedBytes: exportedBytes,
            reparsed: reparsed,
            reparseFailed: reparseFailed,
            partitions: partitionFiles.count,
            identitiesInArchive: identities.count,
            identitiesAfterRoundTrip: seen.count,
            missingAfterRoundTrip: Array(missing.sorted().prefix(20)),
            unexpectedAfterRoundTrip: Array(unexpected.sorted().prefix(20)),
            attachmentsInArchive: attachments.count,
            attachmentsAfterRoundTrip: attachmentsAfter.count,
            attachmentMismatches: Array(mismatched.sorted { ($0.messageID, $0.filename) < ($1.messageID, $1.filename) }.prefix(20)),
            rawHashesCompared: rawHashes.count,
            rawHashesMatched: hashesMatched,
            seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            notes: notes)
    }

    /// Message-ID when present; otherwise a stable digest of the identifying
    /// headers so a message without one still has an identity.
    static func identity(of email: MBOXParser.RawEmail) -> String {
        if let mid = email.headers["Message-ID"]?.trimmingCharacters(in: .whitespacesAndNewlines), !mid.isEmpty {
            return mid
        }
        let key = [email.headers["From"] ?? "", email.headers["Date"] ?? "", email.headers["Subject"] ?? ""].joined(separator: "\u{1}")
        return "nomid:" + sha256Hex(key)
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
