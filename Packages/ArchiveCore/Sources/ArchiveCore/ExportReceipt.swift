//
//  ExportReceipt.swift
//  maxmailin
//
//  A8: what an export actually did, kept as a durable record. Every bulk
//  export through `UnifiedExportSections` ends in one of these — requested
//  versus written, whether it was cancelled or failed, the artifact's SHA-256
//  when the writer computed one, and the destination — so "I exported the
//  case" can be checked later against a file rather than remembered.
//
//  Receipts are JSON in Application Support/mailin/exports/receipts, one per
//  export, and are shown by the export overlay when a run finishes. An
//  export that stopped early (cancel, error, disk full) produces a receipt
//  that says so — the failure is never only a vanished progress bar.
//

import Foundation

struct ExportReceipt: Codable, Identifiable, Sendable, Equatable {
    enum Outcome: String, Codable, Sendable {
        case complete
        case truncated      // the free-tier cap wrote fewer than requested
        /// The run finished, but some requested messages could not be
        /// produced as promised and were withheld with a stated reason (audit
        /// F05/F09: a production whose input had no readable content). Never
        /// reported as `complete`.
        case partial
        /// Audit 2026-11-06 A07: every requested message was written, but
        /// the portable inventory could not be created (destination full,
        /// read-only, …). The working manifest stays beside the files; the
        /// receipt says so instead of "complete".
        case unverified
        case cancelled
        case failed
    }

    var id: UUID = UUID()
    var title: String
    var destination: String
    var isFolder: Bool
    var requested: Int?
    var written: Int
    var bytesWritten: Int?
    var outcome: Outcome
    var sha256Hex: String?
    var signaturePath: String?
    var errorMessage: String?
    var startedAt: Date
    var completedAt: Date
    /// A8 resume: for an interrupted run whose format keeps its partial output,
    /// the request that continues it from where it stopped. Optional and
    /// defaulted, so receipts written before this field decode unchanged.
    var resumeRequest: ExportRequest? = nil
    // Five jobs OUT-04/OUT-07: the reconciliation and the durable inventory.
    /// Files whose bytes were hashed as they were written and listed in the inventory.
    var checked: Int? = nil
    /// Messages in the selection intentionally not produced (withheld with a reason, or skipped by the renderer).
    var excluded: Int? = nil
    /// The per-file inventory a finished folder export left beside its files.
    var inventoryPath: String? = nil
    /// OUT-02: files beyond one per message, written because the user chose
    /// one copy per folder occurrence. Disclosed, never hidden in `written`.
    var extraCopies: Int? = nil
    /// OUT-02: true when the selection was frozen at the start of the run
    /// (a query scope bound to the rows that existed then).
    var selectionFrozen: Bool? = nil
    /// R06: the result of a later Verify export / Finish inventory action —
    /// "rehash checked N of M files match · missing k …" — kept apart from
    /// `checked` (hashes recorded while writing) and from `written`.
    var verificationLine: String? = nil
    /// OUT-04: the content statement of a later Verify export — the outputs
    /// parsed back and compared with the archive's records. Always written by
    /// a verification, even when nothing could be checked (then it says why).
    /// Kept apart from `verificationLine`, which is the byte re-hash.
    var contentLine: String? = nil
    /// The full `ExportReconciliation.ContentReport` saved beside this receipt.
    var contentReportPath: String? = nil

    /// IPAD-09 (rule 5): what happened to the file AFTER it was written, where
    /// the platform hands it on (iOS writes inside the app, then shows the Share
    /// sheet). Nil where the person chose the destination before writing (Mac).
    enum Delivery: String, Codable, Sendable {
        case saved
        case shared
        /// The Share sheet was closed without saving or sending the file.
        case notSaved
        case failed
        /// R1: written inside the app and recorded, but not yet handed on —
        /// the Share sheet / Save to Files is still to come (or was interrupted
        /// by a relaunch). The file stays offered until it is saved or shared.
        case awaitingDelivery
    }
    var delivery: Delivery? = nil
    /// Why the hand-off failed, when it did.
    var deliveryNote: String? = nil

