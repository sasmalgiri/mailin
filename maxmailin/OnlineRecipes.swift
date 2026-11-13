@testable import ArchiveCore
import MailConnectivity
//
//  OnlineRecipes.swift
//  maxmailin
//
//  v4.0 REC-07 (plan §2.1 "Archive and safely clean up", §8.2, §8.5, §9.1
//  RQ09/RQ10): the connected-mail recipes, built on the engines V4-04…V4-11
//  already ship — never a second capture or server-action stack.
//
//    1. Capture selectively      account → folders / labels + date range +
//                                sender → preview (counts from the provider's
//                                listing, frozen) → the account's SyncEngine
//                                captures exactly that list → result read from
//                                the capture receipt (captured / unavailable /
//                                failed, each with its reason)
//    2. Archive and safely clean up — the online half
//                                after the capture is verified, an OPTIONAL
//                                server cleanup through `SafeCleanup`: exact
//                                remote effect with counts and exclusions (not
//                                captured, failed, held, other account …),
//                                a confirmation naming the count, per-item
//                                journalled execution, a reconciliation
//                                receipt. Needs the account's "Change server
//                                mail" permission; without it the recipe says
//                                so and sends nothing. Removing mail from the
//                                server never removes mailin's copy, and it is
//                                a separate choice from mailin's own Trash
//                                (the local duplicate clean-up recipe).
//    3. Capture rules (RQ09)     "when a new message matching SearchSpec X is
//                                captured, add tag Y": evaluated after capture
//                                AND indexing, exactly once per message and
//                                rule version (a durable ledger survives replay
//                                and restart), historical arrivals (old header
//                                date, captured now) included and counted on
//                                their own, overlapping rules never tag twice.
//

import Foundation
import os

// MARK: - Kinds and results

enum OnlineRecipeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case captureSelectively, archiveAndCleanServer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureSelectively: return String(localized: "Capture selectively")
        case .archiveAndCleanServer: return String(localized: "Archive and clean up the server")
        }
    }

    var summary: String {
        switch self {
        case .captureSelectively:
            return String(localized: "Choose an account, folders, dates or a sender, preview what will be saved, then save exactly that.")
        case .archiveAndCleanServer:
            return String(localized: "Save the selected mail, verify every copy, then optionally move only verified messages to the server's Trash. mailin's copies are kept.")
        }
    }

    var icon: String {
        switch self {
        case .captureSelectively: return "tray.and.arrow.down"
        case .archiveAndCleanServer: return "externaldrive.badge.icloud"
        }
    }
}

enum ConnectedRecipeError: LocalizedError, Equatable {
    case noEngine(String?)
    case notPermitted(String)
    case listingStopped(String)

    var errorDescription: String? {
        switch self {
        case .noEngine(let why): return why ?? String(localized: "Saving mail is switched off for this account.")
        case .notPermitted(let why): return why
        case .listingStopped(let why): return String(localized: "The server's list could not be read to its end: \(why)")
        }
    }
}

/// An online recipe's result, kept on disk like the practical recipes'.
struct OnlineRecipeResult: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var recipe: OnlineRecipeKind
    var state: RecipeRunState
    var startedAt: Date
    var finishedAt: Date
    var facts: [RecipeResultFacts]
    var notes: [String] = []

    var isCompleted: Bool { state == .completed }
}

final class OnlineRecipeResultStore: @unchecked Sendable {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    static var production: OnlineRecipeResultStore {
        OnlineRecipeResultStore(directory: RecipeRunFileStore.baseDirectory.appendingPathComponent("online-recipes", isDirectory: true))
    }

    @discardableResult
    func save(_ result: OnlineRecipeResult) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("result-\(result.id.uuidString).json")
        try RecipeRunFileStore.encoder.encode(result).write(to: url, options: .atomic)
        return url
    }

    func list() -> [OnlineRecipeResult] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? RecipeRunFileStore.decoder.decode(OnlineRecipeResult.self, from: Data(contentsOf: $0)) }
            .sorted { $0.finishedAt > $1.finishedAt }
    }
}

// MARK: - Previews

