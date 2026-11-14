//
//  SafeCleanup.swift
//  MailConnectivity
//
//  Plan v4 V4-11 (§6 "Server actions and safe cleanup", T43, RQ10): bulk
//  removal of mail from the SERVER, as its own workflow:
//
//    1. frozen selection   — the exact provider identities, digested
//    2. archive check      — each one captured, its bytes present and their
//                            SHA-256 equal to the capture's (rehashed now)
//    3. optional backup    — an independent verified export / backup holds it
//    4. exclusions         — not captured, capture failed, bytes missing or
//                            damaged, on hold, no independent copy … each
//                            with its reason; never silently dropped
//    5. preview            — exact remote effect with counts (rule 4)
//    6. confirmation       — must name this plan, its digest and its count
//    7. per-item execution — one journalled `RemoteOperation` each, re-checked
//                            just before it is sent
//    8. receipt            — per item: outcome, and the archive copy checked
//                            again AFTER the remote change ("X of Y")
//
//  Remote removal never removes the archived copy: nothing here writes to
//  the archive, and the receipt proves the copy still verifies.
//

import ArchiveCore
import CryptoKit
import Foundation

// MARK: - Inputs

/// One message the user selected for server cleanup.
public struct CleanupCandidate: Codable, Sendable, Equatable, Hashable {
    public var accountID: UUID
    public var identity: ProviderMessageIdentity
    /// The archive record (nil = never captured).
    public var emailID: UUID?
    /// Where it is on the server now (Gmail label, Graph folder id or name, IMAP mailbox).
    public var folder: String

    public init(accountID: UUID, identity: ProviderMessageIdentity, emailID: UUID?, folder: String) {
        self.accountID = accountID; self.identity = identity; self.emailID = emailID; self.folder = folder
    }

    var sortKey: String { ((try? identity.key()) ?? "\(identity)") + "\u{1F}" + folder }
}

public enum CleanupAction: String, Codable, Sendable, CaseIterable {
    /// Move to the provider's Trash / Deleted Items.
    case moveToTrash
    /// Gmail's server Archive (out of the Inbox). Gmail accounts only.
    case archiveOnServer

    func request(for c: CleanupCandidate) -> RemoteChangeRequest {
        switch self {
        case .moveToTrash: return .moveToTrash(from: c.folder)
        case .archiveOnServer: return .archiveOnServer
        }
    }
}

/// What the archive says about the preserved copy of one message.
public enum ArchivedCopyStatus: Codable, Sendable, Equatable {
    case verified(sha256: String, byteCount: Int64)
    case notCaptured
    /// The archive record belongs to another account / provider identity.
    case recordMismatch
    case bytesMissing
    case hashMismatch(expected: String, actual: String)
    case unreadable(String)

    public var isVerified: Bool { if case .verified = self { return true }; return false }
}

public protocol ArchivedCopyVerifier: Sendable {
    func verify(emailID: UUID, accountID: UUID, identity: ProviderMessageIdentity) async -> ArchivedCopyStatus
}

/// Rehashes the preserved bytes of `emailID` (streamed by the app's blob
/// reader); nil when the bytes are absent.
public typealias ArchivedBytesHasher = @Sendable (_ emailID: UUID, _ provenance: ConnectedProvenance) async throws -> (sha256: String, byteCount: Int64)?

/// The archive verifier over the public ingestion boundary: provenance from
/// `ConnectedArchiveSink`, bytes rehashed by the injected hasher.
public struct ConnectedArchiveCopyVerifier: ArchivedCopyVerifier {
    let sink: ConnectedArchiveSink
    let rehash: ArchivedBytesHasher

    public init(sink: ConnectedArchiveSink, rehash: @escaping ArchivedBytesHasher) { self.sink = sink; self.rehash = rehash }

    public func verify(emailID: UUID, accountID: UUID, identity: ProviderMessageIdentity) async -> ArchivedCopyStatus {
        let provenance: ConnectedProvenance?
        do { provenance = try await sink.provenance(emailID: emailID) } catch { return .unreadable(error.localizedDescription) }
        guard let p = provenance else { return .notCaptured }
        guard p.accountID == accountID, let key = try? identity.key(), p.identityKey == key else { return .recordMismatch }
        do {
            guard let actual = try await rehash(emailID, p) else { return .bytesMissing }
            guard actual.sha256 == p.sha256, actual.byteCount == p.byteCount else {
                return .hashMismatch(expected: p.sha256, actual: actual.sha256)
            }
            return .verified(sha256: p.sha256, byteCount: p.byteCount)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }
}

/// The checks every candidate must pass, supplied by the app.
public struct CleanupSafetyChecks: Sendable {
    public var archive: any ArchivedCopyVerifier
    /// A reason when the message is under a hold (legal / retention / user).
    public var hold: @Sendable (_ emailID: UUID?, _ identity: ProviderMessageIdentity) async -> String?
    /// A reason when the message's capture failed or is pending.
    public var captureFailure: @Sendable (_ identity: ProviderMessageIdentity) async -> String?
    /// nil = no independent copy required; otherwise true when a verified
    /// export / backup outside this archive holds the message.
    public var independentCopy: (@Sendable (_ emailID: UUID) async -> Bool)?