    // R8 / OUT-06a: Recover and resume. All optional, so older receipts decode unchanged.
    /// The run's request, for a single-file container (mbox) whose partial
    /// file could not be cut back or hashed when it stopped (drive removed,
    /// process ended): Recover and resume finds the last verified boundary
    /// in the file's manifest and continues from there.
    var recoverableRequest: ExportRequest? = nil
    /// Saved when such a run STARTS and replaced when it ends: found at
    /// launch, it means mailin stopped mid-run.
    var interrupted: Bool? = nil
    /// What recovery found, in the person's language (the app writes it).
    var recoveryLine: String? = nil
    /// The engine's own statement of the recovery (`Recovery.summary`, or why none was possible).
    var recoveryDetail: String? = nil
    /// True when no boundary could be verified: Export again is offered instead.
    var recoveryFailed: Bool? = nil
    /// R3 (iOS): the container's manifest kept with the receipt, for a file
    /// written inside the app and handed on alone by the Share sheet.
    var manifestPath: String? = nil

    /// True when the card offers Recover and resume.
    var offersRecovery: Bool {
        recoverableRequest != nil && resumeRequest == nil && recoveryFailed != true
            && (outcome == .failed || outcome == .cancelled)
    }

    /// True when recovery found no verified boundary and the card offers Export again.
    var offersExportAgain: Bool { recoverableRequest != nil && recoveryFailed == true }

    /// False when the file was written but the person did not get it out of the app.
    var isDelivered: Bool { delivery != .notSaved && delivery != .failed && delivery != .awaitingDelivery }

    var durationSeconds: Double { completedAt.timeIntervalSince(startedAt) }

    /// OUT-04: selected / written / checked / excluded / failed — distinct,
    /// never double-counted ("checked" is coverage over the written files;
    /// intentional extra copies are taken out before "failed" is derived).
    var reconciliationLine: String? {
        guard checked != nil || excluded != nil else { return nil }
        let copies = extraCopies ?? 0
        let messagesWritten = max(0, written - copies)
        var parts: [String] = []
        if let requested { parts.append("selected \(requested)") }
        parts.append(copies > 0 ? "written \(messagesWritten) messages in \(written) files" : "written \(written)")
        // A07: these are the hashes recorded while writing — not a later re-read
        // of the destination, which Verify export performs separately.
        if let checked { parts.append("hashes recorded while writing \(checked) of \(written)") }
        if let excluded { parts.append("excluded \(excluded)") }
        if let requested {
            let failed = max(0, requested - messagesWritten - (excluded ?? 0))
            parts.append("failed \(failed)")
        }
        if copies > 0 { parts.append("\(copies == 1 ? "1 extra copy" : "\(copies) extra copies") — one file per folder occurrence, as chosen") }
        if selectionFrozen == true { parts.append("selection frozen at start") }
        return parts.joined(separator: " · ")
    }

    /// True when Resume can pick this export up.
    var isResumable: Bool { resumeRequest != nil && outcome != .complete }

    var destinationURL: URL { URL(fileURLWithPath: destination) }

    /// Requested minus written, when both are known and the run did not
    /// finish: what the user did NOT get.
    var shortfall: Int? {
        guard let requested, outcome != .complete else { return nil }
        return max(0, requested - written)
    }