/// What a selective capture will do, before anything is saved (rule 4).
struct OnlineCapturePreview: Sendable {
    let listing: SelectiveCaptureListing
    let accountDisplay: String
    /// Messages of the listing this account already preserved (not downloaded again).
    let alreadySaved: Int

    var toCapture: Int { listing.items.count }
    var toDownload: Int { max(0, toCapture - alreadySaved) }

    var lines: [String] {
        var out = [String(localized: "\(listing.listed) messages listed in \(listing.folders.count) folders of \(accountDisplay)")]
        out.append(String(localized: "\(toCapture) will be saved: \(toDownload) new, \(alreadySaved) already in mailin"))
        if listing.excludedByDate > 0 { out.append(String(localized: "\(listing.excludedByDate) outside the date range — not saved")) }
        if listing.excludedBySender > 0 { out.append(String(localized: "\(listing.excludedBySender) from other senders — not saved")) }
        if listing.undetermined > 0 {
            out.append(listing.filter.includeUndetermined
                ? String(localized: "\(listing.undetermined) included because the server's list does not show their date or sender")
                : String(localized: "\(listing.undetermined) left out because the server's list does not show their date or sender"))
        }
        return out
    }
}

/// A capture's outcome, read back from the archive's run items.
struct OnlineCaptureOutcome: Sendable {
    let report: SyncRunReport
    let items: [CaptureRunItem]
    let result: OnlineRecipeResult

    var captured: [CaptureRunItem] { items.filter { $0.state == .stored || $0.state == .alreadyPreserved } }
    var failed: [CaptureRunItem] { items.filter { $0.state == .failed } }
    var unavailable: [CaptureRunItem] { items.filter { $0.state == .unavailable } }
}

/// The server cleanup's review: the plan, or why there can be none.
struct OnlineCleanupReview: Sendable {
    let accountID: UUID
    let accountDisplay: String
    /// Set when the account may not change server mail: nothing will be sent.
    let refusal: String?
    let plan: CleanupPlan?
    /// Selected records that did not come from any connected account (imported files).
    let notConnected: Int
    let checks: CleanupSafetyChecks

    var confirmTitle: String {
        let n = plan?.included.count ?? 0
        switch plan?.action {
        case .archiveOnServer?: return String(localized: "Archive \(n) messages on the server")
        default: return String(localized: "Move \(n) messages to the server's Trash")
        }
    }

    /// Exclusions by reason, in words, for the preview.
    var exclusionLines: [String] {
        guard let plan else { return [] }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for e in plan.excluded {
            let text = OnlineRecipeEngine.exclusionText(e.reason)
            if counts[text] == nil { order.append(text) }
            counts[text, default: 0] += 1
        }
        var out = order.map { "\(counts[$0] ?? 0) · \($0)" }
        if notConnected > 0 { out.append(String(localized: "\(notConnected) · Not from a connected account (imported from a file)")) }
        return out
    }
}

// MARK: - Engine

@MainActor
final class OnlineRecipeEngine {
    struct Environment {
        var runtime: ConnectedMailRuntime
        var results: OnlineRecipeResultStore
        /// Where the journalled server actions and cleanup receipts are kept.
        var journalDirectory: URL
        /// A reason when a record is under a hold (legal / retention), else nil.
        var hold: @Sendable (UUID) async -> String?

        @MainActor static func production(runtime: ConnectedMailRuntime) -> Environment {
            let store = runtime.sink.store
            return Environment(runtime: runtime, results: .production,
                               journalDirectory: store.storeDirectory.appendingPathComponent("remote-operations", isDirectory: true),
                               hold: { id in
                                   let held = (try? await store.legalHoldIDs()) ?? []
                                   return held.contains(id) ? String(localized: "Legal hold") : nil
                               })
        }
    }

    let env: Environment
    init(env: Environment) { self.env = env }

    private var runtime: ConnectedMailRuntime { env.runtime }

    // MARK: 1 — capture selectively

