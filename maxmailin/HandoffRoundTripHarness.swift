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
        // Identity → row id, so a mismatch can fetch its original afterwards
        // and NAME the first divergence instead of just counting it.
        var rowIDs: [String: UUID] = [:]
        for try await batch in archive.streamSelected(scope: .query(.all, exclusions: []), batchSize: 200) {
            for email in batch {
                let id = identity(of: email)
                identities.insert(id)
                rowIDs[id] = email.id
                for att in email.attachments {
                    attachments.insert(.init(messageID: id, filename: att.filename, size: att.size))
                }
                if !email.rawSource.isEmpty {
                    rawHashes[id] = messageHash(email.rawSource)
                }
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
        var mismatchedRaw: [(id: String, roundTripped: String)] = []
        for partition in partitionFiles {
            let report = try await ParserFactory.parseStreamingCallback(fileURL: partition, senderEmail: "", batchSize: 200) { emails in
                for email in emails {
                    reparsed += 1
                    let id = identity(of: email)
                    seen.insert(id)
                    for att in email.attachments {
                        attachmentsAfter.insert(.init(messageID: id, filename: att.filename, size: att.size))
                    }
                    if let original = rawHashes[id], !email.rawSource.isEmpty {
                        if messageHash(email.rawSource) == original {
                            hashesMatched += 1
                        } else if mismatchedRaw.count < 3 {
                            mismatchedRaw.append((id, email.rawSource))
                        }
                    }
                }
            }
            reparseFailed += report.failed
        }

        // Name the first divergences, fetching each original back from the
        // archive by row id.
        for mismatch in mismatchedRaw {
            guard let rowID = rowIDs[mismatch.id],
                  let original = try? await archive.fullEmail(id: rowID), !original.rawSource.isEmpty else { continue }
            notes.append(firstDivergence(original: original.rawSource, roundTripped: mismatch.roundTripped, id: mismatch.id))
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

    /// Hash of the MESSAGE, not of its mbox framing. The stored raw carries
    /// whatever envelope line the parser saw (the source's own or a synthetic
    /// `From MAILER-DAEMON …`) and whatever trailing separator the container
    /// used; both are container metadata that a different container may
    /// legitimately write differently. Everything from the first header byte
    /// to the last body byte must match exactly.
    /// "First raw divergence <id>: line N — original «…» vs round-tripped «…»",
    /// on the framing-normalised texts the hash is taken over.
    static func firstDivergence(original: String, roundTripped: String, id: String) -> String {
        // Bytes, not Characters: Swift folds CRLF into one Character and a
        // Character split on "\n" sees a CRLF message as a single line.
        let a = messageBytes(original), b = messageBytes(roundTripped)
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        if i == a.count, i == b.count { return "First raw divergence \(id): normalised bytes identical (\(a.count)) — hash inputs differ elsewhere" }
        func window(_ bytes: [UInt8]) -> String {
            let lo = max(0, i - 80), hi = min(bytes.count, i + 80)
            return String(decoding: bytes[lo..<hi], as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "␍").replacingOccurrences(of: "\n", with: "␊")
        }
        let line = a[0..<min(i, a.count)].filter { $0 == 0x0A }.count + 1
        return "First raw divergence \(id): byte \(i) (line \(line)) of \(a.count)/\(b.count) — original «\(window(a))» vs round-tripped «\(window(b))»"
    }

    static func messageHash(_ raw: String) -> String {
        SHA256.hash(data: Data(messageBytes(raw))).map { String(format: "%02x", $0) }.joined()
    }

    /// The message's bytes with mbox framing removed: no envelope line, no
    /// trailing CR/LF run. Trimmed at the BYTE level — `hasSuffix("\n")` is
    /// false for a String ending in CRLF, because Swift treats CRLF as one
    /// Character (found 2026-09-27 by the executed round trip).
    static func messageBytes(_ raw: String) -> [UInt8] {
        var bytes = Array(MBOXRecordBuilder.strippingEnvelopeLine(raw).utf8)
        while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
        return bytes
    }
}
