@testable import ArchiveCore
import MailConnectivity
//
//  ConnectedMailRuntime.swift
//  maxmailin
//
//  Plan v4 V4-08 (§3 A08, §5.4, §5.5): connected mail inside the five jobs.
//
//  One runtime per process, created only when the `connectedMail` capability
//  is on in a build that compiled the mail transports (the offline build
//  never creates it: `ConnectedBuildFeatures.mailTransportsCompiled` is false
//  there and the Live Mail page is excluded). It owns:
//
//    • the ONE `ConnectedArchiveSink`, on the shared store (one connection
//      for every archive write), and `reconcileAfterRestart` before any
//      capture of this process starts;
//    • `MailAccountRegistry` (records in the archive, secrets in the
//      Keychain keyed by account UUID) and the ONE `TokenRefreshCoordinator`;
//    • one `SyncEngine` per enabled account, built with its provider's
//      adapter, all sharing one `FairDownloadScheduler`;
//    • the `NetworkPermission` closure — `MailNetworkPolicy.permit` with
//      purpose "preserve mail" — asked before every request, retry, download
//      and token refresh;
//    • the cancellation registry: every capture run is registered with the
//      policy, so switching Mail or the account off cancels it.
//
//  Five jobs (§5.5): online mail enters ONLY through the sink (the unscoped
//  `ContentViewModel.ingestEmails` is not used for it, A08). Every NEWLY
//  stored record is handed to `ConnectedSearchFeed`, which indexes it into the
//  full-text index exactly like an import and kicks the attachment text job,
//  so the same bytes give the same evidence and coverage whichever way they
//  arrived (T14/T15). Folders are the account's remote folders under the
//  account's source; duplicates, exports and backups read the same tables as
//  for imports. Removing an account deletes its secrets only — preserved mail,
//  folders, search and exports keep working offline (T21).
//
//  Nothing in this file opens a connection. The production adapters (the
//  only code that does, through the package's transports) are at the bottom,
//  behind the mail compile gate.
//

import Foundation
import os

// MARK: - Adapter factory

/// What a factory needs to build one account's provider adapter.
struct ConnectedAdapterContext: Sendable {
    let account: MailAccount
    let credentials: any CredentialStore
    /// The one coordinator; a factory registers the account's OAuth client here.
    let tokens: TokenRefreshCoordinator?
    /// The policy check every adapter request goes through.
    let permission: NetworkPermission
}

/// Builds an account's adapter; nil = this build has no transport for it.
/// A thrown error is the reason shown for the account (e.g. sign-in not configured).
typealias ConnectedAdapterFactory = @Sendable (ConnectedAdapterContext) async throws -> (any MailProviderAdapter)?

/// REC-07: builds an account's server-action executor (V4-11); the context's
/// permission asks the policy with purpose "change server mail".
typealias ConnectedActionExecutorFactory = @Sendable (ConnectedAdapterContext) async throws -> (any RemoteActionExecutor)?

// MARK: - Search feed

