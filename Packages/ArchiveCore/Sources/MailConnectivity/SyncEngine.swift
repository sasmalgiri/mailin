//
//  SyncEngine.swift
//  MailConnectivity
//
//  Plan v4 V4-04 (§5.2, §5.3): the provider-independent capture engine.
//  One actor per account; every account's engine shares one
//  `ConnectedArchiveSink` (the archive) and one `FairDownloadScheduler`.
//
//  A sync run, in order:
//   1. Folder list — every page (`listFolders` until nextPageToken == nil);
//      recorded, empty folders included.
//   2. Exact retry of earlier failures (items whose latest outcome is
//      `failed` and that are not preserved).
//   3. Per change scope (the account for Gmail, each folder for Graph / IMAP
//      CONDSTORE, none for plain IMAP):
//        bootstrap  — take the provider's change BOUNDARY first and persist it
//                     (`bootstrapping@<generation>`), then enumerate every
//                     selected folder page by page, then apply the changes
//                     made since the boundary (arrivals, moves, deletions
//                     during the bootstrap), then mark the scope `ready`.
//        incremental — apply changes from the stored cursor; an expired
//                     cursor (`changeTokenExpired`) starts a new generation:
//                     a full reconciliation that re-lists everything and
//                     downloads only what is not yet preserved.
//   Per page: discovered identities are durably queued (`pending`) → each is
//   either observed (already preserved: memberships only) or downloaded
//   (bytes streamed to an owner-only staging file and hashed → the sink
//   publishes and commits record + occurrence + outcome) → failures are
//   recorded `failed` (with reason) or `unavailable` (gone on the server) →
//   only when every item of the run is terminal does the page's cursor
//   commit (the sink re-checks that inside its write transaction).
//
//  Stops (never a completion claim): cancellation, disk full / drive gone,
//  provider quota, throttling beyond the run's wait budget, sign-in needed,
//  network not permitted. A stopped run keeps its pending items pending and
//  its cursors where they were; the next run resumes from them.
//

import ArchiveCore
import Foundation

// MARK: - Public vocabulary

public enum SyncSelection: Sendable, Equatable {
    /// Every folder / label the provider lists.
    case allFolders
    /// These server folder / label ids only — a user selection, stated as such.
    case folders(Set<String>)

    public var description: String {
        switch self {
        case .allFolders: return "all folders"
        case .folders(let ids): return "folders: " + ids.sorted().joined(separator: ", ")
        }
    }

    func apply(_ all: [RemoteFolderOccurrence]) -> [RemoteFolderOccurrence] {
        switch self {
        case .allFolders: return all
        case .folders(let ids): return all.filter { ids.contains($0.serverID) }
        }
    }

    func includes(_ occurrences: [RemoteFolderOccurrence]) -> Bool {
        switch self {
        case .allFolders: return true
        case .folders(let ids): return occurrences.isEmpty || occurrences.contains { ids.contains($0.serverID) }
        }
    }
}

public enum SyncPauseReason: Sendable, Equatable {
    case diskFull(availableBytes: Int64)
    case driveUnavailable
    case quotaExceeded(resetAfter: TimeInterval?)
    case rateLimited(retryAfter: TimeInterval?)
}

/// The account's live state (the UI combines it with `ConnectedCompleteness`).
public enum AccountSyncState: Sendable, Equatable {
    case idle
    case syncing
    case backingOff(seconds: TimeInterval)
    case paused(SyncPauseReason)
    case needsSignIn
    case notPermitted(String)
    case cancelled
    case failed(String)
}

public enum SyncOutcome: Sendable, Equatable {
    /// The selection was enumerated to its end and reconciled to a change
    /// point; nothing pending, nothing failed. Unavailable items (gone on the
    /// server before they could be saved) are counted in the receipt.
    case completed
    /// As `completed`, but `failed` items have recorded reasons and will be retried.
    case completedWithFailures(failed: Int)
    case paused(SyncPauseReason)
    case needsSignIn
    case notPermitted(String)
    case cancelled
    case failed(String)
    /// Tests only: a simulated process death — nothing after it ran.
    case aborted

    public var isCompletion: Bool {
        switch self {
        case .completed, .completedWithFailures: return true
        default: return false
        }
    }
}

