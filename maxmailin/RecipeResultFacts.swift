@testable import ArchiveCore
//
//  RecipeResultFacts.swift
//  maxmailin
//
//  v4.0 REC-05: a recipe's result is read from the job's persisted receipt —
//  the export receipt, the import receipt, the backup inventory, the duplicate
//  cleanup's registry document — never typed. Counts, source and destination,
//  hashes, the reasons anything was not written, and the verification that
//  was really performed are carried as `RecipeResultFacts`, stored with the
//  step (so they survive a restart) and used to fill the step's own fields
//  ("Matches found", "Saved to", "Verified readable").
//
//  Also REC-05: the export and duplicate tools opened from a recipe step work
//  on the run's FROZEN selection (`RecipeFrozenScope`), not on whatever list
//  happens to be on screen.
//

import Foundation

struct RecipeResultFacts: Codable, Equatable, Sendable {
    var outcome: RecipeJobOutcome
    var receiptKind: RecipeReceiptRef.Kind
    var receiptID: String
    var receiptPath: String? = nil
    /// What the job worked on (scope and search, source files), in words.
    var source: String? = nil
    var destination: String? = nil
    /// What was asked for (selected messages, files chosen, rows in scope).
    var requested: Int? = nil
    /// What the job really did (written, saved, moved to the Trash, inserted, backed up).
    var completed: Int? = nil
    var bytes: Int64? = nil
    /// Artifact hashes the receipt records (SHA-256, hex).
    var hashes: [String] = []
    /// How many per-file hashes the receipt's inventory lists.
    var hashesRecorded: Int? = nil
    var inventoryPath: String? = nil
    /// Every item asked for and not written, each with its reason.
    var skipped: [String] = []
    /// The verification the receipt records (a re-hash, a read-back), or nil when none was run.
    var verification: String? = nil
    /// True only when a verification ran and found every file matching.
    var verificationPassed: Bool? = nil
    /// RQ07: what the search could not read (locked / unread / partly read nested files).
    var coverage: String? = nil
    /// The job's own one-line statement.
    var summary: String = ""

    // MARK: Reading receipts

    /// The callback's report only (a measurement, or no receipt to read).
    init(report: RecipeJobReport, outcome: RecipeJobOutcome) {
        self.outcome = outcome
        receiptKind = report.receipt.kind
        receiptID = report.receipt.id
        receiptPath = report.receipt.path
        destination = report.destination
        completed = report.count
        summary = report.summary
        if let spec = report.spec, !spec.isEmpty { source = SearchSpecDescriber.summary(spec) }
    }

    init(export r: ExportReceipt, receiptPath: String?, outcome: RecipeJobOutcome) {
        self.outcome = outcome
        receiptKind = .exportReceipt
        receiptID = r.id.uuidString
        self.receiptPath = receiptPath
        source = r.sourceLine ?? r.title
        destination = r.destination
        requested = r.requested
        completed = r.written
        bytes = r.bytesWritten.map(Int64.init)
        hashes = r.sha256Hex.map { [$0] } ?? []
        hashesRecorded = r.checked
        inventoryPath = r.inventoryPath
        var reasons = r.skippedReasons ?? []
        if reasons.isEmpty, let excluded = r.excluded, excluded > 0 {
            reasons.append("\(excluded) excluded by the writer")
        }
        if let shortfall = r.shortfall, shortfall > 0, r.skippedReasons == nil {
            reasons.append("\(shortfall) not written — \(r.outcome.rawValue)")
        }
        if let error = r.errorMessage, r.outcome != .complete { reasons.append(error) }
        skipped = reasons
        verification = r.verificationLine
        coverage = r.coverageLine
        summary = r.verdictLine
    }

    init(importReceipt r: ImportReceipt, receiptPath: String, outcome: RecipeJobOutcome) {
        self.outcome = outcome
        receiptKind = .importReceipt
        receiptID = (receiptPath as NSString).lastPathComponent
        self.receiptPath = receiptPath
        source = r.sources.map(\.filename).joined(separator: ", ")
        requested = r.discovered
        completed = r.inserted
        bytes = Int64(r.sources.reduce(0) { $0 + $1.sizeBytes })
        hashes = r.sources.map(\.sha256)
        var reasons: [String] = []
        if let duplicates = r.duplicates, duplicates > 0 { reasons.append("\(duplicates) already in the archive") }
        if r.damaged > 0 { reasons.append("\(r.damaged) damaged") }
        if r.persistFailed > 0 { reasons.append("\(r.persistFailed) could not be stored") }
        reasons.append(contentsOf: r.fileFailures.map { "\($0.filename): \($0.message)" })
        skipped = reasons
        verification = r.verdict.label
        verificationPassed = r.verdict == .complete
        summary = "import receipt: \(r.inserted.map(String.init) ?? "unknown") inserted · \(r.verdict.label)"
    }

