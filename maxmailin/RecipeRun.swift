@testable import ArchiveCore
//
//  RecipeRun.swift
//  maxmailin
//
//  v4.0 REC-01…REC-04: the truth behind a guided recipe run.
//
//  • RecipeRunContext (REC-01) — the archive/account/source scope, the search
//    and frozen selection revision, the chosen output and the permissions the
//    run works under. Captured once when the run starts (or when an old run
//    is first reopened) and written once: another window, or a later change
//    of the active archive, cannot overwrite it. Every job ticket carries a
//    copy, so a tool opened from a step receives the exact scope.
//  • Job steps (REC-02) — a step that opens import / search / dedupe / backup /
//    restore / export completes only from the job's PERSISTED result (export
//    receipt, import receipt, backup inventory, duplicate-cleanup document,
//    measured search). Opening a tool and filling every field is not a
//    result. A step records the job ID; the job's report binds to it once; a
//    duplicate callback cannot advance the step twice.
//  • RecipeRunState (REC-03) — draft … completed, derived from durable records
//    (this file's run record + the job ledger), so a restart reconnects to the
//    same jobs by ID and never issues the work again. A genuinely manual step
//    is closed by an explicit user attestation, recorded and shown as such.
//  • WorkflowRunPersistence (REC-04) — the saves a step makes are injectable,
//    so a failing store (full disk) is tested: the error is shown, typed
//    values stay dirty, nothing says Saved or completed.
//
//  Records live as JSON under Application Support (outside emails.db), so an
//  archive restore — which replaces the database — does not lose the record
//  of the restore job that a recipe is waiting on.
//

import Foundation

// MARK: - Run state (REC-03)

enum RecipeRunState: String, Codable, CaseIterable, Sendable {
    case draft, ready, running, needsAttention, paused, cancelled, partial, failed, completed

    var label: String {
        switch self {
        case .draft: return String(localized: "Draft")
        case .ready: return String(localized: "Ready")
        case .running: return String(localized: "Running")
        case .needsAttention: return String(localized: "Needs attention")
        case .paused: return String(localized: "Paused")
        case .cancelled: return String(localized: "Cancelled")
        case .partial: return String(localized: "Partial")
        case .failed: return String(localized: "Failed")
        case .completed: return String(localized: "Completed")
        }
    }
}

// MARK: - Job kinds (REC-02)

enum RecipeJobKind: String, Codable, CaseIterable, Sendable {
    case importArchive = "import"
    case search, dedupe, backup, restore, export

    /// What the run must be allowed to do for this job.
    var permission: RecipeRunContext.Permission {
        switch self {
        case .importArchive: return .writeArchive
        case .search: return .readArchive
        case .dedupe: return .moveToTrash
        case .backup, .export: return .writeFiles
        case .restore: return .replaceArchive
        }
    }

    /// The real job a step performs, or nil for a manual / record-only step.
    /// Conservative on purpose: a step is a job step only when its key, its
    /// posted document or its tool says so unambiguously.
    static func forStep(_ op: WorkflowOperation) -> RecipeJobKind? {
        guard op.launches != nil else { return nil }
        let key = op.key.lowercased()
        if key.contains("restore") { return .restore }
        if key.contains("backup") { return .backup }
        if op.postsDocType == .importRun || key == "import" || key == "ingest" { return .importArchive }
        if op.launches == .duplicateManager || key.contains("dedupe") { return .dedupe }
        if key == "export" || key == "publish" { return .export }
        if key == "search" || key == "find" { return .search }
        return nil
    }
}

/// What a job's persisted result says. `unverifiable` = the job reported
/// success but its receipt could not be found or read: never a success.
enum RecipeJobOutcome: String, Codable, Sendable {
    case running, succeeded, partial, cancelled, failed, unverifiable
}

// MARK: - Context (REC-01)

struct RecipeRunContext: Codable, Equatable, Sendable {
    static let currentVersion = 1

    enum Permission: String, Codable, CaseIterable, Sendable, Comparable {
        case readArchive, writeArchive, moveToTrash, writeFiles, replaceArchive, changeServerMail, sendMail
        static func < (a: Permission, b: Permission) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    enum Origin: String, Codable, Sendable {
        /// Captured when the run started.
        case startedWithRun
        /// The run predates v4.0: captured when it was first reopened.
        case migrated
    }