    var verdictLine: String {
        switch outcome {
        case .complete:
            // IPAD-09: written is not delivered — a Share sheet closed without saving is not "Complete".
            switch delivery {
            case .awaitingDelivery:
                return "Written — waiting for you to save or share it: \(written) written inside mailin; nothing has left the app yet"
            case .notSaved:
                return "Written, not saved — \(written) written inside mailin; the Share sheet was closed without saving or sending the file"
            case .failed:
                return "Written, not delivered — \(written) written inside mailin; the Share sheet could not hand the file on\(deliveryNote.map { " (\($0))" } ?? "")"
            case .shared:
                return "Complete — \(written) written and handed on from the Share sheet"
            case .saved:
                return "Complete — \(written) written and saved; the saved copy read back identical"
            case nil:
                return "Complete — \(written) written"
            }
        case .truncated:
            return "Truncated — \(written) of \(requested ?? written) written (free-tier limit)"
        case .partial:
            return "Partial — \(written) of \(requested ?? written) produced; the rest withheld, see the error line"
        case .unverified:
            return "Written, record incomplete — \(written) written; the inventory file could not be created, see the error line"
        case .cancelled:
            return resumeRequest != nil
                ? "Cancelled — \(written) written before the stop; partial output kept, Resume continues from there"
                : "Cancelled — \(written) written before the stop; partial output removed where the writer could"
        case .failed:
            if interrupted == true, resumeRequest == nil {
                return "Interrupted — mailin stopped before this export finished; Recover and resume continues it from the last verified boundary in the file"
            }
            return resumeRequest != nil
                ? "Failed — \(written) written before the error; partial output kept, Resume continues from there"
                : "Failed — \(written) written before the error"
        }
    }

    /// Plain text, filable without this app.
    func plainText() -> String {
        var lines: [String] = []
        lines.append("mailin export receipt")
        lines.append("Export: \(title)")
        lines.append("Outcome: \(verdictLine)")
        lines.append("Destination: \(destination)\(isFolder ? " (folder)" : "")")
        if let requested { lines.append("Requested: \(requested)") }
        lines.append("Written: \(written)")
        if let bytesWritten { lines.append("Bytes written: \(bytesWritten)") }
        if let sha256Hex { lines.append("SHA-256: \(sha256Hex)") }
        if let signaturePath { lines.append("Signature: \(signaturePath)") }
        if let errorMessage { lines.append("Error: \(errorMessage)") }
        if let delivery { lines.append("Delivery: \(delivery.rawValue)\(deliveryNote.map { " — \($0)" } ?? "")") }
        if let resumeRequest { lines.append("Resumable: yes — continues at message \(resumeRequest.skipFirst + 1)") }
        if let recoveryDetail { lines.append("Recovery: \(recoveryDetail)") }
        if let manifestPath { lines.append("Manifest: \(manifestPath)") }
        if let verificationLine { lines.append("Verification: \(verificationLine)") }
        if let contentLine { lines.append("Content: \(contentLine)") }
        if let contentReportPath { lines.append("Content report: \(contentReportPath)") }
        lines.append("Started: \(startedAt.formatted(date: .abbreviated, time: .standard))")
        lines.append("Finished: \(completedAt.formatted(date: .abbreviated, time: .standard)) (\(String(format: "%.1f", durationSeconds)) s)")
        lines.append("Receipt id: \(id.uuidString)")
        return lines.joined(separator: "\n")
    }
}

/// JSON receipts on disk, newest discoverable by modification date.
struct ExportReceiptStore {
    let directory: URL

    static var production: ExportReceiptStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return ExportReceiptStore(directory: base.appendingPathComponent("mailin/exports/receipts", isDirectory: true))
    }

    func save(_ receipt: ExportReceipt) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent("export-\(receipt.id.uuidString).json")
        try encoder.encode(receipt).write(to: url, options: .atomic)
        return url
    }

    /// OUT-04: the full content report beside its receipt, as
    /// `export-<id>.content.json` (Codable `ExportReconciliation.ContentReport`).
    func saveContentReport(_ report: ExportReconciliation.ContentReport, for receipt: ExportReceipt) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = directory.appendingPathComponent("export-\(receipt.id.uuidString).content.json")
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    func load(_ url: URL) throws -> ExportReceipt {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExportReceipt.self, from: Data(contentsOf: url))
    }

    /// Newest first.
    func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".content.json") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
    }
}
