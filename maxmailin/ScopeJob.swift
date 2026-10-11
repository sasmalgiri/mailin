@testable import ArchiveCore
//
//  ScopeJob.swift
//  maxmailin
//
//  The 3.0 whole-archive job engine (SCALE_TODO_3_0.md §3-F1, F2, S4, E1;
//  switch: `v3ScopeEngine`).
//
//  A tool supplies only its per-batch step; the engine supplies everything a
//  whole-archive action must have:
//   • batches (flat memory at any archive size), progress, Cancel;
//   • a crash breadcrumb (EngineGuard) and an iOS background assertion;
//   • iPhone/iPad continued processing (BGContinuedProcessingTask) so a job
//     keeps running after the user switches apps, with system progress UI;
//   • a checkpoint after every batch — quit, crash, power cut or iOS kill
//     resumes where it stopped, and the receipt says "resumed";
//   • a receipt (§3-E1): scope, archive revision, counts, "X of Y read", and
//     a fingerprint of exactly which emails were covered (order-independent,
//     so it survives resume and is reproducible).
//  The audit entry is the caller's to write — after `run` returns, i.e. after
//  the work actually happened.
//

import Foundation
import SwiftUI
import CryptoKit
#if os(iOS)
import BackgroundTasks
import os
#endif

// MARK: - Receipt

struct ScopeJobReceipt: Codable, Sendable, Equatable {
    let jobKey: String
    let title: String
    let capability: String
    let scope: String
    let archiveRevision: Int
    let totalInScope: Int
    let processed: Int
    let unreadable: Int
    let resumed: Bool
    let cancelled: Bool
    let startedAt: Date
    let finishedAt: Date
    /// Order-independent fingerprint of the processed email ids (hex).
    let fingerprint: String
    /// The scope as an `EmailQuery` (JSON) — what "Re-run and prove" re-runs.
    var queryJSON: String? = nil
    /// §3-M3: calls inside this job that fell back to the previous engine.
    var fallbacks: Int? = nil

    /// "X of Y" wording for status lines.
    var coverageLine: String {
        let base = cancelled
            ? String(localized: "Stopped after \(processed) of \(totalInScope) emails.")
            : unreadable > 0
                ? String(localized: "\(processed) of \(totalInScope) emails processed; \(unreadable) could not be read.")
                : String(localized: "All \(processed) emails in scope processed.")
        guard let fallbacks, fallbacks > 0 else { return base }
        return base + " " + String(localized: "\(fallbacks) call(s) fell back to the previous engine.")
    }

    /// Fields for a structured document (DocumentRegistry.captureStructured).
    var documentFields: [CapturedDocument.Field] {
        let f = ISO8601DateFormatter()
        return [
            .init(key: "Job", value: title),
            .init(key: "Scope", value: scope),
            .init(key: "Archive revision", value: String(archiveRevision)),
            .init(key: "Emails in scope", value: String(totalInScope)),
            .init(key: "Emails processed", value: String(processed)),
            .init(key: "Emails unreadable", value: String(unreadable)),
            .init(key: "Resumed after interruption", value: resumed ? "yes" : "no"),
            .init(key: "Cancelled", value: cancelled ? "yes" : "no"),
            .init(key: "Started", value: f.string(from: startedAt)),
            .init(key: "Finished", value: f.string(from: finishedAt)),
            .init(key: "Email-set fingerprint", value: fingerprint),
        ] + (queryJSON.map { [.init(key: "Scope query (JSON)", value: $0)] } ?? [])
          + ((fallbacks ?? 0) > 0 ? [.init(key: "Calls that fell back to the previous engine", value: String(fallbacks ?? 0))] : [])
    }
}

/// Order-independent multiset hash: each id's SHA-256 is added lane-wise
/// (4 × UInt64, wrapping). Same set ⇒ same value regardless of order or of a
/// resume in the middle; serialisable, so it is checkpointed.
struct EmailSetFingerprint: Codable, Sendable, Equatable {
    var lanes: [UInt64] = [0, 0, 0, 0]
    var count = 0

    mutating func add(_ id: UUID) {
        let digest = SHA256.hash(data: Data(id.uuidString.utf8))
        let bytes = Array(digest)
        for lane in 0..<4 {
            var v: UInt64 = 0
            for b in 0..<8 { v = (v << 8) | UInt64(bytes[lane * 8 + b]) }
            lanes[lane] = lanes[lane] &+ v
        }
        count += 1
    }