    struct Scope: Codable, Equatable, Sendable {
        /// The archive's store folder — the identity a job must act on.
        var archiveID: String
        var archiveName: String
        /// Connected-mail account (v4.0); nil = the local archive.
        var accountID: String? = nil
        /// Sources the run is limited to (empty = the whole archive).
        var sourceIDs: [String] = []
    }

    struct Selection: Codable, Equatable, Sendable {
        /// Bumped only by an explicit new search for the run; the run's
        /// later steps work on this revision.
        var revision: Int
        var spec: SearchSpec?
        var matchCount: Int?
        var frozenAt: Date
        /// REC-05: the archive's row bound when the search was measured, so
        /// the export and duplicate tools work on the rows the search saw —
        /// mail imported later is outside the selection. Nil for runs saved
        /// before it (the spec alone is then the selection).
        var storeRevision: Int64? = nil
    }

    struct Output: Codable, Equatable, Sendable {
        var destination: String?
        var format: String?
    }

    var version = RecipeRunContext.currentVersion
    var scope: Scope
    var selection: Selection? = nil
    var output: Output? = nil
    var permissions: [Permission]
    var frozenAt: Date
    var origin: Origin

    func allows(_ kind: RecipeJobKind) -> Bool { permissions.contains(kind.permission) }

    /// The permissions a definition's steps need (read is always granted).
    static func permissions(for operations: [WorkflowOperation]) -> [Permission] {
        var set: Set<Permission> = [.readArchive]
        for op in operations { if let k = RecipeJobKind.forStep(op) { set.insert(k.permission) } }
        return set.sorted()
    }

    static func capture(archiveDirectory: URL, operations: [WorkflowOperation],
                        origin: Origin, now: Date = Date()) -> RecipeRunContext {
        RecipeRunContext(
            scope: Scope(archiveID: archiveDirectory.standardizedFileURL.path,
                         archiveName: archiveDirectory.lastPathComponent),
            permissions: permissions(for: operations), frozenAt: now, origin: origin)
    }
}

// MARK: - Job tickets and reports (REC-02)

/// Where a job's result is persisted.
struct RecipeReceiptRef: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case exportReceipt, importReceipt, backupInventory, restoreInventory, registryDocument
        /// A count the app measured itself (a search result, "0 duplicates").
        case measurement
        /// No artifact (a cancelled or failed run that wrote nothing).
        case none
    }
    var kind: Kind
    /// Receipt id, document number, or a short statement for a measurement.
    var id: String
    var path: String? = nil
}

/// What a real engine said when it finished.
struct RecipeJobReport: Codable, Equatable, Sendable {
    var kind: RecipeJobKind
    var outcome: RecipeJobOutcome
    var receipt: RecipeReceiptRef
    /// English one-line statement of what the job did (e.g. "written 50 of 50").
    var summary: String
    var count: Int? = nil
    var spec: SearchSpec? = nil
    var destination: String? = nil
    var reportedAt: Date
    /// REC-05: a search's row bound at the moment it was measured.
    var storeRevision: Int64? = nil
}

struct RecipeJobTicket: Codable, Equatable, Sendable, Identifiable {
    var id: UUID { jobID }
    var jobID: UUID
    var wf: String
    var seq: Int
    var kind: RecipeJobKind
    /// The run's frozen context — the exact scope the tool is opened with.
    var context: RecipeRunContext
    var issuedAt: Date
    /// First report wins; a later (duplicate) report is ignored.
    var report: RecipeJobReport? = nil
}

/// Durable ticket ledger — one JSON file per job, keyed by job ID.
final class RecipeJobLedger: @unchecked Sendable {
    let directory: URL
    /// A ticket waits this long for its job before it stops binding reports,
    /// so an unrelated export next week cannot complete an abandoned step.
    var bindingWindow: TimeInterval = 24 * 3600
    private let lock = NSLock()

    init(directory: URL) { self.directory = directory }