    /// A backup (or the backup a restore read): the inventory, and whether every listed file is there.
    init(backupFolder folder: URL, restore: Bool, outcome: RecipeJobOutcome) {
        self.outcome = outcome
        receiptKind = restore ? .restoreInventory : .backupInventory
        receiptID = folder.lastPathComponent
        receiptPath = folder.appendingPathComponent(ArchiveBackupInventory.filename).path
        inventoryPath = receiptPath
        destination = restore ? nil : folder.path
        source = restore ? folder.path : nil
        guard let inv = try? ArchiveBackup.load(from: folder) else {
            verification = "the backup inventory could not be read"
            verificationPassed = false
            return
        }
        completed = inv.counts.emails
        bytes = inv.totalBytes
        hashesRecorded = inv.files.count
        let missing = inv.files.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.path).path) }
        skipped = inv.omitted
        verification = missing.isEmpty
            ? "all \(inv.files.count) files listed in the inventory are present"
            : "\(missing.count) of \(inv.files.count) files listed in the inventory are missing"
        verificationPassed = missing.isEmpty ? nil : false
        summary = "\(restore ? "restore from" : "backup") \(folder.lastPathComponent): \(inv.counts.emails) emails, \(inv.files.count) files"
    }

    // MARK: Showing and filling

    /// The result as labelled lines (labels localized, values as recorded).
    var lines: [(label: String, value: String)] {
        var out: [(label: String, value: String)] = []
        out.append((String(localized: "Result"), summary))
        if let source, !source.isEmpty { out.append((String(localized: "Source"), source)) }
        if let requested, let completed {
            out.append((String(localized: "Done"), String(localized: "\(completed) of \(requested)")))
        } else if let completed {
            out.append((String(localized: "Done"), "\(completed)"))
        }
        if let destination, !destination.isEmpty { out.append((String(localized: "Saved to"), destination)) }
        if let bytes { out.append((String(localized: "Size"), ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))) }
        for hash in hashes { out.append(("SHA-256", hash)) }
        if let hashesRecorded { out.append((String(localized: "Hashes recorded"), "\(hashesRecorded)")) }
        if let inventoryPath { out.append((String(localized: "Inventory"), inventoryPath)) }
        if let verification { out.append((String(localized: "Verification"), verification)) }
        else { out.append((String(localized: "Verification"), String(localized: "Not verified"))) }
        if let coverage { out.append((String(localized: "Search coverage"), coverage)) }
        for reason in skipped { out.append((String(localized: "Not done"), reason)) }
        out.append((String(localized: "Receipt"), receiptPath ?? receiptID))
        return out
    }

    /// Field keys the shipped templates use for a count of what the job found or produced.
    static let countKeys: Set<String> = ["found", "matches", "messageCount", "itemCount", "totalCount", "recordCount", "finalCount"]

    /// REC-05: the step's own fields filled from the receipt — the person never
    /// types "Matches found", "Saved to" or "Verified readable" as proof.
    func fieldValues(for fields: [WorkflowField]) -> [String: String] {
        var out: [String: String] = [:]
        for field in fields {
            switch field.key {
            case let key where Self.countKeys.contains(key):
                if let completed { out[key] = "\(completed)" }
            case "destination":
                if let destination, !destination.isEmpty { out[field.key] = destination }
            case "withheld":
                out[field.key] = "\(skipped.count)"
            case "verified":
                if field.kind == .bool {
                    if let verificationPassed { out[field.key] = verificationPassed ? "Yes" : "No" }
                } else if let verification {
                    out[field.key] = verification
                }
            case "summary":
                out[field.key] = summary
            default:
                break
            }
        }
        return out
    }

    /// The facts as document fields for the step's numbered record.
    var documentFields: [CapturedDocument.Field] {
        lines.map { CapturedDocument.Field(key: $0.label, value: $0.value) }
    }
}

// MARK: - Frozen scope (REC-05: REC-01 left the tools reading the screen's list)

enum RecipeFrozenScope {
    /// The rows a run's frozen selection names: its spec, bound to the store
    /// revision the search was measured at (when recorded).
    static func query(_ selection: RecipeRunContext.Selection?, base: EmailQuery = .all) -> EmailQuery? {
        guard let selection, let spec = selection.spec, !spec.isEmpty else { return nil }
        var q = base
        q.spec = spec
        q.snapshotMaxRowID = selection.storeRevision
        return q
    }

    /// The export tool opened from a recipe step exports the run's frozen
    /// selection; opened any other way it exports what its host passed.
    static func exportScope(_ toolScope: ArchiveSelectionScope, ticket: RecipeJobTicket?) -> ArchiveSelectionScope {
        guard let ticket, ticket.kind == .export, let q = query(ticket.context.selection) else { return toolScope }
        return .query(q, exclusions: [])
    }

    /// The duplicate tool opened from a recipe step only offers copies inside
    /// the run's frozen selection: each group keeps only its members in the
    /// selection, and a group with fewer than two left is not a duplicate there.
    static func restrict(groups: [[EmailID]], to query: EmailQuery, archive: ArchiveDataService) async throws -> [[EmailID]] {
        let all = groups.flatMap { $0 }
        var inside = Set<EmailID>()
        var start = 0
        while start < all.count {
            try Task.checkCancellation()
            let slice = Array(all[start..<min(start + 500, all.count)])
            inside.formUnion(try await archive.matchingIDs(among: slice, query: query))
            start += 500
        }
        return groups.map { $0.filter(inside.contains) }.filter { $0.count > 1 }
    }
}