    var hex: String {
        lanes.map { String(format: "%016llx", $0) }.joined() + "-\(count)"
    }
}

// MARK: - Checkpoints (§3-F2)

struct ScopeJobCheckpoint<State: Codable & Sendable>: Codable, Sendable {
    var jobKey: String
    var title: String
    var capability: String
    var query: EmailQuery
    var cursorDate: Date?
    var cursorID: UUID?
    var processed: Int
    var unreadable: Int
    var total: Int
    var fingerprint: EmailSetFingerprint
    var state: State
    var startedAt: Date
    var appVersion: String
}

/// Where scope jobs read from and keep their checkpoints. Production uses the
/// shared archive; tests bind a disposable one with
/// `ScopeJobEnvironment.$current.withValue(...)`, so no global state changes.
struct ScopeJobEnvironment: Sendable {
    var archive: ArchiveDataService
    var store: SQLiteEmailStore
    /// Holds this environment's checkpoints and crash breadcrumbs.
    var root: URL
    /// Legal files and their database mirror (nil = the app's).
    var custodian: CustodianManager? = nil
    var legal: LegalStateMirror? = nil
    var checkpoints: URL { root.appendingPathComponent("ScopeJobs", isDirectory: true) }

    @TaskLocal static var current: ScopeJobEnvironment?

    static var archive: ArchiveDataService { current?.archive ?? .shared }
    static var store: SQLiteEmailStore { current?.store ?? .shared }
    @MainActor static var custodians: CustodianManager { current?.custodian ?? .shared }
    @MainActor static var legalMirror: LegalStateMirror { current?.legal ?? .shared }

    /// Audit entry for a 3.0 engine action — call only after the action
    /// really happened (rule 5). In a bound environment the entry is kept
    /// with it (`auditLines`), never in the real audit chain.
    @MainActor
    static func logAction(_ action: String, detail: String) {
        guard let root = current?.root else {
            ForensicManager.shared.logAction(action, detail: detail)
            return
        }
        let url = root.appendingPathComponent("audit.log")
        let line = Data((action + "\t" + detail.replacingOccurrences(of: "\n", with: " ") + "\n").utf8)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url)   // lint:allow test-environment audit log, not a user file
        }
    }

    /// Audit entries recorded in this environment, oldest first.
    func auditLines() -> [String] {
        ((try? String(contentsOf: root.appendingPathComponent("audit.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
}

enum ScopeJobCheckpointStore {
    static var directory: URL {
        if let dir = ScopeJobEnvironment.current?.checkpoints { return dir }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ScopeJobs", isDirectory: true)
    }
    private static func url(_ key: String) -> URL {
        directory.appendingPathComponent(key.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression) + ".json")
    }
    static func save<S>(_ c: ScopeJobCheckpoint<S>) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(c).write(to: url(c.jobKey), options: .atomic)
        } catch { /* a missing checkpoint costs a restart, never data */ }
    }
    static func load<S>(_ key: String, as: S.Type) -> ScopeJobCheckpoint<S>? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? JSONDecoder().decode(ScopeJobCheckpoint<S>.self, from: data)
    }
    static func remove(_ key: String) { try? FileManager.default.removeItem(at: url(key)) }

    /// Job keys with an unfinished checkpoint (for "resume" offers).
    static func pendingKeys() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
    }
}

// MARK: - Progress center

@MainActor
@Observable
final class ScopeJobCenter {
    static let shared = ScopeJobCenter()

    struct Running: Identifiable, Equatable {
        let id: String       // job key
        let title: String
        var done: Int
        var total: Int
        var resumed: Bool
    }

    private(set) var running: [Running] = []
    private var cancelled: Set<String> = []

    func started(_ key: String, title: String, done: Int, total: Int, resumed: Bool) {
        running.removeAll { $0.id == key }
        running.append(Running(id: key, title: title, done: done, total: total, resumed: resumed))
    }
    func progress(_ key: String, done: Int, total: Int) {
        guard let i = running.firstIndex(where: { $0.id == key }) else { return }
        running[i].done = done
        running[i].total = total
    }
    func finished(_ key: String) {
        running.removeAll { $0.id == key }
        cancelled.remove(key)
    }
    func cancel(_ key: String) { cancelled.insert(key) }
    func isCancelled(_ key: String) -> Bool { cancelled.contains(key) }
}