    static var production: RecipeJobLedger {
        RecipeJobLedger(directory: RecipeRunFileStore.baseDirectory.appendingPathComponent("recipe-jobs", isDirectory: true))
    }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("job-\(id.uuidString).json") }

    func issue(_ ticket: RecipeJobTicket) throws {
        lock.lock(); defer { lock.unlock() }
        try write(ticket)
    }

    func ticket(_ id: UUID) -> RecipeJobTicket? {
        lock.lock(); defer { lock.unlock() }
        return read(url(id))
    }

    /// Binds `report` to the newest open ticket of its kind (within the
    /// window, and only where the run's context permits that kind of job).
    /// Returns the ticket it bound to, or nil — nothing waiting, or already bound.
    @discardableResult
    func bind(_ report: RecipeJobReport, now: Date = Date()) throws -> RecipeJobTicket? {
        lock.lock(); defer { lock.unlock() }
        let open = all().filter {
            $0.kind == report.kind && $0.report == nil && $0.context.allows(report.kind)
                && now.timeIntervalSince($0.issuedAt) <= bindingWindow && $0.issuedAt <= report.reportedAt.addingTimeInterval(1)
        }
        guard var ticket = open.max(by: { $0.issuedAt < $1.issuedAt }) else { return nil }
        ticket.report = report
        try write(ticket)
        return ticket
    }

    /// Binds `report` to one specific job. False = already reported (a
    /// duplicate callback) or no such ticket.
    @discardableResult
    func bind(_ report: RecipeJobReport, toJob id: UUID) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var ticket = read(url(id)), ticket.report == nil else { return false }
        ticket.report = report
        try write(ticket)
        return true
    }

    /// True when a step is waiting for this kind of job (within the window).
    func hasOpenTicket(for kind: RecipeJobKind, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return all().contains { $0.kind == kind && $0.report == nil && now.timeIntervalSince($0.issuedAt) <= bindingWindow }
    }

    private func all() -> [RecipeJobTicket] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap(read)
    }

    private func read(_ url: URL) -> RecipeJobTicket? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? RecipeRunFileStore.decoder.decode(RecipeJobTicket.self, from: data)
    }

    private func write(_ ticket: RecipeJobTicket) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RecipeRunFileStore.encoder.encode(ticket).write(to: url(ticket.jobID), options: .atomic)
    }
}

// MARK: - Step and run records (REC-02 / REC-03)

struct RecipeAttestation: Codable, Equatable, Sendable {
    var by: String
    var at: Date
    var statement: String
}

struct RecipeStepRecord: Codable, Equatable, Sendable {
    /// How the step's completion is evidenced. Shown with the step, so a
    /// user-written value can never read as a measured result.
    enum Evidence: String, Codable, Sendable {
        case none
        /// A real job's persisted receipt reported success.
        case measured
        /// The user stated they did a manual task (explicit attestation).
        case attested
        /// A record-only step: the values are what the user typed.
        case entered
        /// Confirmed before v4.0, when no job receipt was recorded.
        case legacyConfirmed
    }

    var seq: Int
    var jobKind: RecipeJobKind? = nil
    var jobID: UUID? = nil
    var jobOutcome: RecipeJobOutcome? = nil
    var receipt: RecipeReceiptRef? = nil
    var measuredSummary: String? = nil
    var evidence: Evidence = .none
    var attestation: RecipeAttestation? = nil
    /// The job whose success advanced this step — set once, so a duplicate
    /// report of the same job cannot advance it again.
    var advancedJobID: UUID? = nil
    /// The document the step posted, so a retried completion does not post another.
    var docNumber: String? = nil
    /// Earlier jobs of this step (cancelled / failed runs that were retried).
    var previousJobIDs: [UUID] = []
    /// REC-05: what the job's persisted receipt says — counts, source,
    /// destination, hashes, skipped reasons, verification — read back from
    /// the receipt, never typed. Optional so records saved before it decode.
    var facts: RecipeResultFacts? = nil

    /// The step may be finalized: measured success, or an explicit attestation.
    var isEvidenced: Bool {
        switch evidence {
        case .measured: return advancedJobID != nil && jobOutcome == .succeeded
        case .attested: return attestation != nil
        case .entered, .legacyConfirmed: return true
        case .none: return false
        }
    }
}