    public init(archive: any ArchivedCopyVerifier,
                hold: @escaping @Sendable (UUID?, ProviderMessageIdentity) async -> String? = { _, _ in nil },
                captureFailure: @escaping @Sendable (ProviderMessageIdentity) async -> String? = { _ in nil },
                independentCopy: (@Sendable (UUID) async -> Bool)? = nil) {
        self.archive = archive; self.hold = hold; self.captureFailure = captureFailure; self.independentCopy = independentCopy
    }
}

// MARK: - Plan

public enum CleanupExclusion: Codable, Sendable, Equatable {
    case notCaptured
    case captureFailed(String)
    case archiveRecordMismatch
    case archiveBytesMissing
    case archiveBytesDamaged(expected: String, actual: String)
    case archiveUnreadable(String)
    case onHold(String)
    case noIndependentCopy
    case duplicateInSelection
    case otherAccount
    case unsupported(String)

    /// Stable key for "excluded by reason" counts.
    public var key: String {
        switch self {
        case .notCaptured: return "notCaptured"
        case .captureFailed: return "captureFailed"
        case .archiveRecordMismatch: return "archiveRecordMismatch"
        case .archiveBytesMissing: return "archiveBytesMissing"
        case .archiveBytesDamaged: return "archiveBytesDamaged"
        case .archiveUnreadable: return "archiveUnreadable"
        case .onHold: return "onHold"
        case .noIndependentCopy: return "noIndependentCopy"
        case .duplicateInSelection: return "duplicateInSelection"
        case .otherAccount: return "otherAccount"
        case .unsupported: return "unsupported"
        }
    }

    public var defaultText: String {
        switch self {
        case .notCaptured: return "Not saved in the archive yet"
        case .captureFailed(let why): return "Saving it failed: \(why)"
        case .archiveRecordMismatch: return "The archive copy belongs to another account or message"
        case .archiveBytesMissing: return "The archive copy's bytes are missing"
        case .archiveBytesDamaged: return "The archive copy no longer matches its saved fingerprint"
        case .archiveUnreadable(let why): return "The archive copy could not be checked: \(why)"
        case .onHold(let why): return "On hold: \(why)"
        case .noIndependentCopy: return "No verified export or backup holds it"
        case .duplicateInSelection: return "Selected twice"
        case .otherAccount: return "Belongs to another account"
        case .unsupported(let why): return why
        }
    }

    static func from(_ status: ArchivedCopyStatus) -> CleanupExclusion? {
        switch status {
        case .verified: return nil
        case .notCaptured: return .notCaptured
        case .recordMismatch: return .archiveRecordMismatch
        case .bytesMissing: return .archiveBytesMissing
        case .hashMismatch(let e, let a): return .archiveBytesDamaged(expected: e, actual: a)
        case .unreadable(let why): return .archiveUnreadable(why)
        }
    }
}

public struct CleanupPreview: Codable, Sendable, Equatable {
    public var selected: Int
    /// Messages that WILL be changed on the server after confirmation.
    public var toChange: Int
    public var excluded: Int
    public var excludedByReason: [String: Int]
    public var action: CleanupAction
    public var accountDisplay: String
    /// Always true: the archive's copies are not changed by a server cleanup.
    public var archiveCopiesKept: Bool

    public var defaultText: String {
        let verb = action == .moveToTrash ? "moved to Trash" : "archived (removed from the Inbox)"
        return "\(toChange) of \(selected) messages will be \(verb) on \(accountDisplay); \(excluded) will not be changed. "
            + "The copies saved in mailin are kept."
    }
}

public struct CleanupPlan: Codable, Sendable, Equatable {
    public struct Included: Codable, Sendable, Equatable {
        public var candidate: CleanupCandidate
        public var request: RemoteChangeRequest
        public var archivedSHA256: String
        public var archivedByteCount: Int64
    }
    public struct Excluded: Codable, Sendable, Equatable {
        public var candidate: CleanupCandidate
        public var reason: CleanupExclusion
    }