    func previewCapture(account id: UUID, filter: SelectiveCaptureFilter) async throws -> OnlineCapturePreview {
        let account = try await runtime.registry.account(id)
        let listing: SelectiveCaptureListing
        do { listing = try await runtime.listSelection(id, filter: filter) } catch let stopped as SelectiveListingStopped {
            throw ConnectedRecipeError.listingStopped(Self.outcomeText(stopped.outcome))
        }
        var already = 0
        for item in listing.items {
            if try await runtime.sink.preservedEmailID(accountID: id, identity: item.ref.identity) != nil { already += 1 }
        }
        return OnlineCapturePreview(listing: listing, accountDisplay: account.displayIdentity, alreadySaved: already)
    }

    /// Captures exactly the preview's frozen list; the result is read from
    /// the run's receipt and items (REC-05), never from the listing.
    func capture(_ preview: OnlineCapturePreview, recipe: OnlineRecipeKind = .captureSelectively) async -> OnlineCaptureOutcome? {
        let started = Date()
        guard let report = await runtime.captureListed(preview.listing) else { return nil }
        var items: [CaptureRunItem] = []
        var readError: String?
        if let runID = report.runID {
            do { items = try await runtime.sink.runItems(runID) } catch { readError = error.localizedDescription }
        }
        let facts = Self.captureFacts(preview: preview, report: report, items: items, readError: readError)
        let result = finish(recipe, started: started, facts: [facts], notes: preview.lines)
        return OnlineCaptureOutcome(report: report, items: items, result: result)
    }

    nonisolated static func captureFacts(preview: OnlineCapturePreview, report: SyncRunReport, items: [CaptureRunItem],
                             readError: String?) -> RecipeResultFacts {
        let receipt = report.receipt
        let outcome: RecipeJobOutcome
        switch report.outcome {
        case .completed: outcome = .succeeded
        case .completedWithFailures: outcome = .partial
        case .cancelled: outcome = .cancelled
        case .paused, .needsSignIn, .notPermitted: outcome = .partial
        case .failed, .aborted, .alreadyRunning: outcome = .failed
        }
        var facts = RecipeResultFacts(
            report: RecipeJobReport(kind: .importArchive, outcome: outcome,
                                    receipt: .init(kind: report.runID == nil ? .none : .importReceipt, id: report.runID ?? ""),
                                    summary: "capture run: \(receipt?.stored ?? 0) saved, \(receipt?.alreadyPreserved ?? 0) already saved, "
                                        + "\(receipt?.failed ?? 0) failed, \(receipt?.unavailable ?? 0) unavailable — \(outcomeText(report.outcome))",
                                    reportedAt: report.endedAt),
            outcome: readError == nil ? outcome : .unverifiable)
        facts.source = "\(preview.accountDisplay) · \(preview.listing.filter.description)"
        facts.destination = String(localized: "this archive")
        facts.requested = preview.toCapture
        facts.completed = (receipt?.stored ?? 0) + (receipt?.alreadyPreserved ?? 0)
        facts.bytes = items.compactMap(\.byteCount).reduce(0, +)
        var reasons: [String] = []
        for item in items where item.state == .failed || item.state == .unavailable || item.state == .pending {
            let what = item.state == .unavailable ? "unavailable" : item.state == .pending ? "no outcome" : "failed"
            reasons.append("\(item.identityKey.replacingOccurrences(of: "\u{1F}", with: " · ")) — \(what): \(item.reason ?? "no reason recorded")")
        }
        if let readError { reasons.append("the run's items could not be read: \(readError)") }
        facts.skipped = reasons
        // Verification: every frozen message has exactly one recorded outcome.
        let listed = Set(preview.listing.identityKeys)
        let recorded = Set(items.map(\.identityKey))
        let accounted = items.filter { $0.state != .pending }.count
        facts.verification = "\(accounted) of \(listed.count) listed messages have a recorded outcome"
            + (listed == recorded ? "; the run holds exactly the previewed messages" : "; the run does NOT hold exactly the previewed messages")
        facts.verificationPassed = readError == nil && listed == recorded && accounted == listed.count
        return facts
    }

    // MARK: 2 — server cleanup after verified capture