public struct SyncRunReport: Sendable {
    public var runID: String?
    public var outcome: SyncOutcome
    /// The run's durable counts (nil when the run could not even begin).
    public var receipt: CaptureRunReceipt?
    /// The capture interval: mailboxes change while read, so coverage is
    /// stated over [startedAt, endedAt] up to `reconciledTo`, never as an
    /// atomic snapshot.
    public var startedAt: Date
    public var endedAt: Date
    public var reconciledTo: String?
    /// True when this run (re)built the inventory from a full enumeration.
    public var fullEnumeration: Bool
    public var selection: String
    /// V4-12: set when the run paused because the archive's drive is gone —
    /// the drive the user must reconnect (never a fallback archive elsewhere).
    public var missingDrive: ArchiveDriveIdentity? = nil
}

/// Where engine-level kill tests interrupt a run.
public enum SyncBoundary: String, Sendable, CaseIterable {
    case afterBoundaryRecorded, afterDiscovered, afterPageCheckpoint, afterChangePage
}

// MARK: - Engine

public actor SyncEngine {
    public nonisolated let accountID: UUID
    let adapter: any MailProviderAdapter
    let sink: ConnectedArchiveSink
    let scheduler: FairDownloadScheduler
    let tokens: (any AccessTokenSource)?
    let permission: NetworkPermission
    let backoff: BackoffPolicy
    let storage: StorageProbe

    public private(set) var state: AccountSyncState = .idle
    /// V4-12: the drive named by the last `.driveUnavailable` pause.
    public private(set) var missingDrive: ArchiveDriveIdentity?
    private var running = false
    /// V4-12: bytes the downloads in flight may still need on the archive
    /// volume (staged copy + published copy each), so parallel downloads
    /// never pass the free-space check on the same bytes.
    private var reservedForInFlight: Int64 = 0
    /// The largest archive write need seen in this run: a failed archive
    /// write is re-checked against it, so a volume that filled up mid-write
    /// pauses the account instead of failing it.
    private var largestWriteNeed: Int64 = 0
    private var limits = ProviderLimits(changeTracking: .none)
    private var selection: SyncSelection = .allFolders

    private var refreshTask: Task<String, Error>?
    /// Tokens already refreshed away: a late 401 carrying one just retries.
    private var supersededTokens: Set<String> = []
    private var throttleGate: Task<Void, Error>?
    private var throttleWaited: TimeInterval = 0

    // Diagnostics (tests, Health).
    public private(set) var peakItemsHeld = 0
    public private(set) var downloadsAttempted = 0
    public private(set) var waits: [TimeInterval] = []

    // Test hooks.
    var faultHook: (@Sendable (SyncBoundary) throws -> Void)?
    var abortFilter: (@Sendable (Error) -> Bool)?
    func setFaultHook(_ hook: (@Sendable (SyncBoundary) throws -> Void)?) { faultHook = hook }
    func setAbortFilter(_ filter: (@Sendable (Error) -> Bool)?) { abortFilter = filter }

    public init(adapter: any MailProviderAdapter, sink: ConnectedArchiveSink, scheduler: FairDownloadScheduler,
                tokens: (any AccessTokenSource)?, permission: @escaping NetworkPermission,
                backoff: BackoffPolicy = BackoffPolicy(), storage: StorageProbe = StorageProbe()) {
        self.accountID = adapter.accountID
        self.adapter = adapter; self.sink = sink; self.scheduler = scheduler; self.tokens = tokens
        self.permission = permission; self.backoff = backoff; self.storage = storage
    }

    // MARK: Errors

    /// Why a run stopped before its end.
    enum Stop: Error {
        case paused(SyncPauseReason)
        case needsSignIn
        case notPermitted(String)
        case cancelled
        case failed(String)
        case aborted
    }

    /// A request that kept failing transiently.
    struct RetriesExhausted: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    // MARK: Run

    /// One capture run of `selection`. Never throws: every way it can end is
    /// an outcome, and only `completed*` claims completion.
    public func sync(_ selection: SyncSelection = .allFolders) async -> SyncRunReport {
        let started = Date()
        guard !running else {
            return SyncRunReport(runID: nil, outcome: .failed("A capture of this account is already running."), receipt: nil,
                                 startedAt: started, endedAt: Date(), reconciledTo: nil, fullEnumeration: false,
                                 selection: selection.description)
        }
        running = true
        defer { running = false }
        self.selection = selection
        state = .syncing
        missingDrive = nil
        largestWriteNeed = 0
        throttleWaited = 0
        var runID: String?
        do {
            limits = await adapter.limits()
            try storageCheck(nextBytes: 0)
            let id = try await sink.beginRun(accountID: accountID, selection: selection.description)
            runID = id
            let all = try await listAllFolders()
            try await sink.recordFolders(accountID: accountID, folders: all)
            let selected = selection.apply(all)
            try await retryEarlierFailures(runID: id)
            let (point, full) = try await syncScopes(selected, runID: id)
            let receipt = try await sink.finishRun(id)
            let outcome: SyncOutcome
            if receipt.pending > 0 {
                outcome = .failed("\(receipt.pending) listed messages have no outcome.")
            } else if receipt.failed > 0 {
                outcome = .completedWithFailures(failed: receipt.failed)
            } else {
                outcome = .completed
            }
            state = .idle
            return SyncRunReport(runID: id, outcome: outcome, receipt: receipt, startedAt: started, endedAt: Date(),
                                 reconciledTo: point, fullEnumeration: full, selection: selection.description)
        } catch {
            let stop = classify(error)
            if case .aborted = stop {
                // A dead process records nothing more.
                return SyncRunReport(runID: runID, outcome: .aborted, receipt: nil, startedAt: started, endedAt: Date(),
                                     reconciledTo: nil, fullEnumeration: false, selection: selection.description)
            }
            let outcome: SyncOutcome
            switch stop {
            case .paused(let why):
                outcome = .paused(why); state = .paused(why)
                if why == .driveUnavailable { missingDrive = storage.drive }
            case .needsSignIn: outcome = .needsSignIn; state = .needsSignIn
            case .notPermitted(let why): outcome = .notPermitted(why); state = .notPermitted(why)
            case .cancelled: outcome = .cancelled; state = .cancelled
            case .failed(let why): outcome = .failed(why); state = .failed(why)
            case .aborted: outcome = .aborted
            }
            var receipt: CaptureRunReceipt?
            if let runID {
                receipt = try? await sink.finishRun(runID)
                if receipt != nil { receipt?.state = .partial }
                try? await sink.markRunStopped(runID, reason: "\(outcome)")
            }
            return SyncRunReport(runID: runID, outcome: outcome, receipt: receipt, startedAt: started, endedAt: Date(),
                                 reconciledTo: nil, fullEnumeration: false, selection: selection.description,
                                 missingDrive: outcome == .paused(.driveUnavailable) ? storage.drive : nil)
        }
    }

    private func classify(_ error: Error) -> Stop {
        if let abortFilter, abortFilter(error) { return .aborted }
        if let stop = error as? Stop { return stop }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let e = error as? MailProviderError {
            switch e {
            case .reauthorisationRequired, .unauthorized: return .needsSignIn
            case .quotaExceeded(let reset): return .paused(.quotaExceeded(resetAfter: reset))
            case .rateLimited(let after): return .paused(.rateLimited(retryAfter: after))
            default: return .failed(String(describing: e))
            }
        }
        if case OAuthError.reauthorisationNeeded = error { return .needsSignIn }
        // V4-12: the volume itself said it is full (its free-space figure can
        // be optimistic): a pause until space is freed, never a failure.
        if ArchiveWriteError.isOutOfSpace(error) {
            guard let available = storage.availableBytes(archiveDirectory) else { return .paused(.driveUnavailable) }
            return .paused(.diskFull(availableBytes: available))
        }
        // Archive-side write failures: the volume decides what the user is told
        // (V4-12: re-checked against what the failed write needed).
        if let storageStop = storageStopIfAny(nextBytes: largestWriteNeed) { return storageStop }
        return .failed(error.localizedDescription)
    }

    private func fault(_ boundary: SyncBoundary) throws {
        try faultHook?(boundary)
    }

    // MARK: Storage

    private var archiveDirectory: URL { sink.stagingDirectory.deletingLastPathComponent() }

    private func storageStopIfAny(nextBytes: Int64 = 0) -> Stop? {
        guard let available = storage.availableBytes(archiveDirectory) else { return .paused(.driveUnavailable) }
        if available - nextBytes < storage.reserveBytes { return .paused(.diskFull(availableBytes: available)) }
        return nil
    }

    private func storageCheck(nextBytes: Int64) throws {
        if let stop = storageStopIfAny(nextBytes: nextBytes) { throw stop }
    }

    // MARK: Requests

    private func ask(_ operation: SyncNetworkOperation, destination: NetworkAsk.Destination = .mailServer) throws {
        let host = destination == .authorization ? (adapter.authorizationHost ?? adapter.mailHost) : adapter.mailHost
        do {
            try permission(NetworkAsk(accountID: accountID, host: host, destination: destination, operation: operation))
        } catch {
            throw Stop.notPermitted(error.localizedDescription)
        }
    }

    private func currentToken() async throws -> String? {
        guard let audience = adapter.tokenAudience, let tokens else { return nil }
        if let refreshTask { return try await mapAuth { try await refreshTask.value } }
        return try await mapAuth { try await tokens.accessToken(for: self.accountID, audience: audience) }
    }

    private func mapAuth<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch {
            if case OAuthError.reauthorisationNeeded = error { throw Stop.needsSignIn }
            throw error
        }
    }

    /// After a 401: one shared refresh per rejected token.
    private func refreshToken(rejected: String?) async throws {
        guard let audience = adapter.tokenAudience, let tokens else { throw Stop.needsSignIn }
        if let refreshTask { _ = try await mapAuth { try await refreshTask.value }; return }
        if let rejected, supersededTokens.contains(rejected) { return }
        try ask(.oauthRefresh, destination: .authorization)
        let account = accountID
        let task = Task { try await tokens.refreshAfterRejection(account: account, audience: audience) }
        refreshTask = task
        defer { refreshTask = nil }
        let fresh = try await mapAuth { try await task.value }
        if let rejected, rejected != fresh { supersededTokens.insert(rejected) }
    }

    private func waitForThrottle() async throws {
        guard let gate = throttleGate else { return }
        try await withTaskCancellationHandler { try await gate.value } onCancel: { gate.cancel() }
    }

    /// The account waits (holding no download slot); other accounts go on.
    private func throttle(retryAfter: TimeInterval?, attempt: Int) async throws {
        if throttleGate != nil { try await waitForThrottle(); return }
        let delay = backoff.delay(attempt: attempt, retryAfter: retryAfter)
        guard throttleWaited + delay <= backoff.maximumThrottleWait else {
            throw Stop.paused(.rateLimited(retryAfter: retryAfter ?? delay))
        }
        throttleWaited += delay
        waits.append(delay)
        state = .backingOff(seconds: delay)
        let sleep = backoff.sleep
        let gate = Task { try await sleep(delay) }
        throttleGate = gate
        defer { throttleGate = nil; if case .backingOff = state { state = .syncing } }
        try await withTaskCancellationHandler { try await gate.value } onCancel: { gate.cancel() }
    }

    private func transientWait(_ failures: Int) async throws {
        let delay = backoff.delay(attempt: failures, retryAfter: nil)
        waits.append(delay)
        try await backoff.sleep(delay)
    }

    /// Runs one provider request with the policy check, token, 401 refresh,
    /// throttling and transient backoff. Every attempt — the first and each
    /// retry — asks the network policy first.
    private func perform<T: Sendable>(_ operation: SyncNetworkOperation,
                                      _ body: (ProviderRequestContext) async throws -> T) async throws -> T {
        var attempt = 0
        var transientFailures = 0
        var refreshed = false
        while true {
            try Task.checkCancellation()
            try await waitForThrottle()
            try ask(attempt == 0 ? operation : .retry)
            let token = try await currentToken()
            do {
                return try await body(ProviderRequestContext(accountID: accountID, accessToken: token, attempt: attempt))
            } catch let error as MailProviderError {
                switch error {
                case .unauthorized:
                    guard !refreshed, adapter.tokenAudience != nil else { throw Stop.needsSignIn }
                    refreshed = true
                    try await refreshToken(rejected: token)
                case .rateLimited(let after):
                    try await throttle(retryAfter: after, attempt: attempt + 1)
                case .transient(let why):
                    transientFailures += 1
                    guard transientFailures < backoff.transientAttempts else {
                        throw RetriesExhausted(reason: "\(why) (\(transientFailures) attempts)")
                    }
                    try await transientWait(transientFailures)
                default:
                    throw error
                }
            }
            attempt += 1
        }
    }

    // MARK: Folders

    private func listAllFolders() async throws -> [RemoteFolderOccurrence] {
        var out: [RemoteFolderOccurrence] = []
        var token: String?
        repeat {
            let page = try await perform(.request) { [adapter] ctx in try await adapter.listFolders(pageToken: token, context: ctx) }
            out.append(contentsOf: page.folders)
            token = page.nextPageToken
        } while token != nil
        return out
    }

    // MARK: Scopes

    private func syncScopes(_ selected: [RemoteFolderOccurrence], runID: String) async throws -> (String?, Bool) {
        switch limits.changeTracking {
        case .accountWide, .none:
            return try await syncScope(.account, folders: selected, runID: runID)
        case .perFolder:
            var points: [String] = []
            var full = false
            for folder in selected {
                let (point, rebuilt) = try await syncScope(.folder(folder), folders: [folder], runID: runID)
                if let point { points.append("\(folder.serverID)=\(point)") }
                full = full || rebuilt
            }
            return (points.joined(separator: "; "), full)
        }
    }

    private static func generation(_ state: String) -> String? {
        guard let at = state.firstIndex(of: "@") else { return nil }
        return String(state[state.index(after: at)...])
    }

    private func syncScope(_ scope: ChangeScope, folders: [RemoteFolderOccurrence], runID: String) async throws -> (String?, Bool) {
        let tracking = limits.changeTracking
        let checkpointScope = scope.checkpointScope
        let existing = try await sink.checkpoint(accountID: accountID, scope: checkpointScope)

        if let cp = existing, cp.bootstrapState.hasPrefix("ready@"), tracking != .none,
           let generation = Self.generation(cp.bootstrapState) {
            do {
                // Folders newly selected since the bootstrap are enumerated first.
                try await enumerate(folders, generation: generation, runID: runID)
                let point = try await applyChanges(scope, from: cp.cursor, generation: generation, bootstrapping: false, runID: runID)
                return (point, false)
            } catch MailProviderError.changeTokenExpired {
                // History / delta expired: a new generation, full reconciliation.
                return try await bootstrap(scope, folders: folders, runID: runID, resume: nil)
            }
        }
        let resume = existing.flatMap { cp -> (String, String)? in
            guard cp.bootstrapState.hasPrefix("bootstrapping@"), let g = Self.generation(cp.bootstrapState) else { return nil }
            return (g, cp.cursor)
        }
        return try await bootstrap(scope, folders: folders, runID: runID, resume: resume)
    }

    private func bootstrap(_ scope: ChangeScope, folders: [RemoteFolderOccurrence], runID: String,
                           resume: (generation: String, cursor: String)?) async throws -> (String?, Bool) {
        let tracking = limits.changeTracking
        let checkpointScope = scope.checkpointScope
        var expiredOnce = false
        var resume = resume
        while true {
            let generation: String
            let boundary: String
            if let resume {
                generation = resume.generation
                boundary = resume.cursor
            } else {
                generation = UUID().uuidString
                // The change boundary is taken BEFORE enumerating, so nothing
                // that changes during the enumeration falls between the two.
                boundary = tracking == .none ? "" : try await perform(.request) { [adapter] ctx in
                    try await adapter.changeBoundary(scope: scope, context: ctx)
                }
                try await sink.advanceCheckpoint(accountID: accountID, scope: checkpointScope, cursor: boundary,
                                                 bootstrapState: "bootstrapping@\(generation)", runID: runID)
                try fault(.afterBoundaryRecorded)
            }
            try await enumerate(folders, generation: generation, runID: runID)
            var point = boundary
            if tracking != .none {
                do {
                    point = try await applyChanges(scope, from: boundary, generation: generation, bootstrapping: true, runID: runID)
                } catch MailProviderError.changeTokenExpired {
                    // The boundary expired during a very long bootstrap: one
                    // fresh generation (already-preserved mail is not fetched again).
                    guard !expiredOnce else { throw Stop.failed("The provider's change history expired twice during one capture.") }
                    expiredOnce = true
                    resume = nil
                    continue
                }
            }
            try await sink.advanceCheckpoint(accountID: accountID, scope: checkpointScope, cursor: point,
                                             bootstrapState: "ready@\(generation)", runID: runID)
            return (tracking == .none ? nil : point, true)
        }
    }

    // MARK: Enumeration

    private func enumerate(_ folders: [RemoteFolderOccurrence], generation: String, runID: String) async throws {
        for folder in folders {
            let scope = "enum:\(folder.serverID)"
            var cursor: String?
            if let cp = try await sink.checkpoint(accountID: accountID, scope: scope) {
                if cp.bootstrapState == "enumerated@\(generation)" { continue }
                if cp.bootstrapState == "enumerating@\(generation)" { cursor = cp.cursor.isEmpty ? nil : cp.cursor }
            }
            repeat {
                let page: EnumerationPage
                do {
                    let pageSize = limits.pageSize
                    page = try await perform(.request) { [adapter, cursor] ctx in
                        try await adapter.enumerate(folder: folder, cursor: cursor, pageSize: pageSize, context: ctx)
                    }
                } catch MailProviderError.folderUnavailable {
                    // Deleted / renamed on the server mid-run: what was listed
                    // is kept; its messages reappear through the change log.
                    page = EnumerationPage(items: [], nextCursor: nil)
                }
                try await process(page.items.map { ($0, $0.folder.map { [$0] } ?? [folder]) }, runID: runID)
                try await sink.advanceCheckpoint(accountID: accountID, scope: scope, cursor: page.nextCursor ?? "",
                                                 bootstrapState: (page.nextCursor == nil ? "enumerated@" : "enumerating@") + generation,
                                                 runID: runID)
                try fault(.afterPageCheckpoint)
                cursor = page.nextCursor
            } while cursor != nil
        }
    }

    // MARK: Changes

    private func applyChanges(_ scope: ChangeScope, from token: String, generation: String, bootstrapping: Bool,
                              runID: String) async throws -> String {
        var cursor = token
        while true {
            let since = cursor
            let page = try await perform(.request) { [adapter] ctx in
                try await adapter.changes(scope: scope, since: since, context: ctx)
            }
            // The last event per message wins (added-then-deleted = deleted).
            var order: [String] = []
            var last: [String: RemoteChange] = [:]
            for change in page.changes {
                let key: String
                switch change {
                case .upserted(let ref, _): key = try ref.identity.key()
                case .deleted(let identity): key = try identity.key()
                }
                if last[key] == nil { order.append(key) }
                last[key] = change
            }
            var upserts: [(RemoteItemRef, [RemoteFolderOccurrence])] = []
            for key in order {
                switch last[key] {
                case .upserted(let ref, let occurrences)?:
                    let occ = occurrences.isEmpty ? (ref.folder.map { [$0] } ?? []) : occurrences
                    if selection.includes(occ) { upserts.append((ref, occ)) }
                case .deleted(let identity)?:
                    // Preserved: the projection says "removed on server"; the
                    // record stays. Never preserved: unavailable, never captured.
                    let known = try await sink.markRemoteAbsent(accountID: accountID, identity: identity)
                    if !known, selection == .allFolders {
                        try await sink.recordDiscovered(runID: runID, identities: [identity])
                        try await sink.recordFailure(runID: runID, identity: identity, state: .unavailable,
                                                     reason: "Deleted on the server before it could be saved.")
                    }
                case nil:
                    break
                }
            }
            try await process(upserts, runID: runID)
            try await sink.advanceCheckpoint(accountID: accountID, scope: scope.checkpointScope, cursor: page.resume,
                                             bootstrapState: (bootstrapping ? "bootstrapping@" : "ready@") + generation,
                                             runID: runID)
            try fault(.afterChangePage)
            cursor = page.resume
            if !page.hasMore { return cursor }
        }
    }

    // MARK: Earlier failures

    private func retryEarlierFailures(runID: String) async throws {
        var after: String?
        while true {
            let batch = try await sink.retryCandidates(accountID: accountID, after: after, limit: limits.pageSize)
            guard let last = batch.last else { return }
            after = try last.key()
            try await process(batch.map { (RemoteItemRef(identity: $0, folder: nil), []) }, runID: runID)
        }
    }

    // MARK: Items

    /// One page: durably queued, then each item observed or downloaded, then
    /// every item has a terminal outcome (or the run stops).
    private func process(_ entries: [(RemoteItemRef, [RemoteFolderOccurrence])], runID: String) async throws {
        guard !entries.isEmpty else { return }
        var seen = Set<String>()
        var unique: [(RemoteItemRef, [RemoteFolderOccurrence])] = []
        for entry in entries where seen.insert(try entry.0.identity.key()).inserted { unique.append(entry) }
        peakItemsHeld = max(peakItemsHeld, unique.count)
        try await sink.recordDiscovered(runID: runID, identities: unique.map(\.0.identity))
        try fault(.afterDiscovered)

        var downloads: [(RemoteItemRef, [RemoteFolderOccurrence])] = []
        for (ref, occurrences) in unique {
            let observed = try await sink.recordObservation(runID: runID, accountID: accountID, identity: ref.identity,
                                                            occurrences: occurrences)
            if observed == nil { downloads.append((ref, occurrences)) }
        }
        guard !downloads.isEmpty else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (ref, occurrences) in downloads {
                group.addTask { try await self.captureOne(ref, occurrences: occurrences, runID: runID) }
            }
            try await group.waitForAll()
        }
    }

    private enum Disposition { case unavailable(String), failed(String), stop }

    private func disposition(_ error: Error) -> Disposition {
        if let abortFilter, abortFilter(error) { return .stop }
        switch error {
        case MailProviderError.itemUnavailable:
            return .unavailable("Deleted or moved on the server before it could be saved.")
        case MailProviderError.permanent(let why):
            return .failed(why)
        case let exhausted as RetriesExhausted:
            return .failed(exhausted.reason)
        case ConnectedArchiveError.stagedBytesMismatch, ConnectedArchiveError.stagedSizeMismatch,
             ConnectedArchiveError.stagedFileMissing, ConnectedArchiveError.invalidIdentity:
            return .failed(error.localizedDescription)
        default:
            return .stop
        }
    }

    private func captureOne(_ ref: RemoteItemRef, occurrences: [RemoteFolderOccurrence], runID: String) async throws {
        do {
            let limit = limits.maxConcurrentDownloads
            _ = try await perform(.download) { ctx in
                try await self.scheduler.acquire(account: self.accountID, accountLimit: limit)
                do {
                    let outcome = try await self.fetchAndCapture(ref, occurrences: occurrences, runID: runID, context: ctx)
                    await self.scheduler.release(account: self.accountID)
                    return outcome
                } catch {
                    await self.scheduler.release(account: self.accountID)
                    throw error
                }
            }
        } catch {
            switch disposition(error) {
            case .unavailable(let reason):
                try await sink.recordFailure(runID: runID, identity: ref.identity, state: .unavailable, reason: reason)
            case .failed(let reason):
                try await sink.recordFailure(runID: runID, identity: ref.identity, state: .failed, reason: reason)
            case .stop:
                throw error
            }
        }
    }

    private func fetchAndCapture(_ ref: RemoteItemRef, occurrences: [RemoteFolderOccurrence], runID: String,
                                 context: ProviderRequestContext) async throws -> CaptureOutcome {
        // Checked immediately before the bytes are written: a full or
        // missing volume pauses the account before anything is spooled.
        // V4-12: a message needs room twice (the staged copy and the
        // published copy), and downloads already in flight hold their share —
        // the spool is bounded by the volume's free space, never assumed.
        let need = 2 * max(0, ref.sizeHint ?? 0)
        try storageCheck(nextBytes: reservedForInFlight + need)
        reservedForInFlight += need
        defer { reservedForInFlight -= need }
        downloadsAttempted += 1
        let bytes = RawByteSink(writer: try sink.makeStagingWriter())
        do {
            let fetched = try await adapter.fetchRaw(ref, into: bytes, context: context)
            let staged = try bytes.finish()
            if let expected = fetched.expectedByteCount, expected != staged.byteCount {
                try? FileManager.default.removeItem(at: staged.fileURL)
                throw MailProviderError.transient("the transfer ended after \(staged.byteCount) of \(expected) bytes")
            }
            var all = fetched.occurrences
            for o in occurrences where !all.contains(where: { $0.serverID == o.serverID }) { all.append(o) }
            let item = CaptureItem(accountID: accountID, identity: ref.identity, occurrences: all, raw: staged,
                                   metadata: fetched.metadata)
            return try await sink.capture(item, runID: runID)
        } catch {
            largestWriteNeed = max(largestWriteNeed, need, 2 * bytes.bytesWritten)
            bytes.discard()
            throw error
        }
    }

    // MARK: Status

    /// The four completeness states (§5.4) and the line the UI shows.
    /// Search coverage and export verification come from the existing
    /// coverage and receipt code, through the probes.
    public func status(searchCoverage: SearchCoverageProbe? = nil,
                       exportVerification: ExportVerificationProbe? = nil) async throws -> CaptureStatus {
        let completeness = try await sink.completeness(accountID: accountID)
        let search = await searchCoverage?(accountID)
        let export = await exportVerification?(accountID)
        var status = CaptureStatus(accountID: accountID, state: state, completeness: completeness, search: search, export: export)
        if case .paused(.driveUnavailable) = state { status.missingDrive = missingDrive }
        return status
    }
}