struct RecipeRunRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = RecipeRunRecord.currentVersion
    var wf: String
    var defID: String
    var context: RecipeRunContext?
    var steps: [RecipeStepRecord] = []
    var paused = false
    /// The run existed before v4.0 and was migrated on first reopen.
    var migratedFromLegacy = false
    var createdAt: Date
    var updatedAt: Date

    func step(_ seq: Int) -> RecipeStepRecord? { steps.first { $0.seq == seq } }

    mutating func updateStep(_ seq: Int, _ change: (inout RecipeStepRecord) -> Void) {
        if let i = steps.firstIndex(where: { $0.seq == seq }) {
            change(&steps[i])
        } else {
            var s = RecipeStepRecord(seq: seq)
            change(&s)
            steps.append(s)
            steps.sort { $0.seq < $1.seq }
        }
    }
}

/// Run-record persistence (injectable; the production store writes JSON).
protocol RecipeRunStoring: AnyObject {
    func load(wf: String) throws -> RecipeRunRecord?
    func save(_ record: RecipeRunRecord) throws
}

final class RecipeRunFileStore: RecipeRunStoring {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    static var baseDirectory: URL {
        let base = UITestStorageRoot.applicationSupport
        return base.appendingPathComponent("mailin", isDirectory: true)
    }
    static var production: RecipeRunFileStore {
        RecipeRunFileStore(directory: baseDirectory.appendingPathComponent("recipe-runs", isDirectory: true))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    static let decoder: JSONDecoder = {
        return JSONDecoder()
    }()

    private func url(_ wf: String) -> URL {
        let safe = wf.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("run-\(safe).json")
    }

    func load(wf: String) throws -> RecipeRunRecord? {
        let u = url(wf)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try Self.decoder.decode(RecipeRunRecord.self, from: Data(contentsOf: u))
    }

    func save(_ record: RecipeRunRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(record).write(to: url(record.wf), options: .atomic)
    }
}

// MARK: - Receipt verification (REC-02)

/// Reads a job's persisted result. Success is never taken from the callback
/// alone: the receipt must exist and say so.
protocol RecipeReceiptVerifying {
    func verify(_ report: RecipeJobReport) async -> RecipeJobOutcome
    /// REC-05: the facts the persisted receipt holds (read back, not the callback).
    func facts(_ report: RecipeJobReport, outcome: RecipeJobOutcome) async -> RecipeResultFacts
}

extension RecipeReceiptVerifying {
    func facts(_ report: RecipeJobReport, outcome: RecipeJobOutcome) async -> RecipeResultFacts {
        RecipeResultFacts(report: report, outcome: outcome)
    }
}

// MARK: - State machine (REC-03)

enum RecipeRunMachine {
    static func state(of record: RecipeRunRecord, operations: [WorkflowOperation],
                      confirmed: Set<Int>) -> RecipeRunState {
        if !operations.isEmpty && operations.allSatisfy({ confirmed.contains($0.seq) }) { return .completed }
        if record.paused { return .paused }
        let open = record.steps.filter { !confirmed.contains($0.seq) }
        if open.contains(where: { $0.jobID != nil && ($0.jobOutcome == nil || $0.jobOutcome == .running) }) { return .running }
        // An advanced step not yet confirmed (a completion that failed to save).
        if open.contains(where: { $0.jobOutcome == .unverifiable || ($0.isEvidenced && $0.evidence == .measured) }) {
            return .needsAttention
        }
        if open.contains(where: { $0.jobOutcome == .failed }) { return .failed }
        if open.contains(where: { $0.jobOutcome == .partial }) { return .partial }
        if open.contains(where: { $0.jobOutcome == .cancelled }) { return .cancelled }
        // Nothing has happened yet: no step confirmed, started, attested or entered.
        if confirmed.isEmpty && record.steps.allSatisfy({ $0.jobID == nil && ($0.evidence == .none || $0.evidence == .legacyConfirmed) }) {
            return .draft
        }
        return .ready
    }

    /// Whether a step may be finalized now. A job step needs its job's
    /// measured success; a manual tool step needs an attestation; a
    /// record-only step needs its required fields (it is the user's entry).
    static func mayComplete(_ op: WorkflowOperation, step: RecipeStepRecord?) -> Bool {
        if RecipeJobKind.forStep(op) != nil {
            guard let step else { return false }
            return step.evidence == .measured && step.isEvidenced
        }
        if op.launches != nil { return step?.attestation != nil }
        return true
    }