    /// Cleanup candidates from a capture: every previewed message, with its
    /// archive record when it was saved (failed / unavailable ones keep no
    /// record and are excluded with their reason by `SafeCleanup`).
    func candidates(from outcome: OnlineCaptureOutcome, preview: OnlineCapturePreview) -> [CleanupCandidate] {
        let byKey = Dictionary(outcome.items.map { ($0.identityKey, $0) }, uniquingKeysWith: { a, _ in a })
        return preview.listing.items.map { item in
            let key = (try? item.ref.identity.key()) ?? ""
            let record = byKey[key]
            let saved = record?.state == .stored || record?.state == .alreadyPreserved
            return CleanupCandidate(accountID: preview.listing.accountID, identity: item.ref.identity,
                                    emailID: saved ? record?.emailID : nil,
                                    folder: Self.folderForCleanup(item.folders.map(\.serverID), identity: item.ref.identity))
        }
    }

    /// Cleanup candidates from archive records (a frozen search's matches):
    /// each record's provider identity from its provenance. Records from no
    /// connected account are counted, never sent.
    func candidates(fromEmailIDs ids: [UUID]) async -> (candidates: [CleanupCandidate], notConnected: Int) {
        var out: [CleanupCandidate] = []
        var notConnected = 0
        for id in ids {
            guard let p = try? await runtime.sink.provenance(emailID: id),
                  let identity = try? ProviderMessageIdentity(key: p.identityKey) else { notConnected += 1; continue }
            out.append(CleanupCandidate(accountID: p.accountID, identity: identity, emailID: id,
                                        folder: Self.folderForCleanup(p.memberships, identity: identity, mailbox: p.mailbox)))
        }
        return (out, notConnected)
    }

    nonisolated static func folderForCleanup(_ memberships: [String], identity: ProviderMessageIdentity, mailbox: String? = nil) -> String {
        if case .imap(let box, _, _) = identity { return box }
        if memberships.contains("INBOX") { return "INBOX" }
        return mailbox ?? memberships.first ?? "INBOX"
    }

    /// The review (rule 4): exact remote effect, exclusions by reason. Reads
    /// the archive only; sends nothing. Without "Change server mail" the
    /// review says so and holds no plan.
    func cleanupReview(account id: UUID, candidates: [CleanupCandidate], notConnected: Int = 0,
                       action: CleanupAction, captureFailures: [String: String] = [:]) async throws -> OnlineCleanupReview {
        let account = try await runtime.registry.account(id)
        let checks = safetyChecks(captureFailures: captureFailures)
        if let refusal = await runtime.serverChangeRefusal(id) {
            return OnlineCleanupReview(accountID: id, accountDisplay: account.displayIdentity, refusal: refusal, plan: nil,
                                       notConnected: notConnected, checks: checks)
        }
        let plan = await SafeCleanup.plan(candidates, action: action, account: account, checks: checks)
        return OnlineCleanupReview(accountID: id, accountDisplay: account.displayIdentity, refusal: nil, plan: plan,
                                   notConnected: notConnected, checks: checks)
    }

    /// Failed / unavailable capture outcomes, by identity key, for the review.
    nonisolated static func captureFailures(_ outcome: OnlineCaptureOutcome) -> [String: String] {
        var out: [String: String] = [:]
        for item in outcome.items where item.state == .failed || item.state == .unavailable || item.state == .pending {
            out[item.identityKey] = item.reason ?? item.state.rawValue
        }
        return out
    }

