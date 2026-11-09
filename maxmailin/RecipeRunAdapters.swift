@testable import ArchiveCore
//
//  RecipeRunAdapters.swift
//  maxmailin
//
//  v4.0 REC-02: the seams between recipe runs and the real engines.
//
//  • RecipeJobBroker — the one call each engine makes when a job ENDS
//    (export run card, import coordinator caller, backup, restore, duplicate
//    removal, Advanced Search apply). It binds the report to the step that
//    is waiting for that kind of job and tells open runner windows.
//  • PersistedReceiptVerifier — reads the persisted result back: the export
//    receipt file, the import receipt file, the backup inventory, the
//    duplicate-cleanup registry document. A report of success whose receipt
//    is missing is "unverifiable", never success.
//  • SQLiteWorkflowRunPersistence — the runner's real saves, throwing.
//

import Foundation

extension Notification.Name {
    /// Posted on the main actor after a job report was bound to a recipe step.
    static let recipeJobReported = Notification.Name("mailin.recipeJobReported")
    /// Posted when a recipe step opens a tool; `object` is the RecipeJobTicket.
    static let recipeToolRequested = Notification.Name("mailin.recipeToolRequested")
}

@MainActor
final class RecipeJobBroker {
    static let shared = RecipeJobBroker(ledger: .production)

    let ledger: RecipeJobLedger
    init(ledger: RecipeJobLedger) { self.ledger = ledger }

    /// The ticket a tool opened from a recipe step works under (its frozen
    /// scope), while that ticket is still waiting for its job.
    private(set) var requested: RecipeJobTicket?

    func toolRequested(_ ticket: RecipeJobTicket) {
        requested = ticket
        NotificationCenter.default.post(name: .recipeToolRequested, object: ticket)
    }

    /// The open ticket for a kind of job, if a recipe step is waiting on one.
    func waitingTicket(for kind: RecipeJobKind) -> RecipeJobTicket? {
        guard let t = requested, t.kind == kind, ledger.ticket(t.jobID)?.report == nil else { return nil }
        return t
    }

    /// An engine finished a job. Binds once; returns the job ID it bound to.
    @discardableResult
    func report(_ kind: RecipeJobKind, outcome: RecipeJobOutcome, receipt: RecipeReceiptRef,
                summary: String, count: Int? = nil, spec: SearchSpec? = nil,
                destination: String? = nil, now: Date = Date()) -> UUID? {
        let report = RecipeJobReport(kind: kind, outcome: outcome, receipt: receipt, summary: summary,
                                     count: count, spec: spec, destination: destination, reportedAt: now)
        // Open runners reconcile on every report: one that did not bind (the
        // job was already reported) may still have changed its receipt on
        // disk — an export's later delivery — which they re-read.
        guard let bound = try? ledger.bind(report, now: now) else {
            NotificationCenter.default.post(name: .recipeJobReported, object: nil)
            return nil
        }
        if requested?.jobID == bound.jobID { requested = nil }
        NotificationCenter.default.post(name: .recipeJobReported, object: bound.jobID)
        return bound.jobID
    }

    // MARK: Engine adapters

    static func exportReport(_ r: ExportReceipt, receiptURL: URL?) -> (RecipeJobOutcome, String) {
        let outcome = PersistedReceiptVerifier.outcome(of: r)
        var line = "export receipt \(r.id.uuidString): written \(r.written)"
        if let requested = r.requested { line += " of \(requested)" }
        line += " · \(r.outcome.rawValue)"
        if let d = r.delivery { line += " · delivery \(d.rawValue)" }
        return (outcome, line)
    }

    func reportExport(_ r: ExportReceipt, receiptURL: URL?) {
        let (outcome, line) = Self.exportReport(r, receiptURL: receiptURL)
        report(.export, outcome: outcome,
               receipt: .init(kind: .exportReceipt, id: r.id.uuidString, path: receiptURL?.path),
               summary: line, count: r.written, destination: r.destination)
    }

    /// Backup / restore: the inventory is read back now, while the folder
    /// the person chose is reachable (security scope), and its files checked.
    func reportInventory(_ kind: RecipeJobKind, folder: URL) {
        let outcome = PersistedReceiptVerifier.inventoryOutcome(at: folder) ?? .unverifiable
        let inv = try? ArchiveBackup.load(from: folder)
        report(kind, outcome: outcome,
               receipt: .init(kind: kind == .restore ? .restoreInventory : .backupInventory,
                              id: folder.lastPathComponent, path: folder.path),
               summary: "\(kind == .restore ? "restore from" : "backup") \(folder.lastPathComponent): \(inv?.counts.emails ?? 0) emails, \(inv?.files.count ?? 0) files listed in the inventory",
               count: inv?.counts.emails, destination: kind == .backup ? folder.path : nil)
    }

