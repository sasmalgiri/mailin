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
    /// The mailbox address the provider states for the signed-in account
    /// (Gmail: users.getProfile; Microsoft Graph: `/me` with User.Read). Nil =
    /// the provider was not asked or did not say.
    func confirmedAddress(_ choice: MailProviderChoice, accountID: UUID, tokens: OAuthTokenSet,
                          policy: MailNetworkPolicy) async -> String?
    /// Before an IMAP account (or its new password) is saved: one IMAP session
    /// (login, list, logout) and, when `smtp` is set, one SMTP session up to
    /// AUTH. Throws the reason when either server refuses; saves nothing.
    func verifyLogin(_ account: MailAccount, password: String, smtp: MailAccountExtras.SMTP?,
                     policy: MailNetworkPolicy) async throws
    /// The account's server-action executor, with the IMAP Trash folder the server listed.
    func actionExecutor(_ account: MailAccount, credentials: any CredentialStore, tokens: TokenRefreshCoordinator?,
                        permission: @escaping NetworkPermission, trashMailbox: String?) throws -> (any RemoteActionExecutor)?
}

extension ConnectedMailTransports {
    func confirmedAddress(_ choice: MailProviderChoice, accountID: UUID, tokens: OAuthTokenSet,
                          policy: MailNetworkPolicy) async -> String? { nil }
    /// Test transports connect nowhere: the login is not checked.
    func verifyLogin(_ account: MailAccount, password: String, smtp: MailAccountExtras.SMTP?,
                     policy: MailNetworkPolicy) async throws {}
    func actionExecutor(_ account: MailAccount, credentials: any CredentialStore, tokens: TokenRefreshCoordinator?,
                        permission: @escaping NetworkPermission, trashMailbox: String?) throws -> (any RemoteActionExecutor)? {
        try actionExecutor(account, credentials: credentials, tokens: tokens, permission: permission)
    }
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

    /// The runtime started (launch, Connected mail switched on): the backend
    /// and its outbox driver start with it, whether or not Mail is opened.
    static func startForRuntime() {
        _ = current()
    }