    func safetyChecks(captureFailures: [String: String]) -> CleanupSafetyChecks {
        let sink = runtime.sink
        let store = sink.store
        let verifier = ConnectedArchiveCopyVerifier(sink: sink) { _, p in
            let url = store.blobStore.url(for: p.sha256)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = ((try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? -1
            return (try ExportInventory.sha256(of: url).lowercased(), size)
        }
        let hold = env.hold
        return CleanupSafetyChecks(archive: verifier,
                                   hold: { emailID, _ in guard let emailID else { return nil }; return await hold(emailID) },
                                   captureFailure: { identity in
                                       guard let key = try? identity.key() else { return nil }
                                       return captureFailures[key]
                                   })
    }

    /// Runs the confirmed plan item by item (journalled), then reads back the
    /// receipt. Throws nothing: a refusal or mismatch is the result.
    func executeCleanup(_ review: OnlineCleanupReview, confirmation: CleanupConfirmation,
                        recipe: OnlineRecipeKind = .archiveAndCleanServer, earlier: [RecipeResultFacts] = []) async -> OnlineRecipeResult {
        let started = Date()
        guard review.refusal == nil, let plan = review.plan else {
            return finish(recipe, started: started, facts: earlier + [Self.notSentFacts(review.refusal ?? String(localized: "There is no reviewed cleanup plan."), review: review)])
        }
        do {
            let journal = try RemoteOperationJournal(storeDirectory: env.journalDirectory)
            let service = try await runtime.actionService(review.accountID, journal: journal)
            let receipt = try await SafeCleanup.execute(plan, confirmation: confirmation, service: service, checks: review.checks)
            let saved = try? await journal.receipt(planID: plan.planID)
            return finish(recipe, started: started, facts: earlier + [Self.cleanupFacts(receipt, saved: saved, review: review)])
        } catch {
            return finish(recipe, started: started, facts: earlier + [Self.notSentFacts(error.localizedDescription, review: review)])
        }
    }

    nonisolated static func notSentFacts(_ why: String, review: OnlineCleanupReview) -> RecipeResultFacts {
        var f = RecipeResultFacts(report: .init(kind: .dedupe, outcome: .failed, receipt: .init(kind: .none, id: ""),
                                                summary: String(localized: "Nothing was changed on the server: \(why)"), reportedAt: Date()),
                                  outcome: .failed)
        f.source = review.accountDisplay
        f.requested = review.plan?.included.count
        f.completed = 0
        return f
    }

    nonisolated static func cleanupFacts(_ r: CleanupReceipt, saved: CleanupReceipt?, review: OnlineCleanupReview) -> RecipeResultFacts {
        let attempted = r.entries.filter { $0.operationID != nil }.count
        // The receipt as the journal holds it on disk (REC-05: read back, not assumed).
        let readBack = saved.map { $0.planID == r.planID && $0.selectionDigest == r.selectionDigest && $0.entries == r.entries } ?? false
        let allApplied = r.applied == attempted && attempted == (review.plan?.included.count ?? 0)
        var f = RecipeResultFacts(report: .init(kind: .dedupe, outcome: allApplied ? .succeeded : .partial,
                                                receipt: .init(kind: .measurement, id: r.planID.uuidString),
                                                summary: r.defaultText, count: r.applied, reportedAt: r.finishedAt),
                                  outcome: readBack ? (allApplied ? .succeeded : .partial) : .unverifiable)
        f.source = review.accountDisplay
        f.destination = r.action == .archiveOnServer ? String(localized: "the server's Archive (out of the Inbox)") : String(localized: "the server's Trash")
        f.requested = r.selected
        f.completed = r.applied
        var reasons: [String] = []
        for e in r.entries {
            let who = ((try? e.candidate.identity.key()) ?? "").replacingOccurrences(of: "\u{1F}", with: " · ")
            if let x = e.exclusion { reasons.append("\(who) — not changed: \(exclusionText(x))") }
            else if let o = e.outcome, o.name != "applied" { reasons.append("\(who) — \(o.name)") }
        }
        f.skipped = reasons
        let checked = r.entries.filter { $0.operationID != nil }
        let intact = checked.filter { $0.archiveCopyAfter?.isVerified ?? false }.count
        f.verification = "mailin's copies re-checked after the server change: \(intact) of \(checked.count) verify byte for byte"
            + (readBack ? "; receipt saved in the journal" : "; the receipt could not be read back")
        f.verificationPassed = r.archiveCopiesIntact && readBack
        return f
    }

    nonisolated static func exclusionText(_ e: CleanupExclusion) -> String {
        switch e {
        case .notCaptured: return String(localized: "Not saved in mailin yet")
        case .captureFailed(let why): return String(localized: "Saving it failed: \(why)")
        case .archiveRecordMismatch: return String(localized: "mailin's copy belongs to another account or message")
        case .archiveBytesMissing: return String(localized: "mailin's copy is missing its bytes")
        case .archiveBytesDamaged: return String(localized: "mailin's copy no longer matches its fingerprint")
        case .archiveUnreadable(let why): return String(localized: "mailin's copy could not be checked: \(why)")
        case .onHold(let why): return String(localized: "On hold: \(why)")
        case .noIndependentCopy: return String(localized: "No verified export or backup holds it")
        case .duplicateInSelection: return String(localized: "Selected twice")
        case .otherAccount: return String(localized: "Belongs to another account")
        case .unsupported(let why): return why
        }
    }

    nonisolated static func outcomeText(_ o: SyncOutcome) -> String {
        switch o {
        case .completed: return "completed"
        case .completedWithFailures(let n): return "completed, \(n) failed"
        case .paused(let why): return "paused (\(why))"
        case .needsSignIn: return "the account needs sign-in"
        case .notPermitted(let why): return "not permitted: \(why)"
        case .cancelled: return "cancelled"
        case .failed(let why): return "failed: \(why)"
        case .aborted: return "stopped"
        case .alreadyRunning: return "not started: a capture of this account was already running"
        }
    }

    private func finish(_ recipe: OnlineRecipeKind, started: Date, facts: [RecipeResultFacts], notes: [String] = []) -> OnlineRecipeResult {
        var result = OnlineRecipeResult(recipe: recipe, state: PracticalRecipeResult.state(of: facts), startedAt: started,
                                        finishedAt: Date(), facts: facts, notes: notes)
        do { try env.results.save(result) } catch {
            result.notes.append(String(localized: "This result could not be kept on disk: \(error.localizedDescription)"))
        }
        return result
    }
}

/// Holds a listing's cancel handler for the policy's cancellation registry.
final class ListingTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelHandler: (() -> Void)?
    private var cancelled = false

    func cancel() {
        let handler: (() -> Void)? = lock.withLock { cancelled = true; return cancelHandler }
        handler?()
    }

    func set(_ handler: @escaping () -> Void) {
        let wasCancelled: Bool = lock.withLock { cancelHandler = handler; return cancelled }
        if wasCancelled { handler() }
    }
}

// MARK: - 3. Capture rules (RQ09)

/// "When a new message matching `spec` is captured, add tag `tag`."
struct CaptureRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// Bumped when the conditions or the tag change: a new version evaluates afresh.
    var version = 1
    var spec: SearchSpec
    /// nil = every connected account.
    var accountID: UUID? = nil
    var tag: String
    var createdAt = Date()
    var isEnabled = true

