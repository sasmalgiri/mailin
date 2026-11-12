@testable import ArchiveCore
import MailConnectivity
//
//  MailWorkspaceBackend.swift
//  maxmailin
//
//  Plan v4 V4-13: the production `MailWorkspaceBackend` — the Mail
//  workspace's one door into connected mail. It exists only while the
//  `ConnectedMailRuntime` runs (connected build, Connected mail on); the
//  offline build gets `UnavailableMailBackend(.notInThisEdition)` and shows
//  the honest state.
//
//  It owns, per runtime: the draft store, the durable outbox (with the
//  lifecycle admission check and a small driver that submits due items),
//  the remote-operation journal, the lifecycle ledger and the account
//  removal coordinator. Nothing here opens a connection: the transports
//  (sign-in, submitters, server-action executors) come from
//  `ConnectedMailTransports`, which only the connected build compiles.
//

import CryptoKit
import Foundation
import os

/// The network-touching parts, built only in the connected build.
@MainActor
protocol ConnectedMailTransports: AnyObject {
    /// Interactive OAuth sign-in for `accountID` (a new or an existing account).
    func signIn(_ choice: MailProviderChoice, accountID: UUID, extraScopes: [String], info: [String: String],
                policy: MailNetworkPolicy) async throws -> (tokens: OAuthTokenSet, issuer: String, tenant: String?)
    /// Registers the account's send route with the outbox (nil = it cannot send in this build).
    func registerSending(_ account: MailAccount, extras: MailAccountExtras, outbox: Outbox,
                         credentials: any CredentialStore, tokens: TokenRefreshCoordinator?,
                         permission: @escaping NetworkPermission) async
    /// The account's server-action executor (nil = not available for it).
    func actionExecutor(_ account: MailAccount, credentials: any CredentialStore, tokens: TokenRefreshCoordinator?,
                        permission: @escaping NetworkPermission) throws -> (any RemoteActionExecutor)?
}

@MainActor
final class ConnectedMailBackend: MailWorkspaceBackend {
    private static let log = Logger(subsystem: "com.ecosanskriti.mailin", category: "MailWorkspace")

    let runtime: ConnectedMailRuntime
    let draftStore: DraftStore
    let outboxStore: OutboxStore
    let outboxQueue: Outbox
    let journal: RemoteOperationJournal
    let lifecycle: ConnectedLifecycle
    let extras: MailAccountExtrasStore
    let credentials: any CredentialStore
    let tokens: TokenRefreshCoordinator?
    let transports: ConnectedMailTransports?
    let providerInfo: [String: String]
    private var driver: Task<Void, Never>?

    var availability: MailWorkspaceAvailability {
        ConnectedMailRuntime.shared === runtime ? .ready : .mailSwitchedOff
    }

    init(runtime: ConnectedMailRuntime, storeDirectory: URL, credentials: any CredentialStore,
         tokens: TokenRefreshCoordinator?, transports: ConnectedMailTransports?,
         extras: MailAccountExtrasStore = MailAccountExtrasStore(),
         providerInfo: [String: String] = MailProviderChoice.bundleInfo()) throws {
        self.runtime = runtime
        self.credentials = credentials
        self.tokens = tokens
        self.transports = transports
        self.extras = extras
        self.providerInfo = providerInfo
        draftStore = try DraftStore(storeDirectory: storeDirectory)
        outboxStore = try OutboxStore(storeDirectory: storeDirectory)
        journal = try RemoteOperationJournal(storeDirectory: storeDirectory)
        // v4.0 adds no purchase product (owner, 2026-11-09): no connected
        // activity is treated as paid, so the plan never pauses one.
        lifecycle = try ConnectedLifecycle(storeDirectory: storeDirectory,
                                           entitlement: { ConnectedEntitlement(plan: .active, paidActivities: []) },
                                           drive: try? ArchiveDriveIdentity.of(storeDirectory: storeDirectory))
        outboxQueue = Outbox(store: outboxStore, permission: Self.permission(policy: runtime.policy, purpose: .sendMail))
    }

    // MARK: Process wiring

    private static var cached: ConnectedMailBackend?