/// Indexes newly captured records into the full-text index exactly as an
/// import does, in batches, and tells the app (attachment text job, corpus
/// revision, list refresh). A record whose indexing fails stays in the store
/// and is indexed by the launch-time search reconcile, which compares the
/// store with the index — never lost, never claimed indexed.
actor ConnectedSearchFeed {
    private let store: SQLiteEmailStore
    private let fts: FTSSearchIndex
    private let batchSize: Int
    private let afterIndex: @Sendable ([UUID]) async -> Void
    private var pending: [UUID] = []
    /// REC-07: records indexed successfully and not yet handed to the
    /// capture rules (a failed batch is never handed over: the rules' catch-up
    /// evaluates it once the launch reconcile has indexed it).
    private var indexedForRules: [UUID] = []
    private(set) var indexed = 0
    private(set) var lastError: String?

    /// The records indexed since the last call (REC-07 capture rules).
    func drainIndexed() -> [UUID] {
        defer { indexedForRules.removeAll() }
        return indexedForRules
    }

    init(store: SQLiteEmailStore, fts: FTSSearchIndex, batchSize: Int = 200,
         afterIndex: @escaping @Sendable ([UUID]) async -> Void) {
        self.store = store; self.fts = fts; self.batchSize = max(1, batchSize); self.afterIndex = afterIndex
    }

    func enqueue(_ id: UUID) async {
        pending.append(id)
        if pending.count >= batchSize { await flush() }
    }

    /// Indexes everything queued. Called after every run, stopped or not.
    func flush() async {
        guard !pending.isEmpty else { return }
        let ids = pending
        pending.removeAll(keepingCapacity: true)
        do {
            let emails = try await store.emails(withIDs: ids)
            try await fts.indexBatch(emails)
            indexed += emails.count
            indexedForRules += emails.map(\.id)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await afterIndex(ids)
    }
}

// MARK: - Runtime

@MainActor
final class ConnectedMailRuntime {

    struct Dependencies {
        var store: SQLiteEmailStore
        var fts: FTSSearchIndex
        var policy: MailNetworkPolicy
        var credentials: any CredentialStore
        var tokens: TokenRefreshCoordinator?
        var adapters: ConnectedAdapterFactory
        /// After a batch of captured records was indexed (app: attachment
        /// text job, corpus revision, list refresh).
        var afterIndex: @Sendable ([UUID]) async -> Void = { _ in }
        /// V4-13: hosts an account talks to besides its capture host (its
        /// outgoing SMTP server), granted in the policy with the account.
        var extraMailHosts: @Sendable (MailAccount) -> Set<String> = { _ in [] }
        var scheduler = FairDownloadScheduler()
        var backoff = BackoffPolicy()
        var storage = StorageProbe()
        /// REC-07: builds an account's server-action executor (nil = this
        /// build cannot change server mail for it). Asked only after the
        /// account's "Change server mail" permission was checked.
        var actionExecutors: ConnectedActionExecutorFactory = { _ in nil }
        /// How often a running capture tells the page to redraw its counts
        /// (at most once per interval, only while a capture runs).
        var progressInterval: TimeInterval = 2
        /// Waits before an automatic retry (injected so tests do not wait).
        var retrySleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    }

    nonisolated static let didChange = Notification.Name("ConnectedMailRuntime.didChange")
    /// Posted (throttled to `progressInterval`) while a capture runs, so the
    /// page can redraw the account's "N saved, M to go" without a full reload.
    nonisolated static let progress = Notification.Name("ConnectedMailRuntime.progress")
    private static let log = Logger(subsystem: "com.ecosanskriti.mailin", category: "ConnectedMail")

    /// The process's runtime; nil while connected mail is off (always nil in the offline build).
    private(set) static var shared: ConnectedMailRuntime?

    let sink: ConnectedArchiveSink
    let registry: MailAccountRegistry
    let feed: ConnectedSearchFeed
    let policy: MailNetworkPolicy
    private let deps: Dependencies

    private(set) var engines: [UUID: SyncEngine] = [:]
    /// Why an account has no engine (switched off, removed, sign-in not configured…).
    private(set) var unavailable: [UUID: String] = [:]
    private(set) var reconcileReport: ConnectedReconcileReport?
    private(set) var lastReports: [UUID: SyncRunReport] = [:]
    /// V4-13: accounts whose capture the person paused (modes unchanged;
    /// running capture cancelled; Sync now and automatic runs refused).
    private(set) var paused: Set<UUID> = []
    /// Accounts with a capture under way right now (Sync now, launch sync,
    /// automatic retry, selective capture).
    private(set) var running: Set<UUID> = []
    /// When an account paused by its provider (throttling, quota) or by a
    /// server that kept failing is tried again on its own.
    private(set) var nextRetry: [UUID: Date] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    /// One adapter per account, kept while the account's connection settings
    /// are unchanged (each adapter owns a URLSession; rebuilding it on every
    /// reload leaked one session per account per reload).
    private var adapters: [UUID: (fingerprint: String, adapter: any MailProviderAdapter)] = [:]
    /// Adapters replaced while their account was capturing: closed when that run ends.
    private var retiredAdapters: [UUID: [any MailProviderAdapter]] = [:]
    private var started = false

    init(dependencies: Dependencies) {
        deps = dependencies
        policy = dependencies.policy
        sink = ConnectedArchiveSink(store: dependencies.store)
        registry = MailAccountRegistry(records: sink, credentials: dependencies.credentials)
        feed = ConnectedSearchFeed(store: dependencies.store, fts: dependencies.fts, afterIndex: dependencies.afterIndex)
    }

    // MARK: Lifecycle

    /// Once per process, before any capture: restart reconciliation, the
    /// search feed, then the accounts.
    func start() async throws {
        if !started {
            reconcileReport = try await sink.reconcileAfterRestart()
            let feed = self.feed
            await sink.setStoredObserver { id in await feed.enqueue(id) }
            started = true
        }
        try await reloadAccounts()
    }

    /// Re-reads the accounts: pushes each one's permission into the policy
    /// and keeps exactly one engine per account that may capture.
    func reloadAccounts() async throws {
        let accounts = try await registry.accounts()
        let permission = Self.permission(policy: policy)
        var seen = Set<UUID>()
        for account in accounts {
            seen.insert(account.id)
            // V4-13: an account is granted in the policy when it is signed in
            // and allowed at least one mode (Send or Change server mail work
            // without Preserve mail); it gets a capture engine only when
            // Preserve mail is on and the person has not paused it.
            guard account.connectionState == .connected, !account.enabledModes.isEmpty else {
                let reason: String
                switch account.connectionState {
                case .removed: reason = String(localized: "The account was removed; its saved mail stays in the archive.")
                case .needsReauthorisation: reason = String(localized: "Account needs sign-in; saved mail remains available.")
                case .disconnected, .connected: reason = String(localized: "Saving mail is switched off for this account.")
                }
                disable(account.id, reason: reason)
                continue
            }
            do {
                let fingerprint = Self.adapterFingerprint(account)
                let adapter: any MailProviderAdapter
                let rebuilt: Bool
                if let cached = adapters[account.id], cached.fingerprint == fingerprint {
                    adapter = cached.adapter
                    rebuilt = false
                } else {
                    let context = ConnectedAdapterContext(account: account, credentials: deps.credentials,
                                                          tokens: deps.tokens, permission: permission)
                    guard let built = try await deps.adapters(context) else {
                        disable(account.id, reason: String(localized: "This edition has no mail connection code."))
                        continue
                    }
                    if let old = adapters[account.id]?.adapter { retire(old, account: account.id) }
                    adapters[account.id] = (fingerprint, built)
                    adapter = built
                    rebuilt = true
                }
                var modes = Self.networkModes(account.enabledModes)
                let capturing = account.enabledModes.contains(.capture) && !paused.contains(account.id)
                if !capturing { modes.remove(.preserveMail) }
                policy.setAccount(MailAccountNetworkPolicy(
                    id: account.id, isEnabled: true, modes: modes,
                    mailHosts: Set([adapter.mailHost]).union(deps.extraMailHosts(account)),
                    authorizationHosts: adapter.authorizationHost.map { [$0] } ?? []))
                if capturing {
                    if engines[account.id] == nil || rebuilt {
                        engines[account.id] = SyncEngine(adapter: adapter, sink: sink, scheduler: deps.scheduler,
                                                         tokens: deps.tokens, permission: permission,
                                                         backoff: deps.backoff, storage: deps.storage)
                    }
                    unavailable[account.id] = nil
                } else {
                    engines[account.id] = nil
                    cancelRetry(account.id)
                    unavailable[account.id] = paused.contains(account.id)
                        ? String(localized: "Capture paused by you; saved mail remains available.")
                        : String(localized: "Saving mail is switched off for this account.")
                }
            } catch {
                disable(account.id, reason: ConnectedMailErrorText.text(for: error))
            }
        }
        for id in Set(engines.keys).union(adapters.keys) where !seen.contains(id) { disable(id, reason: nil) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func disable(_ id: UUID, reason: String?) {
        engines[id] = nil
        cancelRetry(id)
        if let old = adapters.removeValue(forKey: id)?.adapter { retire(old, account: id) }
        if let reason {
            unavailable[id] = reason
            policy.setAccount(MailAccountNetworkPolicy(id: id))   // off, no modes: cancels its work
        } else {
            unavailable[id] = nil
            policy.removeAccount(id)
        }
    }

    /// What an account's adapter is built from: a change to any of it builds a
    /// new adapter (and engine); anything else (modes, state, the shown
    /// address) reuses the existing one.
    nonisolated static func adapterFingerprint(_ a: MailAccount) -> String {
        [a.provider.rawValue, a.issuer, a.tenant ?? "", a.host ?? "", a.port.map(String.init) ?? "", a.loginName ?? "",
         a.grantedScopes.sorted().joined(separator: " ")].joined(separator: "\u{1F}")
    }

    /// Closes a replaced adapter's session now, or when its account's running capture ends.
    private func retire(_ adapter: any MailProviderAdapter, account id: UUID) {
        if running.contains(id) {
            retiredAdapters[id, default: []].append(adapter)
        } else {
            Task { await adapter.close() }
        }
    }

    private func closeRetired(_ id: UUID) {
        guard let old = retiredAdapters.removeValue(forKey: id) else { return }
        Task { for adapter in old { await adapter.close() } }
    }

    /// The account's credential store and token coordinator (the Mail workspace signs in through them).
    var credentials: any CredentialStore { deps.credentials }
    var tokens: TokenRefreshCoordinator? { deps.tokens }

    /// Stops one account's engine and cancels its registered work (account
    /// removal, V4-12); returns how many engines were stopped.
    @discardableResult
    func stopAccount(_ id: UUID) -> Int {
        let had = engines[id] != nil ? 1 : 0
        engines[id] = nil
        cancelRetry(id)
        policy.setAccount(MailAccountNetworkPolicy(id: id))   // off, no modes: cancels its tasks
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return had
    }

    /// Stops every capture of this process (Mail switched off).
    func stop() {
        for id in Array(engines.keys) { policy.removeAccount(id) }
        engines.removeAll()
        for id in Array(retryTasks.keys) { cancelRetry(id) }
        for (id, entry) in adapters { retire(entry.adapter, account: id) }
        adapters.removeAll()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: Capture

    /// One capture run of one account, registered with the policy's
    /// cancellation registry. Nil when the account has no engine or the
    /// policy refuses the work (Mail or the account off).
    /// A second request while the account's capture runs is a no-op (nil):
    /// the running capture goes on and reports for itself.
    @discardableResult
    func sync(_ id: UUID, selection explicit: SyncSelection? = nil) async -> SyncRunReport? {
        guard let engine = engines[id], !paused.contains(id), !running.contains(id) else { return nil }
        // Marked before the first suspension, so two requests never both start.
        running.insert(id)
        cancelRetry(id)
        NotificationCenter.default.post(name: Self.didChange, object: self)
        let selection: SyncSelection
        if let explicit { selection = explicit } else { selection = await savedSelection(id) }
        let box = CaptureTaskBox()
        guard let token = policy.register(accountID: id, label: "capture", cancel: { box.cancel() }) else {
            endRun(id)
            return nil
        }
        let ticker = progressTicker(id)
        let task = Task { await engine.sync(selection) }
        box.set(task)
        let report = await task.value
        ticker.cancel()
        policy.finish(token)
        await feed.flush()
        await applyCaptureRules()
        if case .alreadyRunning = report.outcome {
            endRun(id)
            return nil
        }
        lastReports[id] = report
        if case .needsSignIn = report.outcome {
            // A revoked grant: the account says so; its saved mail stays usable.
            try? await registry.setState(.needsReauthorisation, account: id)
        }
        endRun(id)
        scheduleRetryIfNeeded(id, after: report)
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return report
    }

    private func endRun(_ id: UUID) {
        running.remove(id)
        closeRetired(id)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// While a capture runs: a progress notice at most every `progressInterval`.
    private func progressTicker(_ id: UUID) -> Task<Void, Never> {
        let nanoseconds = UInt64(max(0.01, deps.progressInterval) * 1_000_000_000)
        return Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled, let self, self.running.contains(id) else { return }
                NotificationCenter.default.post(name: Self.progress, object: self, userInfo: ["accountID": id])
            }
        }
    }

    // MARK: Automatic retry

    /// After a stop that passes by itself (provider throttling or quota, a
    /// server that kept failing), the account is tried again on its own after
    /// the engine's suggested wait — the provider's Retry-After / reset first.
    /// Cancelled by Mail off, the account paused, switched off or removed, and
    /// by a manual Sync now (which runs at once instead).
    private func scheduleRetryIfNeeded(_ id: UUID, after report: SyncRunReport) {
        guard let delay = report.suggestedRetry, engines[id] != nil, !paused.contains(id) else { return }
        cancelRetry(id)
        nextRetry[id] = Date().addingTimeInterval(delay)
        let sleep = deps.retrySleep
        retryTasks[id] = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.retryTasks[id] = nil
            self.nextRetry[id] = nil
            await self.sync(id)
        }
    }

    private func cancelRetry(_ id: UUID) {
        retryTasks.removeValue(forKey: id)?.cancel()
        nextRetry[id] = nil
    }

    // MARK: Sign-in lost outside a capture

    /// A send or server action hit a refused refresh (`invalid_grant`): the
    /// account says "Sign in again", exactly as after a capture would.
    func accountNeedsSignIn(_ id: UUID) async {
        guard let account = try? await registry.account(id), account.connectionState == .connected else { return }
        try? await registry.setState(.needsReauthorisation, account: id)
        try? await reloadAccounts()
    }

    /// The token coordinator's `onReauthorisationNeeded`: the coordinator is
    /// made before the runtime, so it reaches the process's runtime when called.
    nonisolated static let reauthorisationHandler: @Sendable (UUID) async -> Void = { id in
        let runtime = await MainActor.run { ConnectedMailRuntime.shared }
        await runtime?.accountNeedsSignIn(id)
    }

    /// Starts a capture of the account without waiting for it (Preserve mail
    /// switched on). Nothing happens when it cannot capture or already runs.
    func startCapture(_ id: UUID) {
        guard engines[id] != nil, !paused.contains(id), !running.contains(id) else { return }
        Task { @MainActor [weak self] in await self?.sync(id) }
    }

    /// Every account with an engine, concurrently (fairness is the scheduler's).
    /// The person's folder selection (V4-13): every folder until one is
    /// deselected; then exactly the selected ones, stated as a selection.
    func savedSelection(_ id: UUID) async -> SyncSelection {
        guard let folders = try? await sink.folderSummaries(accountID: id), folders.contains(where: { !$0.selected }) else {
            return .allFolders
        }
        return .folders(Set(folders.filter(\.selected).map(\.serverID)))
    }

    /// Pauses (or resumes) one account's capture without changing its modes.
    /// Pausing cancels its running capture at once (the policy narrows).
    func setPaused(_ isPaused: Bool, account id: UUID) async throws {
        if isPaused { paused.insert(id); cancelRetry(id) } else { paused.remove(id) }
        try await reloadAccounts()
    }

    @discardableResult
    func syncAll(selection: SyncSelection? = nil) async -> [UUID: SyncRunReport] {
        let ids = Array(engines.keys)
        let results = await withTaskGroup(of: (UUID, SyncRunReport?).self, returning: [UUID: SyncRunReport].self) { group in
            for id in ids {
                group.addTask { @MainActor in (id, await self.sync(id, selection: selection)) }
            }
            var out: [UUID: SyncRunReport] = [:]
            for await (id, report) in group { if let report { out[id] = report } }
            return out
        }
        return results
    }

    // MARK: REC-07 — selective capture, capture rules, server cleanup

    /// Deterministic capture rules (RQ09), evaluated after every capture's
    /// records were indexed; nil = no rules engine in this process.
    var rules: CaptureRuleEngine?

    /// Hands the newly indexed records to the rules (each rule fires at most
    /// once per message, also across replays and restarts).
    func applyCaptureRules() async {
        let ids = await feed.drainIndexed()
        guard let rules, !ids.isEmpty else { return }
        _ = await rules.handleIndexed(ids)
    }

    /// The account's folders / labels (every page), for the selection.
    func folderList(_ id: UUID) async throws -> [RemoteFolderOccurrence] {
        guard let engine = engines[id] else { throw ConnectedRecipeError.noEngine(unavailable[id]) }
        guard let token = policy.register(accountID: id, label: "list folders", cancel: {}) else {
            throw ConnectedRecipeError.notPermitted(String(localized: "Mail is switched off."))
        }
        defer { policy.finish(token) }
        return try await engine.folderList()
    }

    /// Lists a selection to its end and freezes it (nothing is saved yet).
    func listSelection(_ id: UUID, filter: SelectiveCaptureFilter) async throws -> SelectiveCaptureListing {
        guard let engine = engines[id] else { throw ConnectedRecipeError.noEngine(unavailable[id]) }
        let box = ListingTaskBox()
        guard let token = policy.register(accountID: id, label: "capture preview", cancel: { box.cancel() }) else {
            throw ConnectedRecipeError.notPermitted(String(localized: "Mail is switched off."))
        }
        defer { policy.finish(token) }
        let task = Task { try await engine.listSelection(filter) }
        box.set { task.cancel() }
        return try await task.value
    }

    /// Captures exactly a frozen listing, registered like a sync; the
    /// captured records are indexed and handed to the capture rules.
    func captureListed(_ listing: SelectiveCaptureListing) async -> SyncRunReport? {
        let id = listing.accountID
        guard let engine = engines[id], !running.contains(id) else { return nil }
        running.insert(id)
        let box = CaptureTaskBox()
        guard let token = policy.register(accountID: id, label: "selective capture", cancel: { box.cancel() }) else {
            endRun(id)
            return nil
        }
        let ticker = progressTicker(id)
        let task = Task { await engine.captureListed(listing) }
        box.set(task)
        let report = await task.value
        ticker.cancel()
        policy.finish(token)
        await feed.flush()
        await applyCaptureRules()
        if case .alreadyRunning = report.outcome {
            endRun(id)
            return nil
        }
        lastReports[id] = report
        if case .needsSignIn = report.outcome {
            try? await registry.setState(.needsReauthorisation, account: id)
        }
        endRun(id)
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return report
    }

    /// Why this account may not change server mail now, or nil. Never
    /// touches the network.
    func serverChangeRefusal(_ id: UUID) async -> String? {
        guard let account = try? await registry.account(id) else { return MailNetworkRefusal.noAccount.explanation }
        guard account.enabledModes.contains(.serverActions) else {
            return String(localized: "This account is not allowed to change server mail. Turn on Change server mail for it in Mail settings first.")
        }
        guard account.connectionState == .connected else {
            return String(localized: "Account needs sign-in; saved mail remains available.")
        }
        if let refusal = Self.serverChangeRefusal(policy: policy, account: id) { return refusal.explanation }
        return nil
    }

    nonisolated static func serverChangeRefusal(policy: MailNetworkPolicy, account id: UUID) -> MailNetworkRefusal? {
        guard let host = policy.account(id)?.mailHosts.first else { return policy.isMailEnabled ? .noAccount : .mailOff }
        return policy.wouldPermit(MailNetworkRequest(accountID: id, host: host, destination: .mailServer,
                                                     operation: .request, purpose: .changeServerMail))
    }

    /// The journalled server-action service of one account, or the reason
    /// there is none. Built only after the permission check passed.
    func actionService(_ id: UUID, journal: RemoteOperationJournal) async throws -> RemoteActionService {
        if let why = await serverChangeRefusal(id) { throw ConnectedRecipeError.notPermitted(why) }
        let account = try await registry.account(id)
        let context = ConnectedAdapterContext(account: account, credentials: deps.credentials, tokens: deps.tokens,
                                              permission: Self.permission(policy: policy, purpose: .changeServerMail))
        guard let executor = try await deps.actionExecutors(context) else {
            throw ConnectedRecipeError.notPermitted(String(localized: "This edition cannot change mail on this account's server."))
        }
        let policy = self.policy
        return RemoteActionService(account: account, executor: executor, journal: journal, changePermission: { id in
            if let refusal = Self.serverChangeRefusal(policy: policy, account: id) { throw refusal }
        })
    }

    // MARK: Accounts

    /// Switches saving mail for one account on or off. Off cancels its
    /// running capture at once; saved mail is untouched.
    func setCaptureEnabled(_ enabled: Bool, account id: UUID) async throws {
        var account = try await registry.account(id)
        if enabled { account.enabledModes.insert(.capture) } else { account.enabledModes.remove(.capture) }
        try await registry.save(account)
        try await reloadAccounts()
    }

    /// Removes the account: secrets deleted, engine stopped, the policy
    /// forgets it. Preserved messages, folders, provenance, search and
    /// exports stay (§7 account removal, T21).
    func removeAccount(_ id: UUID) async throws {
        policy.removeAccount(id)
        engines[id] = nil
        cancelRetry(id)
        try await registry.remove(id)
        try await reloadAccounts()
    }

    /// The four kinds of completeness for one account (§5.4).
    func status(of id: UUID) async throws -> CaptureStatus? {
        guard let engine = engines[id] else { return nil }
        let sink = self.sink
        return try await engine.status(searchCoverage: { account in
            guard SearchChunkPolicy.isEnabled, let c = try? await sink.searchCounts(accountID: account) else { return nil }
            return MailConnectivity.SearchCoverageSnapshot(
                bodiesIndexed: c.bodiesEvaluable, bodiesPending: max(0, c.messages - c.bodiesEvaluable),
                attachmentsIndexed: c.attachmentsEvaluable,
                attachmentsPending: max(0, c.attachments - c.attachmentsEvaluable - c.attachmentsUnavailable),
                attachmentsUnavailable: c.attachmentsUnavailable)
        })
    }

    // MARK: Policy glue

    /// Account modes → the policy's permission modes.
    nonisolated static func networkModes(_ modes: Set<MailAccount.Mode>) -> Set<MailAccountMode> {
        Set(modes.map { mode -> MailAccountMode in
            switch mode {
            case .capture: return .preserveMail
            case .send: return .sendMail
            case .serverActions: return .changeServerMail
            }
        })
    }

    /// The engine's network question, asked of the mail policy (purpose:
    /// preserve mail). A refusal stops the account's sync without a retry.
    nonisolated static func permission(policy: MailNetworkPolicy, purpose: MailAccountMode = .preserveMail) -> NetworkPermission {
        { ask in
            let operation: MailNetworkOperation
            switch ask.operation {
            case .request: operation = .request
            case .download: operation = .download
            case .retry: operation = .retry
            case .oauthRefresh: operation = .oauthRefresh
            }
            try policy.permit(MailNetworkRequest(
                accountID: ask.accountID, host: ask.host,
                destination: ask.destination == .authorization ? .authorization : .mailServer,
                operation: operation, purpose: purpose))
        }
    }

    // MARK: Process wiring

    /// Called by `CapabilityWiring` with the resolved `connectedMail` state.
    /// On: the runtime is created (once) and starts; off: it stops and goes
    /// away (the policy has already cancelled its registered work). A build
    /// without the mail transports never creates it.
    static func capabilityChanged(isOn: Bool) {
        guard ConnectedBuildFeatures.mailTransportsCompiled else { return }
        if isOn {
            guard shared == nil, let deps = makeProductionDependencies() else { return }
            let runtime = ConnectedMailRuntime(dependencies: deps)
            runtime.rules = CaptureRuleEngine.production(store: deps.store)
            shared = runtime
            Task { @MainActor in
                do {
                    try await runtime.start()
                    // REC-07: arrivals a rule has not decided yet (an earlier
                    // indexing failure, a crash) — the ledger keeps it once-only.
                    _ = await runtime.rules?.catchUp()
                    await runtime.syncAll()
                } catch {
                    log.error("connected mail did not start: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            shared?.stop()
            shared = nil
        }
    }

    /// A3 / A08: what the legacy connector screens call instead of inserting
    /// fetched messages. Returns false when no runtime runs.
    static func requestCaptureOfAllAccounts() async -> Bool {
        guard let runtime = shared else { return false }
        await runtime.syncAll()
        return true
    }

    /// After captured records were indexed: the same follow-ups an import makes.
    static func afterIndexInApp(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        _ = try? await ArchiveCorpusRevision.shared.bump()
        AttachmentTextIndexJob.shared.kickIfNeeded()
        NotificationCenter.default.post(name: .parsingFinished, object: nil)
    }

    static func makeProductionDependencies() -> Dependencies? {
        #if MAILIN_CONNECTED_MAIL && !NO_NETWORK_BUILD
        return ConnectedMailProduction.dependencies()
        #else
        return nil
        #endif
    }
}

/// Holds a capture task so the policy's cancel handler can reach it, even
/// when the cancel arrives before the task exists.
private final class CaptureTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<SyncRunReport, Never>?
    private var cancelled = false

    func cancel() {
        let current: Task<SyncRunReport, Never>? = lock.withLock { cancelled = true; return task }
        current?.cancel()
    }

    func set(_ task: Task<SyncRunReport, Never>) {
        let wasCancelled: Bool = lock.withLock { self.task = task; return cancelled }
        if wasCancelled { task.cancel() }
    }
}

// MARK: - Production adapters (the only part that reaches the network)

#if MAILIN_CONNECTED_MAIL && !NO_NETWORK_BUILD
enum ConnectedMailProduction {

    /// Info.plist keys holding the owner's registered client IDs (V4-14).
    /// Missing or placeholder values leave Gmail / Outlook accounts without
    /// an engine, with the reason shown — never a request with a fake client.
    static let gmailClientIDKey = "MailinGmailClientID"
    static let graphClientIDKey = "MailinGraphClientID"
    static let graphRedirectKey = "MailinGraphRedirectURI"

    @MainActor
    static func dependencies() -> ConnectedMailRuntime.Dependencies {
        let credentials = KeychainCredentialStore()
        // A refused refresh during a send or server action marks the account
        // "Sign in again", as a refused refresh during capture does.
        let tokens = TokenRefreshCoordinator(credentials: credentials,
                                             transport: PolicyCheckedTokenTransport(policy: .shared),
                                             onReauthorisationNeeded: ConnectedMailRuntime.reauthorisationHandler)
        return ConnectedMailRuntime.Dependencies(
            store: .shared, fts: .shared, policy: .shared, credentials: credentials, tokens: tokens,
            adapters: { context in try await adapter(context) },
            afterIndex: { ids in await ConnectedMailRuntime.afterIndexInApp(ids) },
            actionExecutors: { context in try actionExecutor(context) })
    }

    /// REC-07 / V4-11: the account's server-action executor. Its requests ask
    /// the policy with purpose "change server mail" (the context's permission).
    static func actionExecutor(_ c: ConnectedAdapterContext) throws -> (any RemoteActionExecutor)? {
        switch c.account.provider {
        case .gmail:
            guard let tokens = c.tokens else { return nil }
            return GmailActionExecutor(accountID: c.account.id, tokens: tokens, transport: NoRedirectSendHTTPTransport(),
                                       permission: c.permission)
        case .microsoftGraph:
            guard let tokens = c.tokens else { return nil }
            return GraphActionExecutor(accountID: c.account.id, tokens: tokens, transport: NoRedirectSendHTTPTransport(),
                                       permission: c.permission)
        case .imap:
            // No Trash mailbox is assumed: without one, Move to Trash is
            // refused with its reason (never a mailbox-wide EXPUNGE).
            let adapter = try IMAPAdapter(account: c.account, credentials: c.credentials, permission: c.permission)
            return IMAPActionExecutor(adapter: adapter, trashMailbox: nil, permission: c.permission)
        }
    }

    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }

    static func adapter(_ c: ConnectedAdapterContext) async throws -> (any MailProviderAdapter)? {
        switch c.account.provider {
        case .gmail:
            let configuration = try GmailOAuth.configuration(clientID: info(gmailClientIDKey))
            await c.tokens?.register(account: c.account.id, configuration: configuration)
            return GmailAdapter(accountID: c.account.id, transport: URLSessionGmailTransport(), permission: c.permission)
        case .microsoftGraph:
            guard let redirect = URL(string: info(graphRedirectKey)) else {
                throw GraphConfigurationError.placeholderClientID(info(graphClientIDKey))
            }
            let settings = GraphSignInSettings(clientID: info(graphClientIDKey), tenant: c.account.tenant ?? "common",
                                               redirectURI: redirect)
            // V4-13: Graph refreshes name their scopes, so the refresh asks
            // for every Graph scope the person granted (Mail.Send,
            // Mail.ReadWrite after a re-consent) — never fewer, never more.
            var configuration = try GraphOAuth.configuration(settings)
            let resource = GraphAudience.resource()
            for scope in c.account.grantedScopes where scope.hasPrefix(resource + "/") && !configuration.scopes.contains(scope) {
                configuration.scopes.insert(scope, at: 0)
            }
            await c.tokens?.register(account: c.account.id, configuration: configuration)
            return GraphAdapter(accountID: c.account.id, transport: URLSessionGraphTransport(), permission: c.permission)
        case .imap:
            return try IMAPAdapter(account: c.account, credentials: c.credentials, permission: c.permission)
        }
    }
}

/// The token endpoint transport: POST only, ephemeral session, no redirect
/// followed, and only to a sign-in host an enabled account was granted in
/// the mail policy (the engine also asks before every refresh).
final class PolicyCheckedTokenTransport: NSObject, TokenTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: MailNetworkPolicy
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(policy: MailNetworkPolicy) { self.policy = policy }

    struct Refused: LocalizedError {
        var errorDescription: String? { String(localized: "The server is not one this account uses.") }
    }

    func postForm(_ url: URL, body: Data) async throws -> (status: Int, body: Data) {
        let snapshot = policy.snapshot()
        let host = MailNetworkPolicy.normalized(url.host ?? "")
        guard snapshot.isMailEnabled, url.scheme?.lowercased() == "https",
              snapshot.accounts.contains(where: { $0.isEnabled && $0.authorizationHosts.contains { MailNetworkPolicy.normalized($0) == host } })
        else { throw Refused() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(FormURLEncoding.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
#endif