    /// Hands-off completion from typing (the runner's auto-complete). Only a
    /// record-only step qualifies — its fields ARE the work. A job step
    /// completes from its receipt (reconcile), a manual tool step from an
    /// explicit attestation; opening a tool is never a result (CUR-01).
    static func mayAutoCompleteFromFields(_ op: WorkflowOperation, confirmed: Bool, locked: Bool,
                                          paused: Bool, values: [String: String], touched: Bool) -> Bool {
        guard !confirmed, !locked, !paused else { return false }
        guard op.launches == nil, RecipeJobKind.forStep(op) == nil else { return false }
        guard op.fields.contains(where: { $0.required }) else { return false }
        guard WorkflowFieldValidation.missingRequired(op.fields, values: values).isEmpty else { return false }
        return touched
    }
}

// MARK: - Coordinator (REC-01…REC-03)

/// One run's durable record, its tickets and their reconciliation. Every
/// change re-reads the stored record first, so two windows on the same run
/// cannot overwrite each other's frozen context or job bindings.
@MainActor
final class RecipeRunCoordinator {
    let wf: String
    let defID: String
    let operations: [WorkflowOperation]
    let store: RecipeRunStoring
    let ledger: RecipeJobLedger
    let verifier: RecipeReceiptVerifying
    private(set) var record: RecipeRunRecord

    /// Loads the run's record, creating it for a new run, or migrating an
    /// old (pre-v4.0) saved run: steps confirmed then stay confirmed and are
    /// labelled as such; the context is captured now and marked migrated.
    init(wf: String, defID: String, operations: [WorkflowOperation],
         store: RecipeRunStoring, ledger: RecipeJobLedger, verifier: RecipeReceiptVerifying,
         isNewRun: Bool, legacyConfirmed: Set<Int>,
         captureContext: (RecipeRunContext.Origin) -> RecipeRunContext,
         now: Date = Date()) throws {
        self.wf = wf; self.defID = defID; self.operations = operations
        self.store = store; self.ledger = ledger; self.verifier = verifier
        if var existing = try store.load(wf: wf) {
            if existing.context == nil {
                existing.context = captureContext(isNewRun ? .startedWithRun : .migrated)
                try store.save(existing)
            }
            record = existing
            return
        }
        var r = RecipeRunRecord(wf: wf, defID: defID, context: captureContext(isNewRun ? .startedWithRun : .migrated),
                                migratedFromLegacy: !isNewRun, createdAt: now, updatedAt: now)
        for op in operations {
            r.updateStep(op.seq) { s in
                s.jobKind = RecipeJobKind.forStep(op)
                if legacyConfirmed.contains(op.seq) { s.evidence = .legacyConfirmed }
            }
        }
        try store.save(r)
        record = r
    }

    /// Re-read, change, save. The context is write-once inside `change`'s
    /// reach: `freeze`/`bindSelection` only fill an empty slot.
    private func update(_ change: (inout RecipeRunRecord) throws -> Void, now: Date = Date()) throws {
        var r = (try store.load(wf: wf)) ?? record
        try change(&r)
        r.updatedAt = now
        try store.save(r)
        record = r
    }

    func reload() throws { if let r = try store.load(wf: wf) { record = r } }

    var context: RecipeRunContext? { record.context }

    func state(confirmed: Set<Int>) -> RecipeRunState {
        RecipeRunMachine.state(of: record, operations: operations, confirmed: confirmed)
    }

    /// Start (or reconnect to) the job a step performs. A step whose job is
    /// running or already succeeded gets the SAME ticket back — opening the
    /// tool again never issues the work twice. Only a cancelled / failed /
    /// partial job is replaced by a new one (a retry).
    func beginJob(seq: Int, now: Date = Date()) throws -> RecipeJobTicket? {
        guard let op = operations.first(where: { $0.seq == seq }), let kind = RecipeJobKind.forStep(op),
              let ctx = record.context, ctx.allows(kind) else { return nil }
        if let id = record.step(seq)?.jobID, let existing = ledger.ticket(id) {
            let outcome = record.step(seq)?.jobOutcome
            if existing.report == nil || outcome == nil || outcome == .running || outcome == .succeeded {
                return existing
            }
        }
        let ticket = RecipeJobTicket(jobID: UUID(), wf: wf, seq: seq, kind: kind, context: ctx, issuedAt: now)
        try ledger.issue(ticket)
        try update({ r in
            r.updateStep(seq) { s in
                if let old = s.jobID { s.previousJobIDs.append(old) }
                s.jobKind = kind; s.jobID = ticket.jobID; s.jobOutcome = .running
                s.receipt = nil; s.measuredSummary = nil; s.advancedJobID = nil
                if s.evidence == .measured { s.evidence = .none }
            }
        }, now: now)
        return ticket
    }

