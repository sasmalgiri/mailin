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
    private(set) var indexed = 0
    private(set) var lastError: String?

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
        var scheduler = FairDownloadScheduler()
        var backoff = BackoffPolicy()
        var storage = StorageProbe()
    }

    nonisolated static let didChange = Notification.Name("ConnectedMailRuntime.didChange")
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
            guard account.connectionState == .connected, account.enabledModes.contains(.capture) else {
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
                let context = ConnectedAdapterContext(account: account, credentials: deps.credentials,
                                                      tokens: deps.tokens, permission: permission)
                guard let adapter = try await deps.adapters(context) else {
                    disable(account.id, reason: String(localized: "This edition has no mail connection code."))
                    continue
                }
                policy.setAccount(MailAccountNetworkPolicy(
                    id: account.id, isEnabled: true, modes: Self.networkModes(account.enabledModes),
                    mailHosts: [adapter.mailHost], authorizationHosts: adapter.authorizationHost.map { [$0] } ?? []))
                if engines[account.id] == nil {
                    engines[account.id] = SyncEngine(adapter: adapter, sink: sink, scheduler: deps.scheduler,
                                                     tokens: deps.tokens, permission: permission,
                                                     backoff: deps.backoff, storage: deps.storage)
                }
                unavailable[account.id] = nil
            } catch {
                disable(account.id, reason: error.localizedDescription)
            }
        }
        for id in Array(engines.keys) where !seen.contains(id) { disable(id, reason: nil) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func disable(_ id: UUID, reason: String?) {
        engines[id] = nil
        if let reason {
            unavailable[id] = reason
            policy.setAccount(MailAccountNetworkPolicy(id: id))   // off, no modes: cancels its work
        } else {
            unavailable[id] = nil
            policy.removeAccount(id)
        }
    }

    /// Stops every capture of this process (Mail switched off).
    func stop() {
        for id in Array(engines.keys) { policy.removeAccount(id) }
        engines.removeAll()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: Capture

    /// One capture run of one account, registered with the policy's
    /// cancellation registry. Nil when the account has no engine or the
    /// policy refuses the work (Mail or the account off).
    @discardableResult
    func sync(_ id: UUID, selection: SyncSelection = .allFolders) async -> SyncRunReport? {
        guard let engine = engines[id] else { return nil }
        let box = CaptureTaskBox()
        guard let token = policy.register(accountID: id, label: "capture", cancel: { box.cancel() }) else { return nil }
        let task = Task { await engine.sync(selection) }
        box.set(task)
        let report = await task.value
        policy.finish(token)
        await feed.flush()
        lastReports[id] = report
        if case .needsSignIn = report.outcome {
            // A revoked grant: the account says so; its saved mail stays usable.
            try? await registry.setState(.needsReauthorisation, account: id)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return report
    }

    /// Every account with an engine, concurrently (fairness is the scheduler's).
    @discardableResult
    func syncAll(selection: SyncSelection = .allFolders) async -> [UUID: SyncRunReport] {
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
    nonisolated static func permission(policy: MailNetworkPolicy) -> NetworkPermission {
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
                operation: operation, purpose: .preserveMail))
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
            shared = runtime
            Task { @MainActor in
                do {
                    try await runtime.start()
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
        let tokens = TokenRefreshCoordinator(credentials: credentials,
                                             transport: PolicyCheckedTokenTransport(policy: .shared))
        return ConnectedMailRuntime.Dependencies(
            store: .shared, fts: .shared, policy: .shared, credentials: credentials, tokens: tokens,
            adapters: { context in try await adapter(context) },
            afterIndex: { ids in await ConnectedMailRuntime.afterIndexInApp(ids) })
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
            await c.tokens?.register(account: c.account.id, configuration: try GraphOAuth.configuration(settings))
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