    public var planID: UUID
    public var accountID: UUID
    public var action: CleanupAction
    public var createdAt: Date
    /// The frozen selection, in a stable order.
    public var selection: [CleanupCandidate]
    /// SHA-256 of (account, action, selection): what the confirmation must name.
    public var selectionDigest: String
    public var included: [Included]
    public var excluded: [Excluded]
    public var preview: CleanupPreview

    /// What the UI hands back after the user confirmed THIS preview.
    public func confirmation() -> CleanupConfirmation {
        CleanupConfirmation(planID: planID, selectionDigest: selectionDigest, confirmedCount: included.count)
    }
}

public struct CleanupConfirmation: Codable, Sendable, Equatable {
    public var planID: UUID
    public var selectionDigest: String
    /// The "N messages" count the user saw.
    public var confirmedCount: Int
    public init(planID: UUID, selectionDigest: String, confirmedCount: Int) {
        self.planID = planID; self.selectionDigest = selectionDigest; self.confirmedCount = confirmedCount
    }
}

public struct CleanupReceipt: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var candidate: CleanupCandidate
        public var operationID: UUID?
        public var outcome: RemoteOperationOutcome?
        /// Set when the item was excluded at planning or at the last check before sending.
        public var exclusion: CleanupExclusion?
        /// The archive copy, re-checked AFTER the remote change.
        public var archiveCopyAfter: ArchivedCopyStatus?
    }
    public var planID: UUID
    public var accountID: UUID
    public var action: CleanupAction
    public var selectionDigest: String
    public var startedAt: Date
    public var finishedAt: Date
    public var entries: [Entry]

    public var selected: Int { entries.count }
    public var applied: Int { entries.filter { if case .applied = $0.outcome { return true }; return false }.count }
    public var conflicts: Int { entries.filter { $0.outcome?.name == "conflict" }.count }
    public var uncertain: Int { entries.filter { $0.outcome?.name == "uncertain" }.count }
    public var rejected: Int { entries.filter { $0.outcome?.name == "rejected" }.count }
    public var excluded: Int { entries.filter { $0.exclusion != nil }.count }
    /// Every archive copy of an attempted item still verifies.
    public var archiveCopiesIntact: Bool {
        entries.allSatisfy { $0.operationID == nil || ($0.archiveCopyAfter?.isVerified ?? false) }
    }

    /// "X of Y" (rule 5).
    public var defaultText: String {
        "\(applied) of \(selected) changed on the server; \(conflicts) changed elsewhere first, \(uncertain) uncertain, "
            + "\(rejected) refused, \(excluded) not attempted. Copies saved in mailin: "
            + (archiveCopiesIntact ? "all intact." : "check the archive health report.")
    }
}

public enum CleanupError: LocalizedError, Equatable {
    case confirmationMismatch
    case accountMismatch

    public var errorDescription: String? {
        switch self {
        case .confirmationMismatch: return "The confirmation does not match this cleanup preview; nothing was changed. Review the preview again."
        case .accountMismatch: return "The cleanup belongs to a different account; nothing was changed."
        }
    }
}

// MARK: - Workflow

public enum SafeCleanup {
    /// Steps 1–5: freezes the selection, checks every item, previews the effect.
    /// Reads the archive only; sends nothing.
    public static func plan(_ selection: [CleanupCandidate], action: CleanupAction, account: MailAccount,
                            checks: CleanupSafetyChecks, now: Date = Date()) async -> CleanupPlan {
        let frozen = selection.sorted { $0.sortKey < $1.sortKey }
        var included: [CleanupPlan.Included] = []
        var excluded: [CleanupPlan.Excluded] = []
        var seen = Set<String>()
        for c in frozen {
            if let reason = await exclusion(for: c, action: action, account: account, checks: checks, seen: &seen) {
                excluded.append(.init(candidate: c, reason: reason))
            } else if case .verified(let sha, let size)? = await currentStatus(c, checks) {
                included.append(.init(candidate: c, request: action.request(for: c), archivedSHA256: sha, archivedByteCount: size))
            } else {
                excluded.append(.init(candidate: c, reason: .archiveUnreadable("the archive copy changed while it was checked")))
            }
        }
        var byReason: [String: Int] = [:]
        for e in excluded { byReason[e.reason.key, default: 0] += 1 }
        let preview = CleanupPreview(selected: frozen.count, toChange: included.count, excluded: excluded.count,
                                     excludedByReason: byReason, action: action, accountDisplay: account.displayIdentity,
                                     archiveCopiesKept: true)
        return CleanupPlan(planID: UUID(), accountID: account.id, action: action, createdAt: now, selection: frozen,
                           selectionDigest: digest(frozen, action: action, account: account.id),
                           included: included, excluded: excluded, preview: preview)
    }