    /// Connected mail off, a restore or Delete All Data: the outbox driver
    /// stops and the next `current()` builds a fresh backend (its lifecycle
    /// ledger is read again from disk).
    static func discardCached() {
        cached?.stop()
        cached = nil
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
            var snapshot = MailAccountSnapshot(account: account, status: status, unavailableReason: runtime.unavailable[account.id],
                                               isPaused: runtime.paused.contains(account.id),
                                               lastRunSummary: runtime.lastReports[account.id].map(Self.runSummary))
            snapshot.isRunning = runtime.running.contains(account.id)
            snapshot.nextRetry = runtime.nextRetry[account.id]
            out.append(snapshot)
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

    /// The outgoing server the form names (nil = none entered).
    nonisolated static func smtpSettings(_ form: MailIMAPForm) -> MailAccountExtras.SMTP? {
        let host = form.smtpHost.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty, let port = Int(form.smtpPort) else { return nil }
        return .init(host: host, port: port, implicitTLS: port == 465)
    }

    /// An account that is the same mailbox as `candidate`: the same provider
    /// and address (any case), or for IMAP the same server and login. A
    /// connected match comes first (it refuses the add); otherwise a removed,
    /// signed-out or disconnected one is reconnected under its own id.
    nonisolated static func duplicate(of candidate: MailAccount, among accounts: [MailAccount]) -> MailAccount? {
        func norm(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
        let matches = accounts.filter { other in
            guard other.id != candidate.id, other.provider == candidate.provider else { return false }
            if norm(other.displayIdentity) == norm(candidate.displayIdentity) { return true }
            guard candidate.provider == .imap, !norm(candidate.host).isEmpty, !norm(candidate.loginName).isEmpty else { return false }
            return norm(other.host) == norm(candidate.host) && norm(other.loginName) == norm(candidate.loginName)
        }
        return matches.first { $0.connectionState == .connected } ?? matches.first
    }

    func addIMAP(_ form: MailIMAPForm) async throws -> UUID {
        if let problem = form.problem { throw MailWorkspaceError(problem) }
        var account = MailOnboarding.newAccount(form)
        let smtp = Self.smtpSettings(form)
        // Adding the same mailbox again reconnects its earlier entry (its saved
        // mail is not downloaded again); a connected one is refused.
        let match = Self.duplicate(of: account, among: try await runtime.registry.accounts())
        if let match {
            guard match.connectionState != .connected else { throw MailWorkspaceError(MailLifecycleText.alreadyAdded(match.displayIdentity)) }
            account = MailAccount(id: match.id, provider: .imap, host: account.host, port: account.port, loginName: account.loginName,
                                  displayIdentity: account.displayIdentity,
                                  enabledModes: match.connectionState == .removed ? [] : match.enabledModes,
                                  createdAt: match.createdAt)
        }
        // The password must work before anything is saved.
        try await checkLogin(account, password: form.secret, smtp: smtp)
        try await runtime.registry.add(account, secret: Data(form.secret.utf8), kind: .password)
        if match != nil { try lifecycle.clearAccountRemoved(account.id) }
        var e = extras.extras(account.id)
        e.smtp = smtp
        extras.save(e, for: account.id)
        // The address the person typed: provider presets sign in with it (the
        // login was checked); any other server is not trusted to send as it
        // until the person confirms it is theirs.
        _ = extras.identities(for: account, addressConfirmed: form.choice != .otherIMAP)
        try await runtime.reloadAccounts()
        await registerSendRoutes()
        return account.id
    }

    /// The servers' answer to the password, as a sentence (nothing is saved on a refusal).
    private func checkLogin(_ account: MailAccount, password: String, smtp: MailAccountExtras.SMTP?) async throws {
        guard let transports else { return }
        do {
            try await transports.verifyLogin(account, password: password, smtp: smtp, policy: runtime.policy)
        } catch let refusal as AccountLoginCheckError {
            throw MailWorkspaceError(MailLifecycleText.loginRefused(refusal, gmail: ConnectedMailErrorText.isGmailHost(account.host)))
        }
    }

    /// A new password for an IMAP account that needs sign-in: checked against
    /// the servers first, then stored; the account is connected again.
    func replacePassword(_ password: String, account id: UUID) async throws {
        let account = try await runtime.registry.account(id)
        guard account.provider == .imap else { throw MailWorkspaceError(String(localized: "This account signs in in the browser, not with a password.")) }
        let isGmail = ConnectedMailErrorText.isGmailHost(account.host)
        let secret = isGmail ? password.filter { !$0.isWhitespace } : password
        guard !secret.isEmpty else { throw MailWorkspaceError(String(localized: "Enter the password or app password.")) }
        if isGmail, secret.count != 16 {
            throw MailWorkspaceError(String(localized: "A Google app password has 16 characters. Create one at myaccount.google.com/apppasswords; a normal Google password will be refused."))
        }
        try await checkLogin(account, password: secret, smtp: extras.extras(id).smtp)
        try await runtime.registry.updateSecret(Data(secret.utf8), kind: .password, account: id)
        try await runtime.registry.setState(.connected, account: id)
        try await runtime.reloadAccounts()
        await registerSendRoutes()
    }

    /// The person confirms the typed sending address of an IMAP account is theirs.
    func confirmSendingAddress(_ id: UUID) async throws {
        let account = try await runtime.registry.account(id)
        extras.confirmPrimaryIdentity(of: account)
    }

    func signIn(_ choice: MailProviderChoice, address: String, existing: UUID?, extraScopes: [String]) async throws -> UUID {
        guard case .ready = choice.readiness(info: providerInfo) else { throw MailWorkspaceError(MailProviderChoice.notConfiguredReason(choice)) }
        guard let transports else { throw MailBackendUnavailable() }
        let typed = address.trimmingCharacters(in: .whitespaces)
        var target = existing
        if existing == nil {
            guard (try? MailAddress(parsing: typed)) != nil else { throw MailWorkspaceError(String(localized: "Enter your email address.")) }
            // The same mailbox again: refused while connected, otherwise signed
            // in again under its earlier entry (nothing is downloaded twice).
            let probe = MailAccount(provider: choice.provider, displayIdentity: typed)
            if let match = Self.duplicate(of: probe, among: try await runtime.registry.accounts()) {
                guard match.connectionState != .connected else { throw MailWorkspaceError(MailLifecycleText.alreadyAdded(match.displayIdentity)) }
                target = match.id
            }
        }
        let id = target ?? UUID()
        // A re-consent asks again for every scope the account already holds, so
        // asking for Change server mail never drops Send (the provider's answer
        // replaces the stored scopes below).
        var requested = extraScopes
        if let target, let account = try? await runtime.registry.account(target) {
            requested = Self.reconsentScopes(granted: account.grantedScopes, provider: account.provider, adding: extraScopes)
        }
        let result: (tokens: OAuthTokenSet, issuer: String, tenant: String?)
        do {
            result = try await transports.signIn(choice, accountID: id, extraScopes: requested, info: providerInfo, policy: runtime.policy)
        } catch {
            if target == nil { runtime.policy.removeAccount(id) }
            try? await runtime.reloadAccounts()
            throw error
        }
        // The sending identity is the address the PROVIDER states, never only
        // what was typed (a typed-but-unconfirmed address is never `.verified`).
        let confirmed = await transports.confirmedAddress(choice, accountID: id, tokens: result.tokens, policy: runtime.policy)
            .flatMap { try? MailAddress(parsing: $0) }
        if let target {
            let account = try await runtime.registry.account(target)
            // Signing in again never switches the account to another mailbox.
            if let confirmed, confirmed.addrSpec.lowercased() != account.displayIdentity.lowercased() {
                try? await runtime.reloadAccounts()
                throw MailWorkspaceError(MailLifecycleText.otherMailbox(signedIn: confirmed.addrSpec, account: account.displayIdentity))
            }
            try await reconnect(account, tokens: result.tokens, issuer: result.issuer, tenant: result.tenant, confirmed: confirmed)
        } else if let confirmed,
                  let match = Self.duplicate(of: MailAccount(provider: choice.provider, displayIdentity: confirmed.addrSpec),
                                             among: try await runtime.registry.accounts()) {
            // The provider names a mailbox that is already an account.
            runtime.policy.removeAccount(id)
            guard match.connectionState != .connected else {
                try? await runtime.reloadAccounts()
                throw MailWorkspaceError(MailLifecycleText.alreadyAdded(match.displayIdentity))
            }
            var rekeyed = result.tokens
            rekeyed.accountID = match.id
            try await reconnect(match, tokens: rekeyed, issuer: result.issuer, tenant: result.tenant, confirmed: confirmed)
            try await runtime.reloadAccounts()
            await registerSendRoutes()
            return match.id
        } else {
            let account = MailOnboarding.newOAuthAccount(id: id, provider: choice.provider, issuer: result.issuer, tenant: result.tenant,
                                                         address: confirmed?.addrSpec ?? typed, scopes: result.tokens.scopes)
            try await runtime.registry.add(account, secret: try result.tokens.encoded(), kind: .oauthTokenSet)
            _ = extras.identities(for: account, addressConfirmed: confirmed != nil)
        }
        try await runtime.reloadAccounts()
        await registerSendRoutes()
        return id
    }

    /// Stores new tokens for an existing account (sign in again, re-consent,
    /// or a removed account added again — then with nothing allowed yet).
    private func reconnect(_ existing: MailAccount, tokens newTokens: OAuthTokenSet, issuer: String, tenant: String?,
                           confirmed: MailAddress?) async throws {
        var account = existing
        let wasRemoved = account.connectionState == .removed
        try await runtime.registry.updateSecret(try newTokens.encoded(), kind: .oauthTokenSet, account: account.id)
        account.grantedScopes = newTokens.scopes
        account.connectionState = .connected
        if wasRemoved {
            account.issuer = issuer
            account.tenant = tenant
            account.enabledModes = []
        }
        if let confirmed { account.displayIdentity = confirmed.addrSpec }
        try await runtime.registry.save(account)
        try? await tokens?.store(newTokens)
        if wasRemoved || lifecycle.isRemoved(account.id) { try lifecycle.clearAccountRemoved(account.id) }
        if confirmed != nil { extras.confirmPrimaryIdentity(of: account) } else { _ = extras.identities(for: account, addressConfirmed: false) }
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
        // Switching Preserve mail on starts saving at once (the page says so).
        if mode == .capture, enabled { runtime.startCapture(id) }
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
        // The coordinator waits for the account's running capture to end
        // (RuntimeTaskControl) before anything else changes.
        let report = try await removal.remove(account)
        // Its sending identities and outgoing server go with it; its pause choice too.
        extras.remove(account)
        runtime.forgetPaused(account)
        try await runtime.reloadAccounts()
        return report
    }

    func archiveDeletionPlan(_ account: UUID) async throws -> ConnectedAccountArchiveSummary {
        try await removal.planArchiveDeletion(account)
    }

    /// Search index first, then the archive (the order every delete uses): a
    /// failure in between leaves archive rows the launch reconcile indexes
    /// again, never search results for deleted mail. Any index failure stops
    /// the deletion and is stated.
    func deleteArchivedMail(_ account: UUID, confirmedCount: Int) async throws -> ConnectedAccountArchiveDeletion {
        let summary = try await removal.planArchiveDeletion(account)
        guard summary.deletable == confirmedCount else {
            throw ConnectedLifecycleError.countChanged(shown: confirmedCount, now: summary.deletable)
        }
        let ids = try await runtime.sink.deletableRecordIDs(accountID: account)
        var failed = 0
        for id in ids {
            do { try await runtime.searchIndex.delete(id: id) } catch { failed += 1 }
        }
        if failed > 0 { throw MailWorkspaceError(MailLifecycleText.searchRemovalFailed(failed: failed, total: ids.count)) }
        let result = try await removal.deleteArchivedMail(account, confirmedCount: confirmedCount)
        if !result.deletedEmailIDs.isEmpty { await runtime.afterDelete(result.deletedEmailIDs) }
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
        let trash = await trashMailbox(account.id)
        guard let executor = try transports?.actionExecutor(account, credentials: credentials, tokens: tokens, permission: permission,
                                                            trashMailbox: trash) else {
            throw MailWorkspaceError(String(localized: "This account cannot change mail on the server in this build."))
        }
        let service = RemoteActionService(account: account, executor: executor, journal: journal, changePermission: { id in
            guard policy.account(id)?.modes.contains(.changeServerMail) == true else { throw MailNetworkRefusal.modeNotGranted }
        })
        return try await service.perform(row.identity, request, emailID: row.emailID)
    }

    /// The IMAP Trash folder the server listed for the account (nil = none).
    private func trashMailbox(_ account: UUID) async -> String? {
        ConnectedMailRuntime.trashMailbox(in: (try? await runtime.sink.folderSummaries(accountID: account)) ?? [])
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
        // Microsoft takes at most 4 MB per message once encoded: refused here,
        // with the reason, instead of failing in the outbox after the undo delay.
        if account.provider == .microsoftGraph, let why = Self.graphSendRefusal(byteCount: composed.bytes.count) {
            throw MailWorkspaceError(why)
        }
        let route: OutboxRoute
        switch account.provider {
        case .gmail: route = .gmailAPI
        case .microsoftGraph: route = .graphAPI
        case .imap: route = .smtp(appendToSent: false)
        }
        await registerSendRoutes()
        return try await outboxQueue.enqueue(composed, draft: draft, route: route, undoDelay: undoDelay)
    }

    /// Microsoft Graph's limit for one send request (the base64 MIME body).
    nonisolated static let graphMaximumEncodedBytes = GraphSendSubmitter.maximumRequestBytes

    /// Why a message of `byteCount` bytes cannot go through Microsoft Graph, or nil.
    nonisolated static func graphSendRefusal(byteCount: Int) -> String? {
        let encoded = ((byteCount + 2) / 3) * 4
        return encoded > graphMaximumEncodedBytes ? MailLifecycleText.graphTooLarge(encodedBytes: encoded) : nil
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
        let trash = await trashMailbox(account.id)
        guard let executor = try transports?.actionExecutor(account, credentials: credentials, tokens: tokens, permission: permission,
                                                            trashMailbox: trash) else {
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
/// runtime stops its engine, the policy cancels everything registered, and
/// the removal waits until the running capture has really ended.
private struct RuntimeTaskControl: AccountTaskControl {
    let runtime: ConnectedMailRuntime
    func cancelTasks(account: UUID) async -> Int {
        await runtime.stopAccountAndWait(account)
    }
}