    var ledgerKey: String { "\(id.uuidString)-v\(version)" }
}

/// What one evaluation pass did.
struct CaptureRuleRunSummary: Equatable, Sendable {
    /// rule ledger key → messages the rule fired for in this pass.
    var fired: [String: Int] = [:]
    /// Of those, messages whose own date is before the rule existed (a newly
    /// captured old message is still an arrival — counted, never dropped).
    var historical: [String: Int] = [:]
    var noMatch = 0
    /// Messages the conditions cannot decide yet (text not indexed): not
    /// recorded, evaluated again by the next pass.
    var undecided = 0
    /// Distinct (tag, message) pairs written in this pass — overlapping rules
    /// with the same tag write once.
    var tagWrites = 0
}

/// The per-rule totals the rules screen shows.
struct CaptureRuleTotals: Equatable, Sendable {
    var fired = 0
    var historical = 0
    var noMatch = 0
}

/// Evaluates the rules after capture + index. The ledger (one append-only
/// JSON-lines file per rule version) records every decision durably, so a
/// replayed event or a restart never fires a rule twice for a message.
actor CaptureRuleEngine {
    struct Decision: Codable, Equatable {
        enum Result: String, Codable { case fired, noMatch }
        var emailID: UUID
        var result: Result
        var historical: Bool
        var identityKey: String?
        var contentSHA256: String?
        var at: Date
    }

    typealias TagWriter = @Sendable (_ tag: String, _ ids: [UUID]) async throws -> Void

    private static let log = Logger(subsystem: "com.ecosanskriti.mailin", category: "CaptureRules")

    let directory: URL
    private let store: SQLiteEmailStore
    private let writeTag: TagWriter
    private var rules: [CaptureRule] = []
    private var ledgers: [String: [UUID: Decision]] = [:]
    private var loaded = false
    private(set) var lastError: String?

    init(directory: URL, store: SQLiteEmailStore, writeTag: @escaping TagWriter) {
        self.directory = directory; self.store = store; self.writeTag = writeTag
    }

    static func production(store: SQLiteEmailStore) -> CaptureRuleEngine {
        CaptureRuleEngine(directory: store.storeDirectory.appendingPathComponent("capture-rules", isDirectory: true), store: store,
                          writeTag: { tag, ids in try await store.userTagAdd(tag, ids: ids) })
    }

    private var rulesURL: URL { directory.appendingPathComponent("rules.json") }
    private func ledgerURL(_ key: String) -> URL { directory.appendingPathComponent("ledger-\(key).jsonl") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    // MARK: Rules

    func allRules() throws -> [CaptureRule] {
        try loadIfNeeded()
        return rules
    }

    /// Adds or replaces a rule (a changed spec / tag gets a new version).
    func save(_ rule: CaptureRule) throws {
        try loadIfNeeded()
        var rule = rule
        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            let old = rules[i]
            if old.spec != rule.spec || old.tag != rule.tag || old.accountID != rule.accountID { rule.version = old.version + 1 }
            rules[i] = rule
        } else {
            rules.append(rule)
        }
        try writeRules()
    }

    func remove(_ id: UUID) throws {
        try loadIfNeeded()
        rules.removeAll { $0.id == id }
        try writeRules()
    }

    func totals(_ rule: CaptureRule) throws -> CaptureRuleTotals {
        try loadIfNeeded()
        let ledger = ledgers[rule.ledgerKey] ?? [:]
        return CaptureRuleTotals(fired: ledger.values.filter { $0.result == .fired }.count,
                                 historical: ledger.values.filter { $0.result == .fired && $0.historical }.count,
                                 noMatch: ledger.values.filter { $0.result == .noMatch }.count)
    }

    private func writeRules() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rules).write(to: rulesURL, options: .atomic)
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: rulesURL.path) {
            rules = try Self.decoder.decode([CaptureRule].self, from: Data(contentsOf: rulesURL))
        }
        for rule in rules { ledgers[rule.ledgerKey] = try readLedger(rule.ledgerKey) }
        loaded = true
    }

    private func readLedger(_ key: String) throws -> [UUID: Decision] {
        let url = ledgerURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        var out: [UUID: Decision] = [:]
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n") where !line.isEmpty {
            // A line torn by a crash is ignored: that message is evaluated again.
            if let d = try? Self.decoder.decode(Decision.self, from: Data(line.utf8)), out[d.emailID] == nil { out[d.emailID] = d }
        }
        return out
    }

    /// Appends the decisions (fsync'd) before the pass reports them.
    private func append(_ decisions: [Decision], key: String) throws {
        guard !decisions.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = ledgerURL(key)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var data = Data()
        for d in decisions { data.append(try Self.encoder.encode(d)); data.append(0x0A) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        for d in decisions { ledgers[key, default: [:]][d.emailID] = d }
    }

    // MARK: Evaluation

    /// After a capture's records were indexed: each enabled rule decides
    /// each record once.
    func handleIndexed(_ ids: [UUID]) async -> CaptureRuleRunSummary {
        await evaluate(ids, onlyCapturedSinceRuleCreated: false)
    }

    /// Every connected record not yet decided by a rule and captured since
    /// that rule existed (launch, or after an indexing failure): the same
    /// once-only ledger applies, so this can run any number of times.
    func catchUp(batchSize: Int = 500) async -> CaptureRuleRunSummary {
        guard let rows = try? await store.remoteMessageDigests() else { return CaptureRuleRunSummary() }
        let ids = rows.compactMap { $0.emailID }
        var total = CaptureRuleRunSummary()
        var start = 0
        while start < ids.count {
            let end = min(ids.count, start + max(1, batchSize))
            let part = await evaluate(Array(ids[start..<end]), onlyCapturedSinceRuleCreated: true)
            total.merge(part)
            start = end
        }
        return total
    }

    private func evaluate(_ ids: [UUID], onlyCapturedSinceRuleCreated: Bool) async -> CaptureRuleRunSummary {
        var summary = CaptureRuleRunSummary()
        do { try loadIfNeeded() } catch { lastError = error.localizedDescription; return summary }
        let active = rules.filter(\.isEnabled)
        guard !active.isEmpty, !ids.isEmpty else { return summary }
        // Only captured (connected) records are arrivals.
        var provenance: [UUID: ConnectedProvenance] = [:]
        for id in Set(ids) { if let p = try? await store.connectedProvenance(emailID: id) { provenance[id] = p } }
        let dates: [UUID: Date]
        do {
            dates = Dictionary(try await store.summaries(ids: Array(provenance.keys)).map { ($0.id, $0.date) }, uniquingKeysWith: { a, _ in a })
        } catch {
            lastError = error.localizedDescription
            return summary
        }
        // Tags written in this pass or already written by another rule's ledger.
        var writtenNow: [String: Set<UUID>] = [:]
        for rule in active {
            let key = rule.ledgerKey
            let ledger = ledgers[key] ?? [:]
            let created = Date(timeIntervalSince1970: rule.createdAt.timeIntervalSince1970.rounded(.down))
            let candidates = provenance.values.filter { p in
                ledger[p.emailID] == nil
                    && (rule.accountID == nil || rule.accountID == p.accountID)
                    && (!onlyCapturedSinceRuleCreated || p.firstCapturedAt >= created)
            }.map(\.emailID).sorted { $0.uuidString < $1.uuidString }
            guard !candidates.isEmpty else { continue }
            var query = EmailQuery.all
            query.spec = rule.spec.isEmpty ? nil : rule.spec
            query.includeTrashed = true
            do {
                let matched = try await store.matchingIDs(among: candidates, query: query)
                let rest = candidates.filter { !matched.contains($0) }
                let undecided = try await store.specUnresolvedIDs(among: rest, query: query)
                // The tag first (idempotent write), then the ledger: a crash in
                // between re-writes the same tag once, never a second decision.
                let alreadyTagged = taggedElsewhere(rule.tag, excluding: key).union(writtenNow[rule.tag] ?? [])
                let toWrite = candidates.filter { matched.contains($0) && !alreadyTagged.contains($0) }
                if !toWrite.isEmpty {
                    try await writeTag(rule.tag, toWrite)
                    summary.tagWrites += toWrite.count
                    writtenNow[rule.tag, default: []].formUnion(toWrite)
                }
                let now = Date()
                var decisions: [Decision] = []
                for id in candidates where !undecided.contains(id) {
                    let p = provenance[id]
                    let fired = matched.contains(id)
                    let historical = fired && (dates[id].map { $0 < rule.createdAt } ?? false)
                    decisions.append(Decision(emailID: id, result: fired ? .fired : .noMatch, historical: historical,
                                              identityKey: p?.identityKey, contentSHA256: p?.sha256, at: now))
                }
                try append(decisions, key: key)
                let firedCount = decisions.filter { $0.result == .fired }.count
                if firedCount > 0 { summary.fired[key, default: 0] += firedCount }
                let hist = decisions.filter(\.historical).count
                if hist > 0 { summary.historical[key, default: 0] += hist }
                summary.noMatch += decisions.filter { $0.result == .noMatch }.count
                summary.undecided += undecided.count
            } catch {
                lastError = error.localizedDescription
                Self.log.error("capture rule \(rule.name, privacy: .public) not evaluated: \(error.localizedDescription, privacy: .public)")
            }
        }
        return summary
    }

    /// Messages another rule with the same tag already fired for (its tag is written).
    private func taggedElsewhere(_ tag: String, excluding key: String) -> Set<UUID> {
        var out = Set<UUID>()
        for rule in rules where rule.tag == tag && rule.ledgerKey != key {
            for (id, d) in ledgers[rule.ledgerKey] ?? [:] where d.result == .fired { out.insert(id) }
        }
        return out
    }
}

extension CaptureRuleRunSummary {
    mutating func merge(_ other: CaptureRuleRunSummary) {
        for (k, v) in other.fired { fired[k, default: 0] += v }
        for (k, v) in other.historical { historical[k, default: 0] += v }
        noMatch += other.noMatch
        undecided += other.undecided
        tagWrites += other.tagWrites
    }
}
