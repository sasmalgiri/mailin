//
//  Outbox.swift
//  MailConnectivity
//
//  Plan v4 V4-10 (§6 "Outbox and transport"): runs the durable outbox.
//
//   • `enqueue` freezes a composed message once (Bcc absent from its header,
//     CRLF canonical) with an optional Undo Send delay, persisted.
//   • `runDue` submits what is due, ONE submission per operation at a time;
//     the record says `submitting` on disk before any connection is made and
//     `mayHaveReachedProvider` before the final step.
//   • `recoverAfterRestart` turns an interrupted `submitting` into a safe
//     retry (the provider cannot have it) or `outcomeUncertain` (it may) —
//     never an automatic resend.
//   • `cancel` is Undo Send: it works only before submission and makes no
//     recall promise afterwards.
//   • `reconcile` checks the provider's Sent by Message-ID; only then may the
//     user explicitly `resendAfterUncertainty`.
//   • The SMTP Sent copy (IMAP APPEND) is a separate step; its failure leaves
//     the message `accepted` and is retried as an append, never a resend.
//

import Foundation

public actor Outbox {
    struct Route: Sendable {
        var submitter: any MessageSubmitter
        var appender: (any SentFolderAppender)?
        var lookup: (any SentMessageLookup)?
    }

    let store: OutboxStore
    let permission: NetworkPermission
    let now: @Sendable () -> Date
    /// Delay before an automatic retry when the provider gave none.
    let defaultRetryDelay: TimeInterval

    private var routes: [UUID: Route] = [:]
    private var cache: [UUID: OutboxOperation] = [:]
    private var loaded = false
    /// Records whose latest state is in memory only (the disk refused the write).
    private var unsaved: Set<UUID> = []
    private var inFlight: Set<UUID> = []
    /// V4-12: decides, per due operation, whether it may be submitted now
    /// (subscription lapse, restored or stale items awaiting the user's
    /// decision, removed account, missing archive drive). nil = always.
    private var admission: OutboxAdmission?
    /// Why each due operation was held at the last `runDue` (shown, never hidden).
    private var held: [UUID: OutboxHoldReason] = [:]

    /// V4-12: install the lifecycle admission check (`ConnectedLifecycle.outboxAdmission`).
    public func setAdmission(_ check: OutboxAdmission?) { admission = check }

    /// Due operations the admission check held at the last `runDue`, with the reason.
    public func heldOperations() -> [UUID: OutboxHoldReason] { held }

    public init(store: OutboxStore, permission: @escaping NetworkPermission, defaultRetryDelay: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.permission = permission; self.defaultRetryDelay = defaultRetryDelay; self.now = now
    }

    /// The send route of one account: its submitter, and for generic SMTP the
    /// Sent appender; the Sent lookup used to reconcile uncertain outcomes.
    public func register(account: UUID, submitter: any MessageSubmitter, appender: (any SentFolderAppender)? = nil,
                         lookup: (any SentMessageLookup)? = nil) {
        routes[account] = Route(submitter: submitter, appender: appender, lookup: lookup)
    }

    // MARK: Reading

    public func operation(_ id: UUID) async throws -> OutboxOperation {
        try await loadIfNeeded()
        guard let op = cache[id] else { throw OutboxError.notFound(id) }
        return op
    }

    public func operations() async throws -> [OutboxOperation] {
        try await loadIfNeeded()
        return cache.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// V4-12: the frozen message bytes of an operation (verified), so a held,
    /// cancelled or restored item's contents can always be shown or saved.
    public func frozenMessage(_ id: UUID) async throws -> Data {
        try await store.message(for: try await operation(id))
    }

    /// Whether the record on disk is behind the state shown (the disk refused a write).
    public func hasUnsavedState(_ id: UUID) -> Bool { unsaved.contains(id) }

    private func loadIfNeeded() async throws {
        guard !loaded else { return }
        let listing = await store.all()
        for op in listing.operations { cache[op.id] = op }
        loaded = true
        try await recoverInterrupted()
    }

    /// After a restart: a `submitting` record means the process stopped mid-send.
    private func recoverInterrupted() async throws {
        for var op in cache.values where op.state == .submitting {
            switch op.phase {
            case .notSubmitted:
                try op.move(to: .retryWaiting(reason: "mailin stopped before the message was handed over", notBefore: now(),
                                              quota: false, automatic: true), at: now(), note: "recovered after restart")
            case .mayHaveReachedProvider:
                try op.move(to: .outcomeUncertain(reason: "mailin stopped before the provider replied", reconciliation: .notChecked),
                            at: now(), note: "recovered after restart")
            }
            await persist(op)
        }
    }

    /// Call at launch; returns every operation after interrupted sends were resolved.
    @discardableResult
    public func recoverAfterRestart() async throws -> [OutboxOperation] { try await operations() }

    // MARK: Enqueue and Undo Send

    /// Freezes `composed` (made from `draft` at its current revision) for sending.
    /// `undoDelay` > 0: nothing is submitted before now + undoDelay.
    public func enqueue(_ composed: ComposedMessage, draft: Draft, route: OutboxRoute, undoDelay: TimeInterval = 0) async throws -> OutboxOperation {
        try await loadIfNeeded()
        guard composed.draftID == draft.id, composed.draftRevision == draft.revision, composed.accountID == draft.accountID else {
            throw OutboxError.composedForAnotherDraft
        }
        if cache.values.contains(where: { $0.draftID == draft.id && $0.draftRevision == draft.revision
            && $0.state != .draft && !Self.isCancelled($0.state) }) {
            throw OutboxError.alreadyQueued(draft.id)
        }
        try Self.checkCanonical(composed.bytes)
        let bcc = try Self.bccHeader(for: draft, utf8: composed.requiresSMTPUTF8)
        let created = now()
        var op = OutboxOperation(id: UUID(), composed: composed, apiBccHeader: bcc, route: route, createdAt: created,
                                 notBefore: undoDelay > 0 ? created.addingTimeInterval(undoDelay) : nil)
        try op.move(to: .queued, at: created, note: undoDelay > 0 ? "undo send until \(created.addingTimeInterval(undoDelay))" : nil)
        try await store.create(op, message: composed.bytes)
        cache[op.id] = op
        return op
    }

    /// Undo Send / cancel: only before submission. Afterwards there is no recall.
    @discardableResult
    public func cancel(_ id: UUID, note: String = "cancelled by the user") async throws -> OutboxOperation {
        var op = try await operation(id)
        if op.state.isPastSubmission || inFlight.contains(id) {
            throw OutboxError.cannotCancelAfterSubmission(state: op.state.name)
        }
        try op.move(to: .cancelledBeforeSubmission(at: now()), at: now(), note: note)
        held[id] = nil
        try await store.save(op)          // a cancel that is not durable did not happen
        cache[id] = op
        unsaved.remove(id)
        return op
    }

    // MARK: Submitting

    /// Submits every operation that is due, one at a time. Returns those it touched.
    @discardableResult
    public func runDue() async throws -> [OutboxOperation] {
        try await loadIfNeeded()
        await flushUnsaved()
        var touched: [OutboxOperation] = []
        var stillHeld: [UUID: OutboxHoldReason] = [:]
        for op in try await operations() where isDue(op) {
            if let admission, case .hold(let why) = await admission(op, now()) {
                stillHeld[op.id] = why
                continue
            }
            if let result = try await submit(op.id) { touched.append(result) }
        }
        held = stillHeld
        return touched
    }

    func isDue(_ op: OutboxOperation) -> Bool {
        let t = now()
        switch op.state {
        case .queued: return (op.notBefore ?? .distantPast) <= t
        case .retryWaiting(_, let notBefore, _, let automatic): return automatic && notBefore <= t && (op.notBefore ?? .distantPast) <= t
        default: return false
        }
    }

    /// One submission. Nil when the operation was busy or not due.
    private func submit(_ id: UUID) async throws -> OutboxOperation? {
        guard !inFlight.contains(id), var op = cache[id], isDue(op) else { return nil }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        if case .retryWaiting = op.state { try op.move(to: .queued, at: now(), note: "retry") }
        guard let route = routes[op.accountID] else {
            try op.move(to: .retryWaiting(reason: "this account is not set up for sending", notBefore: now(), quota: false, automatic: false), at: now())
            await persist(op)
            return op
        }
        let stored: Data
        do { stored = try await store.message(for: op) } catch {
            try op.move(to: .rejected(reason: "the stored copy of the prepared message is damaged", rejectedRecipients: []), at: now())
            await persist(op)
            return op
        }
        // Durable BEFORE any connection: a kill from here on is recovered, not resent blindly.
        op.phase = .notSubmitted
        op.submissionAttempts += 1
        try op.move(to: .submitting, at: now(), note: "attempt \(op.submissionAttempts)")
        do { try await store.save(op) } catch {
            // Not durable: do not connect. The record still says queued.
            return cache[id]
        }
        cache[id] = op
        unsaved.remove(id)

        let message = OutboundMessage(operationID: op.id, accountID: op.accountID, messageID: op.messageID, envelopeFrom: op.envelopeFrom,
                                      envelopeRecipients: op.envelopeRecipients, requiresSMTPUTF8: op.requiresSMTPUTF8,
                                      bytes: op.submissionBytes(stored: stored))
        let outcome = await route.submitter.submit(message) { [self] phase in try await self.checkpoint(id, phase) }
        op = cache[id] ?? op
        let t = now()
        switch outcome {
        case .accepted(let response, let reference, let savedToSent):
            op.providerReference = reference ?? Self.firstLine(response)
            try op.move(to: .accepted(at: t, response: response), at: t)
            if savedToSent { try op.move(to: .sentReconciled(at: t, how: .providerResponse), at: t) }
        case .rejected(let reason, let recipients):
            try op.move(to: .rejected(reason: reason, rejectedRecipients: recipients), at: t)
        case .retry(let reason, let after, let quota, let automatic):
            try op.move(to: .retryWaiting(reason: reason, notBefore: t.addingTimeInterval(after ?? defaultRetryDelay), quota: quota,
                                          automatic: automatic), at: t)
        case .needsSignIn(let reason):
            try op.move(to: .needsSignIn(reason: reason), at: t)
        case .uncertain(let reason):
            // A submitter that never reached its checkpoint cannot be uncertain.
            if op.phase == .notSubmitted {
                try op.move(to: .retryWaiting(reason: reason, notBefore: t.addingTimeInterval(defaultRetryDelay), quota: false, automatic: true), at: t)
            } else {
                try op.move(to: .outcomeUncertain(reason: reason, reconciliation: .notChecked), at: t)
            }
        }
        await persist(op)
        if case .accepted = op.state, op.sentCopy == .appendPending, let appender = route.appender {
            op = await appendSentCopy(op, appender: appender, lookup: nil)
        }
        return op
    }

    private func checkpoint(_ id: UUID, _ phase: SubmissionPhase) async throws {
        guard var op = cache[id] else { throw OutboxError.notFound(id) }
        op.phase = phase
        try await store.save(op)     // throws → the submitter does not take the final step
        cache[id] = op
    }

    // MARK: Sent copy (generic SMTP)

    /// Retries a failed Sent APPEND. Appends only — never resubmits the message.
    @discardableResult
    public func retrySentCopy(_ id: UUID) async throws -> OutboxOperation {
        let op = try await operation(id)
        guard case .accepted = op.state else { return op }
        switch op.sentCopy {
        case .appendPending, .appendFailed: break
        default: return op
        }
        guard let route = routes[op.accountID], let appender = route.appender else { return op }
        return await appendSentCopy(op, appender: appender, lookup: route.lookup)
    }

    private func appendSentCopy(_ start: OutboxOperation, appender: any SentFolderAppender, lookup: (any SentMessageLookup)?) async -> OutboxOperation {
        var op = start
        do {
            // A failed append may still have landed: look first, so Sent holds ONE copy.
            if case .appendFailed = op.sentCopy, let lookup {
                try permission(NetworkAsk(accountID: op.accountID, host: lookup.host, destination: .mailServer, operation: .request))
                if case .found = try await lookup.findSent(messageID: op.messageID, accountID: op.accountID) {
                    op.sentCopy = .appended
                    try op.move(to: .sentReconciled(at: now(), how: .foundInSent), at: now())
                    await persist(op)
                    return op
                }
            }
            try permission(NetworkAsk(accountID: op.accountID, host: appender.host, destination: .mailServer, operation: .request))
            let stored = try await store.message(for: op)
            try await appender.appendToSent(stored, messageID: op.messageID, accountID: op.accountID)
            op.sentCopy = .appended
            try op.move(to: .sentReconciled(at: now(), how: .appendedToSent), at: now())
        } catch {
            op.sentCopy = .appendFailed(error.localizedDescription)
        }
        await persist(op)
        return op
    }

    // MARK: Reconciliation and explicit resend

    /// Checks the provider's Sent by Message-ID. Uncertain → sentReconciled when
    /// found; otherwise the finding is recorded and the user may choose to resend.
    /// Accepted (Graph 202, SMTP 250) → sentReconciled when found.
    @discardableResult
    public func reconcile(_ id: UUID) async throws -> OutboxOperation {
        var op = try await operation(id)
        let uncertain: String?
        switch op.state {
        case .outcomeUncertain(let reason, _): uncertain = reason
        case .accepted: uncertain = nil
        default: return op
        }
        guard let lookup = routes[op.accountID]?.lookup else {
            if let uncertain {
                try op.move(to: .outcomeUncertain(reason: uncertain, reconciliation: .lookupFailed("this account cannot search its Sent folder")), at: now())
                await persist(op)
            }
            return op
        }
        let result: SentLookupResult
        do {
            try permission(NetworkAsk(accountID: op.accountID, host: lookup.host, destination: .mailServer, operation: .request))
            result = try await lookup.findSent(messageID: op.messageID, accountID: op.accountID)
        } catch {
            if let uncertain {
                try op.move(to: .outcomeUncertain(reason: uncertain, reconciliation: .lookupFailed(error.localizedDescription)), at: now())
                await persist(op)
            }
            return op
        }
        switch result {
        case .found(let reference):
            if let reference { op.providerReference = reference }
            // Found in Sent: the provider (or an earlier append) already filed it — never append another.
            if op.sentCopy == .appendPending || Self.isAppendFailed(op.sentCopy) { op.sentCopy = .appended }
            try op.move(to: .sentReconciled(at: now(), how: .foundInSent), at: now(), note: "found by Message-ID")
        case .notFound:
            guard let uncertain else { return op }      // accepted stays accepted: Sent may lag
            try op.move(to: .outcomeUncertain(reason: uncertain, reconciliation: .notFound(checkedAt: now())), at: now())
        }
        await persist(op)
        return op
    }

    /// The user's explicit choice to send an uncertain message again (the
    /// provider's Sent was checked, or could not be). Same Message-ID, same bytes.
    @discardableResult
    public func resendAfterUncertainty(_ id: UUID) async throws -> OutboxOperation {
        var op = try await operation(id)
        guard case .outcomeUncertain(_, let reconciliation) = op.state else { throw OutboxError.notResendable(state: op.state.name) }
        guard reconciliation != .notChecked else { throw OutboxError.resendNeedsReconciliation }
        op.userResends += 1
        op.phase = .notSubmitted
        op.notBefore = nil
        try op.move(to: .queued, at: now(), note: "the user chose to send again")
        try await store.save(op)
        cache[id] = op
        unsaved.remove(id)
        return op
    }

    /// The user retries after fixing the cause (signed in again, server settings).
    @discardableResult
    public func retryNow(_ id: UUID) async throws -> OutboxOperation {
        var op = try await operation(id)
        switch op.state {
        case .retryWaiting, .needsSignIn: break
        default: throw OutboxError.notResendable(state: op.state.name)
        }
        op.phase = .notSubmitted
        try op.move(to: .queued, at: now(), note: "retried by the user")
        try await store.save(op)
        cache[id] = op
        unsaved.remove(id)
        return op
    }

    // MARK: Persistence

    /// Saves; on failure the state is kept in memory (never rolled back) and
    /// the save is retried before the next submission.
    private func persist(_ op: OutboxOperation) async {
        cache[op.id] = op
        do { try await store.save(op); unsaved.remove(op.id) } catch { unsaved.insert(op.id) }
    }

    private func flushUnsaved() async {
        for id in unsaved { if let op = cache[id] { await persist(op) } }
    }

    // MARK: Checks

    static func isCancelled(_ s: OutboxState) -> Bool {
        if case .cancelledBeforeSubmission = s { return true }
        return false
    }

    static func isAppendFailed(_ s: SentCopyState) -> Bool {
        if case .appendFailed = s { return true }
        return false
    }

    static func firstLine(_ s: String) -> String? {
        s.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init)
    }

    /// CRLF only (no bare CR / LF), no NUL, lines ≤ 998 octets (RFC 5322 §2.1.1), no Bcc in the header.
    static func checkCanonical(_ bytes: Data) throws {
        var previous: UInt8 = 0
        var lineLength = 0
        var headerEnded = false
        var lineStart = bytes.startIndex
        for i in bytes.indices {
            let b = bytes[i]
            if b == 0 { throw OutboxError.messageNotCanonical("it contains a NUL byte") }
            if previous == 0x0D && b != 0x0A { throw OutboxError.messageNotCanonical("it contains a bare carriage return") }
            if b == 0x0A {
                guard previous == 0x0D else { throw OutboxError.messageNotCanonical("it contains a bare line feed") }
                let line = bytes[lineStart..<(i - 1)]
                if !headerEnded {
                    if line.isEmpty { headerEnded = true } else if line.count >= 4, String(decoding: line.prefix(4), as: UTF8.self).lowercased() == "bcc:" {
                        throw OutboxError.bccInHeader
                    }
                }
                lineLength = 0
                lineStart = i + 1
            } else if b != 0x0D {
                lineLength += 1
                if lineLength > 998 { throw OutboxError.messageNotCanonical("a line is longer than 998 characters") }
            }
            previous = b
        }
        if previous == 0x0D { throw OutboxError.messageNotCanonical("it ends with a bare carriage return") }
    }

    /// The Bcc field for an API submission (never stored in the message).
    static func bccHeader(for draft: Draft, utf8: Bool) throws -> String? {
        let visible = Set((draft.to + draft.cc).map(\.normalizedKey))
        let bcc = MailAddressParser.deduplicated(draft.bcc, excluding: visible)
        guard !bcc.isEmpty else { return nil }
        let value = try bcc.map { a -> String in
            var bare = a
            bare.displayName = nil       // the name of a hidden recipient is not needed for routing
            return try MIMEComposer.formatAddress(bare, utf8: utf8)
        }.joined(separator: ", ")
        return try MIMEComposer.fold("Bcc", value)
    }
}