    func reportImport(receipt: ImportReceipt?, receiptURL: URL?, cancelled: Bool = false, error: String? = nil) {
        if cancelled {
            report(.importArchive, outcome: .cancelled, receipt: .init(kind: .none, id: ""), summary: "Import cancelled")
            return
        }
        if let error {
            report(.importArchive, outcome: .failed, receipt: .init(kind: .none, id: ""), summary: "Import failed: \(error)")
            return
        }
        guard let receipt, let receiptURL else {
            report(.importArchive, outcome: .unverifiable, receipt: .init(kind: .none, id: ""),
                   summary: "Import finished but no receipt was written")
            return
        }
        let outcome = PersistedReceiptVerifier.outcome(of: receipt)
        report(.importArchive, outcome: outcome,
               receipt: .init(kind: .importReceipt, id: receiptURL.lastPathComponent, path: receiptURL.path),
               summary: "import receipt \(receiptURL.lastPathComponent): \(receipt.inserted.map(String.init) ?? "unknown") inserted · \(receipt.verdict.label)",
               count: receipt.inserted)
    }
}

/// Production verification against what is on disk / in the registry.
struct PersistedReceiptVerifier: RecipeReceiptVerifying {
    var exportStore = ExportReceiptStore.production
    var importStore = ImportReceiptStore.production
    /// Document lookup for duplicate cleanup receipts (injectable).
    var documentExists: (String) async -> Bool = { number in
        let docs = (try? await SQLiteEmailStore.shared.lookupDocuments(matching: number, limit: 5)) ?? []
        return docs.contains { $0.number == number }
    }

    static func outcome(of r: ExportReceipt) -> RecipeJobOutcome {
        if r.interrupted == true { return .failed }
        switch r.outcome {
        case .cancelled: return .cancelled
        case .failed: return .failed
        case .truncated, .partial, .unverified: return .partial
        case .complete:
            switch r.delivery {
            case .awaitingDelivery: return .running
            case .notSaved: return .cancelled
            case .failed: return .failed
            case .saved, .shared, .none: return .succeeded
            }
        }
    }

    /// nil = the folder cannot be read now; otherwise every listed file must exist.
    static func inventoryOutcome(at folder: URL) -> RecipeJobOutcome? {
        guard FileManager.default.isReadableFile(atPath: folder.appendingPathComponent(ArchiveBackupInventory.filename).path) else { return nil }
        guard let inv = try? ArchiveBackup.load(from: folder) else { return .unverifiable }
        let missing = inv.files.contains { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.path).path) }
        return missing ? .failed : .succeeded
    }

    static func outcome(of r: ImportReceipt) -> RecipeJobOutcome {
        switch r.verdict {
        case .complete: return .succeeded
        case .partial: return .partial
        case .failed: return .failed
        }
    }

    func verify(_ report: RecipeJobReport) async -> RecipeJobOutcome {
        let ref = report.receipt
        switch ref.kind {
        // A receipt file is the source of truth and is re-read every time:
        // an export awaiting its Share sheet becomes saved / not saved later.
        case .exportReceipt:
            guard let path = ref.path, let r = try? exportStore.load(URL(fileURLWithPath: path)),
                  r.id.uuidString == ref.id else { return .unverifiable }
            return Self.outcome(of: r)
        case .importReceipt:
            guard let path = ref.path, let r = try? importStore.load(URL(fileURLWithPath: path)) else { return .unverifiable }
            return Self.outcome(of: r)
        default:
            break
        }
        // Without a receipt file only success needs proof; a cancelled /
        // failed / partial report is never upgraded.
        guard report.outcome == .succeeded else { return report.outcome }
        switch ref.kind {
        case .exportReceipt, .importReceipt:
            return .unverifiable
        case .backupInventory, .restoreInventory:
            guard let path = ref.path else { return .unverifiable }
            // Re-checked when reachable; a folder outside the app's reach
            // (security scope ended) keeps the check made when it finished.
            return Self.inventoryOutcome(at: URL(fileURLWithPath: path)) ?? report.outcome
        case .registryDocument:
            return await documentExists(ref.id) ? .succeeded : .unverifiable
        case .measurement:
            // Counted by the app itself at report time (search, zero duplicates).
            return .succeeded
        case .none:
            return .unverifiable
        }
    }
}

/// The runner's real writes. Each throws; the audit entry is written only
/// after the confirmation is stored (rule 5).
@MainActor
struct SQLiteWorkflowRunPersistence: WorkflowRunPersistence {
    func saveFieldValues(wf: String, seq: Int, values: [String: String]) async throws {
        try await SQLiteEmailStore.shared.saveFieldValues(wf: wf, seq: seq, values: values)
    }

    func postStepDocument(_ type: DocumentType, summary: String, document: CapturedDocument, refs: String) async throws -> String {
        guard let number = await DocumentRegistry.captureStructured(type, summary: summary, document: document, refs: refs) else {
            throw WorkflowRunPersistenceError.documentNotPosted
        }
        return number
    }

    func confirmStep(wf: String, seq: Int, totalOps: Int, result: String, note: String, docNumber: String?) async throws {
        try await SQLiteEmailStore.shared.confirmOperation(
            wf: wf, seq: seq, totalOps: totalOps, result: result, note: note,
            docNumber: docNumber, confirmedBy: ForensicManager.shared.examinerName)
        ForensicManager.shared.logAction(
            "Workflow \(wf) op \(seq) confirmed",
            detail: "\(result)\(docNumber.map { " → \($0)" } ?? "")")
    }
}