    /// The backend for the page right now.
    static func current() -> MailWorkspaceBackend {
        guard ConnectedBuildFeatures.mailTransportsCompiled else { return UnavailableMailBackend(.notInThisEdition) }
        guard let runtime = ConnectedMailRuntime.shared else {
            cached?.stop(); cached = nil
            return UnavailableMailBackend(.mailSwitchedOff)
        }
        if let cached, cached.runtime === runtime { return cached }
        cached?.stop()
        do {
            let backend = try ConnectedMailBackend(runtime: runtime, storeDirectory: SQLiteEmailStore.shared.storeDirectory,
                                                   credentials: runtime.credentials, tokens: runtime.tokens,
                                                   transports: makeTransports())
            cached = backend
            backend.start()
            return backend
        } catch {
            log.error("mail workspace did not start: \(error.localizedDescription, privacy: .public)")
            return UnavailableMailBackend(.mailSwitchedOff)
        }
    }

    static func makeTransports() -> ConnectedMailTransports? {
        #if MAILIN_CONNECTED_MAIL && !NO_NETWORK_BUILD
        return ConnectedMailProductionTransports()
        #else
        return nil
        #endif
    }

    /// Installs the lifecycle admission check, registers send routes and
    /// starts the outbox driver (due items, every few seconds, while Mail runs).
    func start() {
        let outbox = outboxQueue
        let lifecycle = self.lifecycle
        driver = Task { @MainActor [weak self] in
            await outbox.setAdmission(lifecycle.outboxAdmission)
            _ = try? await outbox.recoverAfterRestart()
            await self?.registerSendRoutes()
            while !Task.isCancelled {
                guard let self, self.availability == .ready else { return }
                _ = try? await outbox.runDue()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() {
        driver?.cancel()
        driver = nil
    }

    private func registerSendRoutes() async {
        guard let transports, let accounts = try? await runtime.registry.accounts() else { return }
        for account in accounts where account.enabledModes.contains(.send) && account.connectionState == .connected {
            await transports.registerSending(account, extras: extras.extras(account.id), outbox: outboxQueue,
                                             credentials: credentials, tokens: tokens,
                                             permission: Self.permission(policy: runtime.policy, purpose: .sendMail))
        }
    }

    /// The policy question for sending / server changes (the capture one is the runtime's).
    nonisolated static func permission(policy: MailNetworkPolicy, purpose: MailAccountMode) -> NetworkPermission {
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

    // MARK: Accounts

    func accounts() async throws -> [MailAccountSnapshot] {
        var out: [MailAccountSnapshot] = []
        for account in try await runtime.registry.accounts() {
            let status = try? await runtime.status(of: account.id)
            out.append(MailAccountSnapshot(account: account, status: status, unavailableReason: runtime.unavailable[account.id],
                                           isPaused: runtime.paused.contains(account.id),
                                           lastRunSummary: runtime.lastReports[account.id].map(Self.runSummary)))
        }
        return out
    }

    static func runSummary(_ r: SyncRunReport) -> String {
        let when = r.endedAt.formatted(date: .abbreviated, time: .shortened)
        if let receipt = r.receipt {
            return String(localized: "Last run \(when): \(receipt.stored) new, \(receipt.alreadyPreserved) already saved, \(receipt.failed) failed, \(receipt.pending) still to fetch (\(r.selection))")
        }
        return String(localized: "Last run \(when) did not start")
    }

    func addIMAP(_ form: MailIMAPForm) async throws -> UUID {
        if let problem = form.problem { throw MailWorkspaceError(problem) }
        let account = MailOnboarding.newAccount(form)
        try await runtime.registry.add(account, secret: Data(form.password.utf8), kind: .password)
        var e = extras.extras(account.id)
        let smtpHost = form.smtpHost.trimmingCharacters(in: .whitespaces).lowercased()
        if !smtpHost.isEmpty, let port = Int(form.smtpPort) {
            e.smtp = .init(host: smtpHost, port: port, implicitTLS: port == 465)
        }
        extras.save(e, for: account.id)
        _ = extras.identities(for: account)
        try await runtime.reloadAccounts()
        return account.id
    }

    func signIn(_ choice: MailProviderChoice, address: String, existing: UUID?, extraScopes: [String]) async throws -> UUID {
        guard case .ready = choice.readiness(info: providerInfo) else { throw MailWorkspaceError(MailProviderChoice.notConfiguredReason(choice)) }
        guard let transports else { throw MailBackendUnavailable() }
        let id = existing ?? UUID()
        if existing == nil, (try? MailAddress(parsing: address.trimmingCharacters(in: .whitespaces))) == nil {
            throw MailWorkspaceError(String(localized: "Enter your email address."))
        }
        // A re-consent asks again for every scope the account already holds, so
        // asking for Change server mail never drops Send (the provider's answer
        // replaces the stored scopes below).
        var requested = extraScopes
        if let existing, let account = try? await runtime.registry.account(existing) {
            requested = Self.reconsentScopes(granted: account.grantedScopes, provider: account.provider, adding: extraScopes)
        }
        let result: (tokens: OAuthTokenSet, issuer: String, tenant: String?)
        do {
            result = try await transports.signIn(choice, accountID: id, extraScopes: requested, info: providerInfo, policy: runtime.policy)
        } catch {
            if existing == nil { runtime.policy.removeAccount(id) }
            try? await runtime.reloadAccounts()
            throw error
        }
        let secret = try result.tokens.encoded()
        if let existing {
            var account = try await runtime.registry.account(existing)
            try await runtime.registry.updateSecret(secret, kind: .oauthTokenSet, account: existing)
            account.grantedScopes = result.tokens.scopes
            account.connectionState = .connected
            try await runtime.registry.save(account)
            try? await tokens?.store(result.tokens)
        } else {
            let account = MailOnboarding.newOAuthAccount(id: id, provider: choice.provider, issuer: result.issuer, tenant: result.tenant,
                                                         address: address, scopes: result.tokens.scopes)
            try await runtime.registry.add(account, secret: secret, kind: .oauthTokenSet)
            _ = extras.identities(for: account)
        }
        try await runtime.reloadAccounts()
        await registerSendRoutes()
        return id
    }

    /// The scopes a re-consent requests: the account's own mail scopes for its
    /// provider (Gmail API scopes; Graph resource scopes) plus `adding`, once each.
    /// Sign-in housekeeping scopes (offline_access, openid) come from the
    /// provider configuration, not from here.
    nonisolated static func reconsentScopes(granted: [String], provider: MailProviderKind, adding: [String]) -> [String] {
        let kept = granted.filter { scope in
            switch provider {
            case .gmail: return scope.hasPrefix("https://www.googleapis.com/auth/gmail.") || scope == ServerActionScopes.gmailFullAccess
            case .microsoftGraph: return scope.hasPrefix(GraphAudience.resource() + "/")
            case .imap: return false
            }
        }
        var out: [String] = []
        for scope in kept + adding where !out.contains(scope) { out.append(scope) }
        return out
    }

    func setMode(_ mode: MailAccount.Mode, enabled: Bool, account id: UUID) async throws {
        var account = try await runtime.registry.account(id)
        if enabled { account.enabledModes.insert(mode) } else { account.enabledModes.remove(mode) }
        try await runtime.registry.save(account)
        try await runtime.reloadAccounts()
        if mode == .send, enabled { await registerSendRoutes() }
    }

    func syncNow(_ account: UUID) async { await runtime.sync(account) }

    func setPaused(_ paused: Bool, account: UUID) async throws { try await runtime.setPaused(paused, account: account) }

    func folders(_ account: UUID) async throws -> [ConnectedFolderSummary] {
        try await runtime.sink.folderSummaries(accountID: account)
    }

    func setFolderSelected(_ serverID: String, selected: Bool, account: UUID) async throws {
        try await runtime.sink.setFolderSelected(accountID: account, serverID: serverID, selected: selected)
    }

    // MARK: Removal

    private var removal: AccountRemovalCoordinator {
        AccountRemovalCoordinator(registry: runtime.registry, sink: runtime.sink, outbox: outboxQueue, drafts: draftStore,
                                  lifecycle: lifecycle, tasks: RuntimeTaskControl(runtime: runtime))
    }

    func removalPlan(_ account: UUID) async throws -> AccountRemovalPlan { try await removal.plan(account) }

    func remove(_ account: UUID) async throws -> AccountRemovalReport {
        let report = try await removal.remove(account)
        try await runtime.reloadAccounts()
        return report
    }

    func archiveDeletionPlan(_ account: UUID) async throws -> ConnectedAccountArchiveSummary {
        try await removal.planArchiveDeletion(account)
    }

    func deleteArchivedMail(_ account: UUID, confirmedCount: Int) async throws -> ConnectedAccountArchiveDeletion {
        let result = try await removal.deleteArchivedMail(account, confirmedCount: confirmedCount)
        if !result.deletedEmailIDs.isEmpty {
            for id in result.deletedEmailIDs { try? await FTSSearchIndex.shared.delete(id: id) }
            NotificationCenter.default.post(name: .parsingFinished, object: nil)
        }
        return result
    }

    // MARK: Mailbox

    func mailbox(_ query: ConnectedMailboxQuery, after: ConnectedMailboxCursor?) async throws -> ConnectedMailboxPage {
        try await runtime.sink.mailboxPage(query, after: after)
    }

    func email(_ id: UUID) async throws -> MBOXParser.RawEmail? {
        try await SQLiteEmailStore.shared.emails(withIDs: [id]).first
    }

    func changeOnServer(_ request: RemoteChangeRequest, row: ConnectedMailboxRow) async throws -> RemoteOperation {
        let account = try await runtime.registry.account(row.accountID)
        let policy = runtime.policy
        let permission = lifecycle.serverActionPermission(Self.permission(policy: policy, purpose: .changeServerMail))
        guard let executor = try transports?.actionExecutor(account, credentials: credentials, tokens: tokens, permission: permission) else {
            throw MailWorkspaceError(String(localized: "This account cannot change mail on the server in this build."))
        }
        let service = RemoteActionService(account: account, executor: executor, journal: journal, changePermission: { id in
            guard policy.account(id)?.modes.contains(.changeServerMail) == true else { throw MailNetworkRefusal.modeNotGranted }
        })
        return try await service.perform(row.identity, request, emailID: row.emailID)
    }

    // MARK: Drafts

    func identities(_ account: UUID) async -> [SendingIdentity] {
        guard let a = try? await runtime.registry.account(account) else { return extras.extras(account).identities }
        return extras.identities(for: a)
    }

    func drafts() async -> DraftListing { await draftStore.drafts() }
    func createDraft(_ seed: DraftSeed) async throws -> Draft { try await draftStore.create(seed) }
    func saveDraft(_ draft: Draft) async throws -> Draft { try await draftStore.save(draft) }
    func discardDraft(_ id: UUID) async throws { try await draftStore.discard(id) }

    func attachmentAvailability(_ attachment: DraftAttachment, draft: UUID) async -> DraftAttachmentAvailability {
        await draftStore.availability(of: attachment, in: draft)
    }

    func addAttachment(_ file: URL, to draft: Draft) async throws -> Draft {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        return try await draftStore.addAttachment(copying: file, to: draft)
    }

    func archivedSource(_ emailID: UUID) async throws -> ArchivedMessageSource {
        guard let email = try await SQLiteEmailStore.shared.emails(withIDs: [emailID]).first else {
            throw MailWorkspaceError(String(localized: "The archived message is no longer in the archive."))
        }
        let raw = try await ArchiveDataService.shared.rawMessageData(for: email)
        return ArchivedMessageSource(raw: raw)
    }

    func queue(_ draft: Draft, undoDelay: TimeInterval) async throws -> OutboxOperation {
        let account = try await runtime.registry.account(draft.accountID)
        let identities = extras.identities(for: account)
        let composed = try await draftStore.compose(draft.id, account: account, identities: identities, date: Date())
        let route: OutboxRoute
        switch account.provider {
        case .gmail: route = .gmailAPI
        case .microsoftGraph: route = .graphAPI
        case .imap: route = .smtp(appendToSent: false)
        }
        await registerSendRoutes()
        return try await outboxQueue.enqueue(composed, draft: draft, route: route, undoDelay: undoDelay)
    }

    // MARK: Outbox

    func outbox() async throws -> [OutboxOperation] { try await outboxQueue.operations() }

    func outboxHolds() async -> [UUID: OutboxHoldReason] {
        var held = await outboxQueue.heldOperations()
        for (id, why) in lifecycle.pendingDecisions() { held[id] = why }
        return held
    }

    func cancelSend(_ id: UUID) async throws { try await outboxQueue.cancel(id) }
    func checkSent(_ id: UUID) async throws { try await outboxQueue.reconcile(id) }
    func resendAnyway(_ id: UUID) async throws { try await outboxQueue.resendAfterUncertainty(id) }
    func retryNow(_ id: UUID) async throws { try await outboxQueue.retryNow(id) }
    func sendHeldNow(_ id: UUID) async throws { try lifecycle.release(id) }
    func keepHeldAsDraft(_ id: UUID) async throws { try await lifecycle.keepAsDraft(id, outbox: outboxQueue) }

    // MARK: Safe cleanup

    private func cleanupChecks(_ accountID: UUID) async -> CleanupSafetyChecks {
        let sink = runtime.sink
        let held = (try? await SQLiteEmailStore.shared.legalHoldIDs()) ?? []
        let unreadable = Set(((try? await sink.unreadableCaptures(accountID: accountID)) ?? []).compactMap { try? $0.identity.key() })
        let verifier = ConnectedArchiveCopyVerifier(sink: sink, rehash: { emailID, _ in
            guard let bytes = try await SQLiteEmailStore.shared.rawBytes(id: emailID) else { return nil }
            let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return (hex, Int64(bytes.count))
        })
        return CleanupSafetyChecks(
            archive: verifier,
            hold: { emailID, _ in
                guard let emailID, held.contains(emailID) else { return nil }
                return String(localized: "legal hold")
            },
            captureFailure: { identity in
                guard let key = try? identity.key(), unreadable.contains(key) else { return nil }
                return String(localized: "the saved copy could not be read")
            },
            independentCopy: nil)
    }

    func planCleanup(_ rows: [ConnectedMailboxRow], action: CleanupAction, account accountID: UUID) async throws -> CleanupPlan {
        let account = try await runtime.registry.account(accountID)
        let candidates = rows.map { row in
            CleanupCandidate(accountID: row.accountID, identity: row.identity, emailID: row.emailID,
                             folder: row.folderServerIDs.first ?? "")
        }
        return await SafeCleanup.plan(candidates, action: action, account: account, checks: await cleanupChecks(accountID))
    }

    func runCleanup(_ plan: CleanupPlan, confirmation: CleanupConfirmation) async throws -> CleanupReceipt {
        let account = try await runtime.registry.account(plan.accountID)
        let policy = runtime.policy
        let permission = lifecycle.serverActionPermission(Self.permission(policy: policy, purpose: .changeServerMail))
        guard let executor = try transports?.actionExecutor(account, credentials: credentials, tokens: tokens, permission: permission) else {
            throw MailWorkspaceError(String(localized: "This account cannot change mail on the server in this build."))
        }
        let service = RemoteActionService(account: account, executor: executor, journal: journal, changePermission: { id in
            guard policy.account(id)?.modes.contains(.changeServerMail) == true else { throw MailNetworkRefusal.modeNotGranted }
        })
        return try await SafeCleanup.execute(plan, confirmation: confirmation, service: service, checks: await cleanupChecks(plan.accountID))
    }

    // MARK: Upgrade inventory

    func legacyCredentials() -> [LegacyCredential] {
        (try? LegacyCredentialInventory().unassigned()) ?? []
    }

    func assignLegacy(_ items: [LegacyCredential], to accountID: UUID) async throws {
        let account = try await runtime.registry.account(accountID)
        let audience: String
        switch account.provider {
        case .gmail: audience = GmailOAuth.audience
        case .microsoftGraph: audience = GraphAudience.resource()
        case .imap: audience = ""
        }
        try LegacyCredentialInventory().assign(items, to: account,
                                               confirmation: LegacyAssignmentConfirmation(accountID: accountID, keys: Set(items.map(\.key))),
                                               into: credentials, audience: audience)
        if account.connectionState == .needsReauthorisation { try await runtime.registry.setState(.connected, account: accountID) }
        try await runtime.reloadAccounts()
    }

    func legacyRecaptures() async throws -> [LegacyOnlineCapture] {
        let box = LegacyCaptureBox()
        _ = try await LegacyRecapturePlanner(sink: runtime.sink, lifecycle: lifecycle).inventory { box.add($0) }
        return box.items
    }

    func compareRecapture(_ old: LegacyOnlineCapture, account accountID: UUID) async throws -> LegacyRecaptureComparison {
        let account = try await runtime.registry.account(accountID)
        return try await LegacyRecapturePlanner(sink: runtime.sink, lifecycle: lifecycle).compare(old, account: account)
    }
}

struct MailWorkspaceError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

private final class LegacyCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [LegacyOnlineCapture] = []
    func add(_ item: LegacyOnlineCapture) { lock.withLock { list.append(item) } }
    var items: [LegacyOnlineCapture] { lock.withLock { list } }
}

/// The removal coordinator's handle on the account's running work: the
/// runtime stops its engine and the policy cancels everything registered.
private struct RuntimeTaskControl: AccountTaskControl {
    let runtime: ConnectedMailRuntime
    func cancelTasks(account: UUID) async -> Int {
        await MainActor.run { runtime.stopAccount(account) }
    }
}