    /// The user stops waiting for a job that never started (tool closed).
    func stopWaiting(seq: Int, now: Date = Date()) throws {
        guard let id = record.step(seq)?.jobID, let kind = record.step(seq)?.jobKind else { return }
        _ = try ledger.bind(RecipeJobReport(kind: kind, outcome: .cancelled, receipt: .init(kind: .none, id: ""),
                                            summary: "Stopped waiting — no job result was received", reportedAt: now),
                            toJob: id)
        try update({ r in r.updateStep(seq) { s in if s.advancedJobID == nil { s.jobOutcome = .cancelled } } }, now: now)
    }

    /// Reads every waiting step's job from the ledger and its persisted
    /// receipt. Returns the steps whose job newly SUCCEEDED (each job once).
    @discardableResult
    func reconcile(now: Date = Date()) async throws -> [Int] {
        try reload()
        var results: [Int: (RecipeJobReport, RecipeJobOutcome, RecipeResultFacts)] = [:]
        for s in record.steps {
            guard let id = s.jobID, let report = ledger.ticket(id)?.report else { continue }
            if s.advancedJobID == id { continue }
            let outcome = await verifier.verify(report)
            results[s.seq] = (report, outcome, await verifier.facts(report, outcome: outcome))
        }
        guard !results.isEmpty else { return [] }
        var advanced: [Int] = []
        try update({ r in
            for (seq, pair) in results {
                let (report, outcome, facts) = pair
                r.updateStep(seq) { s in
                    guard let id = s.jobID, s.advancedJobID != id else { return }
                    s.jobOutcome = outcome
                    s.receipt = report.receipt
                    s.measuredSummary = report.summary
                    s.facts = facts
                    if outcome == .succeeded {
                        s.advancedJobID = id
                        s.evidence = .measured
                        advanced.append(seq)
                    }
                }
                // REC-01: a search's measured result becomes the run's frozen
                // selection revision; an export's destination its output. Each
                // only fills an empty slot.
                if outcome == .succeeded, var ctx = r.context {
                    if report.kind == .search, ctx.selection == nil {
                        ctx.selection = .init(revision: 1, spec: report.spec, matchCount: report.count, frozenAt: report.reportedAt,
                                             storeRevision: report.storeRevision)
                    }
                    if report.kind == .export || report.kind == .backup, ctx.output == nil, let d = report.destination {
                        ctx.output = .init(destination: d, format: nil)
                    }
                    r.context = ctx
                }
            }
        }, now: now)
        return advanced.sorted()
    }

    /// Steps whose evidence allows completion but which are not yet confirmed
    /// (e.g. a completion whose save failed — retried, never re-run).
    func pendingCompletions(confirmed: Set<Int>) -> [Int] {
        record.steps.filter { !confirmed.contains($0.seq) && $0.evidence == .measured && $0.isEvidenced }.map(\.seq)
    }

    /// REC-03: the explicit statement that a manual task was done. Never
    /// allowed for a job step — its result must come from the job.
    func attest(seq: Int, by: String, statement: String, now: Date = Date()) throws -> Bool {
        guard let op = operations.first(where: { $0.seq == seq }), RecipeJobKind.forStep(op) == nil else { return false }
        try update({ r in
            r.updateStep(seq) { s in
                s.evidence = .attested
                s.attestation = RecipeAttestation(by: by, at: now, statement: statement)
            }
        }, now: now)
        return true
    }

    func markEntered(seq: Int) throws {
        try update { r in r.updateStep(seq) { s in if s.evidence == .none { s.evidence = .entered } } }
    }

    func recordDocument(seq: Int, number: String) throws {
        try update { r in r.updateStep(seq) { s in s.docNumber = number } }
    }

    func setPaused(_ paused: Bool) throws { try update { r in r.paused = paused } }