// MARK: - Progress bar (shell)

/// One row per running whole-archive job: title, "X of Y", progress, Cancel.
/// Shown in the shell so a job stays visible whichever tool is open.
struct ScopeJobProgressBar: View {
    private var center: ScopeJobCenter { .shared }
    @State private var exports = ExportRunCenter.shared
    @Environment(ModuleRegistry.self) private var modules: ModuleRegistry?
    /// §3-F1: with the 3.0 scope engine on, a running export is listed here
    /// too — one place for all running work, with the same Cancel.
    private var showsExport: Bool { (modules?.isOn(.v3ScopeEngine) ?? false) && exports.isActive }

    var body: some View {
        if !center.running.isEmpty || showsExport {
            VStack(spacing: 4) {
                if showsExport {
                    HStack(spacing: 8) {
                        Text(exports.title).font(.caption.weight(.semibold)).lineLimit(1)
                            .accessibilityHidden(true)
                        ProgressView(value: exports.fraction)
                            .frame(maxWidth: 220)
                            .accessibilityLabel(exports.title)
                            .accessibilityValue(String(localized: "\(exports.done) of \(exports.total) emails"))
                        Text("\(exports.done.formatted()) of \(exports.total.formatted())")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Spacer()
                        Button(String(localized: "Cancel")) { exports.cancel() }
                            .controlSize(.small)
                            .accessibilityLabel(String(localized: "Cancel \(exports.title)"))
                    }
                }
                ForEach(center.running) { job in
                    HStack(spacing: 8) {
                        Text(job.title).font(.caption.weight(.semibold)).lineLimit(1)
                            .accessibilityHidden(true)   // read as the progress bar's label
                        ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
                            .frame(maxWidth: 220)
                            .accessibilityLabel(job.title)
                            .accessibilityValue(String(localized: "\(job.done) of \(job.total) emails"))
                        Text("\(job.done.formatted()) of \(job.total.formatted())")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityHidden(true)   // read as the progress bar's value
                        if job.resumed {
                            Text("Resumed").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(String(localized: "Cancel")) { center.cancel(job.id) }
                            .controlSize(.small)
                            .accessibilityLabel(String(localized: "Cancel \(job.title)"))
                            .accessibilityInputLabels([String(localized: "Cancel"), String(localized: "Cancel \(job.title)")])
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
    }
}

// MARK: - Adaptive batch size (§3-F1)

/// How many full emails one batch may hold, from the memory actually free:
/// iPhone/iPad ask the OS what the app may still use
/// (`os_proc_available_memory`); the Mac uses physical memory minus what the
/// app already uses. A batch is given at most an eighth of that at a
/// conservative 256 KB per hydrated email; never more than the tool asked
/// for, never fewer than 25 (a job slows down under pressure, it never stops).
enum AdaptiveBatch {
    static let bytesPerEmail = 256 * 1024
    static let minimum = 25

    static func availableBytes() -> UInt64 {
        #if os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        let physical = ProcessInfo.processInfo.physicalMemory
        let used = currentFootprintBytes()
        // The app should not plan to use more than half of the Mac's memory.
        return physical / 2 > used ? physical / 2 - used : 0
        #endif
    }

    static func size(requested: Int, available: UInt64 = availableBytes()) -> Int {
        let fits = Int(min(available / 8 / UInt64(bytesPerEmail), UInt64(Int.max)))
        return max(minimum, min(requested, fits))
    }
}

// MARK: - Runner

enum ScopeJobError: LocalizedError {
    case alreadyRunning(String)
    var errorDescription: String? {
        switch self { case .alreadyRunning(let t): return "“\(t)” is already running." }
    }
}

@MainActor
enum ScopeJob {
    /// Runs `step` over every email in `query`, batch by batch.
    ///
    /// - Parameters:
    ///   - key: stable job identity (used for resume; same key + same query
    ///     resumes an unfinished run).
    ///   - step: called per batch with the job's state; must be idempotent per
    ///     batch (a crash inside a batch re-runs that batch on resume).
    static func run<State: Codable & Sendable>(
        key: String,
        title: String,
        capability: Capability,
        query: EmailQuery,
        batchSize: Int = 200,
        resumable: Bool = true,
        initialState: State,
        step: @MainActor (inout State, [MBOXParser.RawEmail]) async throws -> Void
    ) async throws -> (state: State, receipt: ScopeJobReceipt) {
        let center = ScopeJobCenter.shared
        guard !center.running.contains(where: { $0.id == key }) else { throw ScopeJobError.alreadyRunning(title) }

        let data = ScopeJobEnvironment.archive
        let total = (try? await data.count(query: query)) ?? 0
        let revision = (try? await ScopeJobEnvironment.store.corpusRevision()) ?? 0

        // Resume when an unfinished checkpoint for the same job and scope exists.
        var cp: ScopeJobCheckpoint<State>
        var resumed = false
        // `resumable: false` — for jobs whose per-email results live outside
        // `State` (too large to checkpoint): always start over, never leave a
        // checkpoint behind.
        if !resumable { ScopeJobCheckpointStore.remove(key) }
        if resumable, let saved = ScopeJobCheckpointStore.load(key, as: State.self), saved.query == query {
            cp = saved
            cp.total = total
            resumed = true
        } else {
            cp = ScopeJobCheckpoint(jobKey: key, title: title, capability: capability.rawValue, query: query,
                                    cursorDate: nil, cursorID: nil, processed: 0, unreadable: 0, total: total,
                                    fingerprint: EmailSetFingerprint(), state: initialState,
                                    startedAt: Date(), appVersion: EngineGuard.appVersion)
        }

        center.started(key, title: title, done: cp.processed, total: total, resumed: resumed)
        defer { center.finished(key) }
        let breadcrumb = EngineGuard.begin(capability)
        defer { EngineGuard.end(breadcrumb) }
        let assertion = BackgroundExecution.begin(title)
        defer { BackgroundExecution.end(assertion) }
        let continued = ContinuedProcessing.begin(title: title, total: total, done: cp.processed)
        defer { ContinuedProcessing.end(continued, success: !center.isCancelled(key)) }

        var wasCancelled = false
        func shouldStop() -> Bool {
            center.isCancelled(key) || assertion.isExpiring || ContinuedProcessing.isExpired(continued) || Task.isCancelled
        }

        // Counts, fingerprint and the resume position are saved together in
        // ONE checkpoint write after each batch: saving the counts before the
        // cursor moved let a stop in between re-run the batch on resume and
        // count it twice (wrong totals, wrong fingerprint on the receipt).
        func handle(_ emails: [MBOXParser.RawEmail], requested: Int) async throws {
            try await step(&cp.state, emails)
            for e in emails { cp.fingerprint.add(e.id) }
            cp.processed += emails.count
            cp.unreadable += max(0, requested - emails.count)
            center.progress(key, done: cp.processed, total: total)
            ContinuedProcessing.progress(continued, done: cp.processed, total: total)
        }

        if let text = query.text, !text.isEmpty {
            // Ranked full-text scopes: resume by skipping what was processed
            // (the ranked order is stable for an unchanged archive).
            var toSkip = cp.processed
            for try await batch in data.streamFullEmails(query: query, batchSize: AdaptiveBatch.size(requested: batchSize)) {
                if shouldStop() { wasCancelled = true; break }
                var emails = batch
                if toSkip > 0 {
                    let drop = min(toSkip, emails.count)
                    emails.removeFirst(drop)
                    toSkip -= drop
                    if emails.isEmpty { continue }
                }
                try await handle(emails, requested: emails.count)
                if resumable { ScopeJobCheckpointStore.save(cp) }
            }
        } else {
            var cursor: EmailPageCursor? = cp.cursorDate.flatMap { d in cp.cursorID.map { EmailPageCursor(beforeDate: d, beforeID: $0) } }
            while true {
                if shouldStop() { wasCancelled = true; break }
                let page = try await data.page(query: query, cursor: cursor, limit: AdaptiveBatch.size(requested: batchSize))
                if page.summaries.isEmpty { break }
                let emails = (try? await data.fullEmails(ids: page.summaries.map(\.id))) ?? []
                try await handle(emails, requested: page.summaries.count)
                guard let next = page.nextCursor else { break }
                cursor = next
                cp.cursorDate = next.beforeDate
                cp.cursorID = next.beforeID
                if resumable { ScopeJobCheckpointStore.save(cp) }
            }
        }

        // A cancelled run keeps its checkpoint so it can be resumed; a
        // finished one removes it.
        if !wasCancelled || !resumable { ScopeJobCheckpointStore.remove(key) }
        let receipt = ScopeJobReceipt(
            jobKey: key, title: title, capability: capability.rawValue,
            scope: ScopeJob.describe(query), archiveRevision: revision,
            totalInScope: total, processed: cp.processed, unreadable: cp.unreadable,
            resumed: resumed, cancelled: wasCancelled,
            startedAt: cp.startedAt, finishedAt: Date(), fingerprint: cp.fingerprint.hex,
            queryJSON: ScopeJob.json(query),
            fallbacks: EngineGuard.fallbackCount(capability, since: cp.startedAt))
        return (cp.state, receipt)
    }

    /// Ids-only variant for actions that need no bodies (holds, tags, Bates):
    /// walks summaries, never hydrates emails.
    static func runIDs<State: Codable & Sendable>(
        key: String, title: String, capability: Capability, query: EmailQuery,
        batchSize: Int = 1_000, initialState: State,
        step: @MainActor (inout State, [EmailSummary]) async throws -> Void
    ) async throws -> (state: State, receipt: ScopeJobReceipt) {
        let center = ScopeJobCenter.shared
        guard !center.running.contains(where: { $0.id == key }) else { throw ScopeJobError.alreadyRunning(title) }
        let data = ScopeJobEnvironment.archive
        let total = (try? await data.count(query: query)) ?? 0
        let revision = (try? await ScopeJobEnvironment.store.corpusRevision()) ?? 0
        center.started(key, title: title, done: 0, total: total, resumed: false)
        defer { center.finished(key) }
        let breadcrumb = EngineGuard.begin(capability)
        defer { EngineGuard.end(breadcrumb) }
        let assertion = BackgroundExecution.begin(title)
        defer { BackgroundExecution.end(assertion) }

        var state = initialState
        var fingerprint = EmailSetFingerprint()
        var processed = 0
        var cancelled = false
        let started = Date()
        for try await page in data.streamSummaries(query: query, batchSize: batchSize) {
            if center.isCancelled(key) || assertion.isExpiring || Task.isCancelled { cancelled = true; break }
            try await step(&state, page)
            for s in page { fingerprint.add(s.id) }
            processed += page.count
            center.progress(key, done: processed, total: total)
        }
        let receipt = ScopeJobReceipt(
            jobKey: key, title: title, capability: capability.rawValue, scope: describe(query),
            archiveRevision: revision, totalInScope: total, processed: processed, unreadable: 0,
            resumed: false, cancelled: cancelled, startedAt: started, finishedAt: Date(),
            fingerprint: fingerprint.hex, queryJSON: json(query),
            fallbacks: EngineGuard.fallbackCount(capability, since: started))
        return (state, receipt)
    }

    nonisolated static func json(_ q: EmailQuery) -> String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(q)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// §3-E1 "Re-run and prove": re-runs the receipt's scope now and compares
    /// the fingerprint of the email set. Same fingerprint = exactly the same
    /// emails; otherwise says how the set differs in size.
    static func prove(documentPayload payload: String) async -> String? {
        guard let data = payload.data(using: .utf8),
              let doc = try? JSONDecoder().decode(CapturedDocument.self, from: data) else { return nil }
        let fields = doc.sections.flatMap(\.fields)
        guard let expected = fields.first(where: { $0.key == "Email-set fingerprint" })?.value,
              let qjson = fields.first(where: { $0.key == "Scope query (JSON)" })?.value,
              let qdata = qjson.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let query = try? dec.decode(EmailQuery.self, from: qdata) else {
            return String(localized: "The receipt's scope could not be read.")
        }
        var fp = EmailSetFingerprint()
        do {
            for try await page in ScopeJobEnvironment.archive.streamSummaries(query: query, batchSize: 5_000) {
                for s in page { fp.add(s.id) }
            }
        } catch {
            return String(localized: "The scope could not be re-run: \(error.localizedDescription)")
        }
        let then = fields.first(where: { $0.key == "Emails processed" })?.value ?? "?"
        if fp.hex == expected {
            return String(localized: "Proved: re-running the scope now gives exactly the same \(fp.count) emails (fingerprint matches).")
        }
        return String(localized: "Not the same set: the receipt covered \(then) emails, the scope now gives \(fp.count). The archive changed since the job ran.")
    }

    /// Human-readable scope for receipts.
    nonisolated static func describe(_ q: EmailQuery) -> String {
        var parts: [String] = []
        if let t = q.text, !t.isEmpty { parts.append("search “\(t)”") }
        if let s = q.sender { parts.append("from \(s)") }
        if let r = q.recipient { parts.append("to \(r)") }
        if let d = q.domain { parts.append("domain \(d)") }
        if let tag = q.userTag { parts.append("tag \(tag)") }
        if let a = q.afterDate { parts.append("after \(ISO8601DateFormatter().string(from: a))") }
        if let b = q.beforeDate { parts.append("before \(ISO8601DateFormatter().string(from: b))") }
        if let f = q.sourceFileName { parts.append("source \(f)") }
        // §3-Q4: what was left out is part of the scope.
        for ex in q.exclusions ?? [] {
            switch ex.field {
            case .attachments: parts.append("not with attachments")
            case .pinned: parts.append("not pinned")
            case .before, .after:
                let d = Date(timeIntervalSince1970: TimeInterval(Int64(ex.value) ?? 0))
                parts.append("not \(ex.field.rawValue) \(ISO8601DateFormatter().string(from: d))")
            default: parts.append("not \(ex.field.rawValue) \(ex.value)")
            }
        }
        return parts.isEmpty ? "whole archive" : parts.joined(separator: ", ")
    }

    /// Records a finished job as a numbered, sealed document (§3-E1) when the
    /// receipts engine is on. Returns the document number.
    @discardableResult
    static func recordReceipt(_ receipt: ScopeJobReceipt, type: DocumentType = .report,
                              extra: [CapturedDocument.Field] = [], registry: ModuleRegistry?) async -> String? {
        guard registry?.isOn(.v3EvidenceReceipts) ?? false else { return nil }
        let doc = CapturedDocument(title: receipt.title, sections: [
            .init(name: String(localized: "Job receipt"), fields: receipt.documentFields + extra)
        ])
        return await DocumentRegistry.captureStructured(type, summary: "\(receipt.title) — \(receipt.coverageLine)", document: doc)
    }
}

// MARK: - iPhone/iPad continued processing (§3-S4)

/// Keeps a user-started job running after the app leaves the screen, with the
/// system's progress UI and Cancel. iOS 26+; a no-op elsewhere (macOS has no
/// such limit; older iOS uses the background assertion only).
@MainActor
enum ContinuedProcessing {
    static let identifierPrefix = "com.ecosanskriti.mailin.scopejob"

    final class Handle {
        fileprivate var task: AnyObject?
        fileprivate var expired = false
        fileprivate let submitted: String?
        fileprivate init(submitted: String?) { self.submitted = submitted }
    }

    private static var pending: [String: Handle] = [:]

    /// Registers the launch handler. Call once, early at launch.
    static func register() {
        #if os(iOS)
        if #available(iOS 26, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifierPrefix + ".*", using: .main) { task in
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                MainActor.assumeIsolated {
                    guard let handle = pending[task.identifier] else { task.setTaskCompleted(success: true); return }
                    handle.task = task
                    task.expirationHandler = { MainActor.assumeIsolated { handle.expired = true } }
                }
            }
        }
        #endif
    }

    static func begin(title: String, total: Int, done: Int) -> Handle {
        #if os(iOS)
        if #available(iOS 26, *) {
            let id = identifierPrefix + "." + UUID().uuidString
            let request = BGContinuedProcessingTaskRequest(identifier: id, title: title,
                                                           subtitle: String(localized: "\(done) of \(total) emails"))
            request.strategy = .queue
            let handle = Handle(submitted: id)
            pending[id] = handle
            do { try BGTaskScheduler.shared.submit(request) } catch { pending[id] = nil }
            return handle
        }
        #endif
        return Handle(submitted: nil)
    }

    static func progress(_ handle: Handle, done: Int, total: Int) {
        #if os(iOS)
        if #available(iOS 26, *), let task = handle.task as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = Int64(max(total, 1))
            task.progress.completedUnitCount = Int64(done)
        }
        #endif
    }

    static func isExpired(_ handle: Handle) -> Bool { handle.expired }

    static func end(_ handle: Handle, success: Bool) {
        #if os(iOS)
        if #available(iOS 26, *), let task = handle.task as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
        }
        #endif
        if let id = handle.submitted { pending[id] = nil }
    }
}