    /// Steps 6–8: only with a confirmation naming this plan, its digest and
    /// its count. Each item is re-checked just before its request; resuming
    /// an interrupted cleanup reuses its journalled operations (no item is
    /// changed twice). Throws only before anything is sent, or when the
    /// journal cannot be written.
    public static func execute(_ plan: CleanupPlan, confirmation: CleanupConfirmation, service: RemoteActionService,
                               checks: CleanupSafetyChecks, now: @Sendable () -> Date = { Date() }) async throws -> CleanupReceipt {
        guard confirmation.planID == plan.planID, confirmation.selectionDigest == plan.selectionDigest,
              confirmation.confirmedCount == plan.included.count,
              plan.selectionDigest == digest(plan.selection, action: plan.action, account: plan.accountID) else {
            throw CleanupError.confirmationMismatch
        }
        let account = service.account
        guard account.id == plan.accountID else { throw CleanupError.accountMismatch }
        let started = now()

        // Operations an interrupted run already journalled for this plan.
        var existing: [String: RemoteOperation] = [:]
        for op in await service.journal.all().operations where op.planID == plan.planID {
            existing[(try? op.identity.key()) ?? ""] = op
        }

        var entries: [CleanupReceipt.Entry] = plan.excluded.map { .init(candidate: $0.candidate, exclusion: $0.reason) }
        for item in plan.included {
            let c = item.candidate
            let key = (try? c.identity.key()) ?? ""
            var op = existing[key]
            if op == nil {
                // Last check before sending: still captured, unchanged, not held.
                var seen = Set<String>()
                if let reason = await exclusion(for: c, action: plan.action, account: account, checks: checks, seen: &seen) {
                    entries.append(.init(candidate: c, exclusion: reason)); continue
                }
                guard case .verified(let sha, _)? = await currentStatus(c, checks), sha == item.archivedSHA256 else {
                    entries.append(.init(candidate: c, exclusion: .archiveBytesDamaged(expected: item.archivedSHA256, actual: "changed since the preview")))
                    continue
                }
                op = try await service.enqueue(c.identity, item.request, emailID: c.emailID, planID: plan.planID)
            }
            let done = try await service.execute(op!.id)
            let after = await currentStatus(c, checks)
            entries.append(.init(candidate: c, operationID: done.id, outcome: done.outcome, archiveCopyAfter: after))
        }
        let order = Dictionary(plan.selection.enumerated().map { ($0.element.sortKey, $0.offset) }, uniquingKeysWith: { a, _ in a })
        entries.sort { (order[$0.candidate.sortKey] ?? 0) < (order[$1.candidate.sortKey] ?? 0) }
        let receipt = CleanupReceipt(planID: plan.planID, accountID: plan.accountID, action: plan.action,
                                     selectionDigest: plan.selectionDigest, startedAt: started, finishedAt: now(), entries: entries)
        try await service.journal.saveReceipt(receipt)
        return receipt
    }

    // MARK: Checks

    private static func currentStatus(_ c: CleanupCandidate, _ checks: CleanupSafetyChecks) async -> ArchivedCopyStatus? {
        guard let emailID = c.emailID else { return .notCaptured }
        return await checks.archive.verify(emailID: emailID, accountID: c.accountID, identity: c.identity)
    }

    /// The reason `c` must not be changed, or nil.
    private static func exclusion(for c: CleanupCandidate, action: CleanupAction, account: MailAccount,
                                  checks: CleanupSafetyChecks, seen: inout Set<String>) async -> CleanupExclusion? {
        guard c.accountID == account.id, c.identity.provider == account.provider else { return .otherAccount }
        guard seen.insert((try? c.identity.key()) ?? c.sortKey).inserted else { return .duplicateInSelection }
        if action == .archiveOnServer, account.provider != .gmail {
            return .unsupported("Server Archive is a Gmail action; move the message to an Archive folder instead.")
        }
        if let why = await checks.captureFailure(c.identity) { return .captureFailed(why) }
        guard let emailID = c.emailID else { return .notCaptured }
        let status = await checks.archive.verify(emailID: emailID, accountID: c.accountID, identity: c.identity)
        if let reason = CleanupExclusion.from(status) { return reason }
        if let why = await checks.hold(emailID, c.identity) { return .onHold(why) }
        if let independent = checks.independentCopy, !(await independent(emailID)) { return .noIndependentCopy }
        return nil
    }

    static func digest(_ selection: [CleanupCandidate], action: CleanupAction, account: UUID) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("mailin-cleanup-v1\u{1F}\(account.uuidString)\u{1F}\(action.rawValue)".utf8))
        for c in selection {
            hasher.update(data: Data("\u{1E}\(c.sortKey)\u{1F}\(c.emailID?.uuidString ?? "-")\u{1F}\(c.accountID.uuidString)".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