    /// Write-once: fills the context only when the record has none.
    @discardableResult
    func freeze(_ ctx: RecipeRunContext) throws -> RecipeRunContext {
        try update { r in if r.context == nil { r.context = ctx } }
        return record.context ?? ctx
    }
}

// MARK: - Step saves and completion (REC-04)

/// The three writes a step makes, injectable so a failing store is tested.
@MainActor
protocol WorkflowRunPersistence {
    func saveFieldValues(wf: String, seq: Int, values: [String: String]) async throws
    func postStepDocument(_ type: DocumentType, summary: String, document: CapturedDocument, refs: String) async throws -> String
    func confirmStep(wf: String, seq: Int, totalOps: Int, result: String, note: String, docNumber: String?) async throws
}

enum WorkflowRunPersistenceError: LocalizedError, Equatable {
    case documentNotPosted
    var errorDescription: String? {
        switch self {
        case .documentNotPosted: return String(localized: "The step's document could not be numbered and saved.")
        }
    }
}

/// The save state the runner shows. A failed save keeps the step dirty and
/// its error on screen; only a real save clears dirty and flashes Saved.
struct RecipeStepEditState: Equatable {
    var dirty: Set<Int> = []
    var savedFlash: Int? = nil
    var saveErrors: [Int: String] = [:]

    mutating func edited(_ seq: Int) { dirty.insert(seq) }

    mutating func record(_ result: RecipeStepCommitter.SaveResult, seq: Int) {
        switch result {
        case .saved:
            dirty.remove(seq); saveErrors[seq] = nil; savedFlash = seq
        case .failed(let message):
            dirty.insert(seq); saveErrors[seq] = message
            if savedFlash == seq { savedFlash = nil }
        }
    }
}

@MainActor
struct RecipeStepCommitter {
    let persistence: WorkflowRunPersistence

    enum SaveResult: Equatable { case saved, failed(String) }

    enum CompletionResult: Equatable {
        case completed(docNumber: String?)
        /// Nothing is confirmed. `docNumber` is a document that WAS posted
        /// before the failure — kept so a retry does not post a second one.
        case failed(String, docNumber: String?)
    }

    struct Completion {
        var wf: String
        var op: WorkflowOperation
        var workflowName: String
        var totalOps: Int
        var values: [String: String]
        var extraFields: [CapturedDocument.Field] = []
        var note: String
        var result: String
        var existingDocNumber: String? = nil
    }

    func save(wf: String, seq: Int, values: [String: String]) async -> SaveResult {
        do {
            try await persistence.saveFieldValues(wf: wf, seq: seq, values: values)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Save → post (once) → confirm. Any failure stops before the confirmation.
    func complete(_ c: Completion) async -> CompletionResult {
        do {
            try await persistence.saveFieldValues(wf: c.wf, seq: c.op.seq, values: c.values)
        } catch {
            return .failed(error.localizedDescription, docNumber: c.existingDocNumber)
        }
        var doc = c.existingDocNumber
        if let type = c.op.postsDocType, doc == nil {
            var fields: [CapturedDocument.Field] = [
                .init(key: "Workflow", value: c.workflowName),
                .init(key: "Step", value: c.op.title),
                .init(key: "Run", value: c.wf),
            ]
            for f in c.op.fields where !(c.values[f.key] ?? "").isEmpty {
                fields.append(.init(key: f.label, value: c.values[f.key] ?? ""))
            }
            fields.append(contentsOf: c.extraFields)
            if !c.note.isEmpty { fields.append(.init(key: "Note", value: c.note)) }
            do {
                doc = try await persistence.postStepDocument(
                    type, summary: "\(c.workflowName): \(c.op.title)",
                    document: CapturedDocument(title: "\(c.workflowName) — \(c.op.title)",
                                               sections: [.init(name: c.op.title, fields: fields)]),
                    refs: c.wf)
            } catch {
                return .failed(error.localizedDescription, docNumber: nil)
            }
        }
        do {
            try await persistence.confirmStep(wf: c.wf, seq: c.op.seq, totalOps: c.totalOps,
                                              result: c.result, note: c.note, docNumber: doc)
        } catch {
            return .failed(error.localizedDescription, docNumber: doc)
        }
        return .completed(docNumber: doc)
    }
}
