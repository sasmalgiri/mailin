//
//  IMAPAdapter.swift
//  MailConnectivity
//
//  Plan v4 V4-07 (§3 A07, §4, §5.1, §5.3): the IMAP connector behind the
//  `MailProviderAdapter` contract.
//
//  Identity is (account UUID, mailbox, UIDVALIDITY, UID) — never a sequence
//  number, never a UID alone. Capture is read-only: EXAMINE, then
//  `UID FETCH <uid> (… BODY.PEEK[])` streamed literal-by-byte-count into the
//  engine's `RawByteSink` (\Seen is never set).
//
//  Change tracking is per folder. The change token records UIDVALIDITY,
//  UIDNEXT, HIGHESTMODSEQ (when CONDSTORE/QRESYNC is offered) and the UIDs
//  known at the boundary (a compact sequence set):
//    • UIDVALIDITY differs  → `.changeTokenExpired` (the engine reconciles in
//      a new generation; new identities carry the new UIDVALIDITY, so a new
//      message is never attached to an old UID and nothing preserved is deleted);
//    • QRESYNC               → `UID FETCH 1:* (UID) (CHANGEDSINCE m VANISHED)`;
//    • otherwise             → unchanged UIDNEXT + EXISTS (+ HIGHESTMODSEQ) is
//      "no change"; else `UID SEARCH ALL` (ESEARCH when offered) is diffed
//      against the known set — the periodic reconciliation of plain IMAP.
//
//  No mutation commands exist in this file or in `IMAPSession` (V4-11).
//
//  Gmail (V4-16): a server that advertises X-GM-EXT-1 shows every label as a
//  folder, so one message has a different UID in INBOX, [Gmail]/All Mail and
//  each label folder. There the identity is the message's X-GM-MSGID
//  (`.gmailIMAP`), the same in every folder: it is downloaded ONCE and each
//  folder it is listed in, plus every label in X-GM-LABELS, becomes a
//  membership of that one record. [Gmail]/All Mail (special-use \All) is
//  listed first so the capture reads from it; Spam and Trash (not in All Mail)
//  are left out of "all folders" and captured only when selected. Still
//  read-only: EXAMINE, UID FETCH … BODY.PEEK[], UID SEARCH X-GM-MSGID.
//  A message's UID disappearing from a label folder is a label change, not a
//  deletion, so no `.deleted` is reported on Gmail (the record stays as is).
//

import ArchiveCore
import Foundation

// MARK: - Configuration

public enum IMAPAuthMethod: Sendable, Equatable {
    /// Password or app-specific password from the credential store (`.password`).
    case password
    /// OAuth access token (XOAUTH2 / OAUTHBEARER), obtained by the engine
    /// for `audience` or read from the credential store (`.oauthTokenSet`).
    case oauth2(audience: String, authorizationHost: String)
}

public struct IMAPAccountConfiguration: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var security: IMAPSecurity
    public var login: String
    public var auth: IMAPAuthMethod
    /// Connections (and so concurrent downloads) this account may hold.
    public var maxConnections: Int
    /// Messages per enumeration / change page (an internal control, not a cap).
    public var pageSize: Int
    /// Also list the "other users" and "shared" namespaces.
    public var includeSharedNamespaces: Bool
    public var timeout: TimeInterval

    public init(host: String, port: UInt16 = 993, security: IMAPSecurity = .implicitTLS, login: String,
                auth: IMAPAuthMethod = .password, maxConnections: Int = 2, pageSize: Int = 500,
                includeSharedNamespaces: Bool = false, timeout: TimeInterval = 60) {
        self.host = host; self.port = port; self.security = security; self.login = login; self.auth = auth
        self.maxConnections = max(1, maxConnections); self.pageSize = max(1, pageSize)
        self.includeSharedNamespaces = includeSharedNamespaces; self.timeout = timeout
    }

    var endpoint: IMAPEndpoint { IMAPEndpoint(host: host, port: port, security: security, timeout: timeout) }
}

/// Server presets. A preset fills in the server settings; it is NOT proof of
/// compatibility (plan §4): `verifiedAgainstRealServer` stays false until a
/// recorded run against that provider passes.
public struct IMAPProviderPreset: Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var host: String
    public var port: UInt16
    public var security: IMAPSecurity
    public var auth: IMAPAuthMethod
    /// What the user must do at the provider (shown on the sign-in screen).
    public var signInNote: String
    public var verifiedAgainstRealServer: Bool

    /// iCloud Mail: IMAP over TLS with an app-specific password generated at
    /// account.apple.com. Two-factor authentication stays on (plan §4, P09).
    public static let iCloud = IMAPProviderPreset(
        id: "icloud", displayName: "iCloud Mail", host: "imap.mail.me.com", port: 993, security: .implicitTLS,
        auth: .password,
        signInNote: "Use an app-specific password from your Apple Account settings. Keep two-factor authentication on.",
        verifiedAgainstRealServer: false)

    /// Fastmail: IMAP over TLS with an app password (Settings → Privacy & Security).
    public static let fastmail = IMAPProviderPreset(
        id: "fastmail", displayName: "Fastmail", host: "imap.fastmail.com", port: 993, security: .implicitTLS,
        auth: .password, signInNote: "Use an app password created in Fastmail's Privacy & Security settings.",
        verifiedAgainstRealServer: false)

    /// Gmail over IMAP (V4-16, the 4.0 Gmail path): IMAP over TLS with a
    /// Google app password (2-Step Verification on, created at
    /// myaccount.google.com/apppasswords). A normal Google password is refused.
    public static let gmail = IMAPProviderPreset(
        id: "gmail", displayName: "Gmail", host: "imap.gmail.com", port: 993, security: .implicitTLS,
        auth: .password,
        signInNote: "Use a Google app password: turn on 2-Step Verification, create the app password at myaccount.google.com/apppasswords and paste its 16 characters. A normal Google password is refused.",
        verifiedAgainstRealServer: false)

    /// Hosts of Gmail's IMAP and SMTP servers (for the app-password guidance).
    public static let gmailHosts: Set<String> = ["imap.gmail.com", "smtp.gmail.com", "imap.googlemail.com", "smtp.googlemail.com"]

    /// Any standards-based server: the user enters host, port and security.
    public static func generic(host: String, port: UInt16 = 993, security: IMAPSecurity = .implicitTLS) -> IMAPProviderPreset {
        IMAPProviderPreset(id: "generic", displayName: "Other IMAP server", host: host, port: port, security: security,
                           auth: .password, signInNote: "Use the server settings your mail provider publishes.",
                           verifiedAgainstRealServer: false)
    }

    public func configuration(login: String) -> IMAPAccountConfiguration {
        IMAPAccountConfiguration(host: host, port: port, security: security, login: login, auth: auth)
    }
}

/// Paces new connections after failures. It never repeats a request (the
/// engine owns retries); it only delays the next connection attempt.
public struct IMAPReconnectPolicy: Sendable {
    public var base: TimeInterval
    public var maximum: TimeInterval
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(base: TimeInterval = 1, maximum: TimeInterval = 60,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.base = base; self.maximum = maximum; self.sleep = sleep
    }

    public func delay(afterFailures n: Int) -> TimeInterval {
        guard n > 0 else { return 0 }
        return min(maximum, base * pow(2, Double(n - 1)))
    }
}

// MARK: - Cursors and change tokens

struct IMAPEnumerationCursor: Equatable {
    var uidValidity: UInt32
    var after: UInt32
    var window: UInt32

    var encoded: String { "imap1;v=\(uidValidity);after=\(after);w=\(window)" }

    init(uidValidity: UInt32, after: UInt32, window: UInt32) {
        self.uidValidity = uidValidity; self.after = after; self.window = window
    }

    init?(_ s: String) {
        let f = IMAPChangeToken.fields(s)
        guard f["imap1"] != nil, let v = f["v"].flatMap({ UInt32($0) }), let a = f["after"].flatMap({ UInt32($0) }) else { return nil }
        uidValidity = v; after = a; window = f["w"].flatMap { UInt32($0) } ?? 0
    }
}

struct IMAPChangeToken: Equatable {
    var uidValidity: UInt32
    var uidNext: UInt32?
    var modSeq: UInt64?
    var exists: UInt64
    var known: IMAPUIDSet

    static let noSelect = "imap1;noselect"

    var encoded: String {
        var s = "imap1;v=\(uidValidity);e=\(exists)"
        if let uidNext { s += ";n=\(uidNext)" }
        if let modSeq { s += ";m=\(modSeq)" }
        return s + ";s=" + known.sequenceSet
    }

    init(uidValidity: UInt32, uidNext: UInt32?, modSeq: UInt64?, exists: UInt64, known: IMAPUIDSet) {
        self.uidValidity = uidValidity; self.uidNext = uidNext; self.modSeq = modSeq; self.exists = exists; self.known = known
    }

    init?(_ s: String) {
        let f = Self.fields(s)
        guard f["imap1"] != nil, let v = f["v"].flatMap({ UInt32($0) }), let set = f["s"].flatMap({ IMAPUIDSet(sequenceSet: $0) }) else { return nil }
        uidValidity = v
        uidNext = f["n"].flatMap { UInt32($0) }
        modSeq = f["m"].flatMap { UInt64($0) }
        exists = f["e"].flatMap { UInt64($0) } ?? UInt64(set.count)
        known = set
    }

    static func fields(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in s.split(separator: ";", omittingEmptySubsequences: false) {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            out[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
        }
        return out
    }
}

// MARK: - Adapter

public actor IMAPAdapter: MailProviderAdapter {
    public nonisolated let accountID: UUID
    public nonisolated let provider: MailProviderKind = .imap
    public nonisolated let mailHost: String
    public nonisolated let authorizationHost: String?
    public nonisolated let tokenAudience: String?
    public nonisolated let configuration: IMAPAccountConfiguration
    /// The client side of every connection, secrets masked.
    public nonisolated let log = IMAPProtocolLog()

    private let credentials: CredentialStore
    private let transportFactory: IMAPTransportFactory
    private let permission: NetworkPermission?
    private let reconnect: IMAPReconnectPolicy

    private struct FolderInfo { var wire: [UInt8]; var occurrence: RemoteFolderOccurrence; var selectable: Bool }
    private var folders: [String: FolderInfo] = [:]

    // V4-16 Gmail (X-GM-EXT-1), learnt from the folder list.
    /// The server speaks Gmail's IMAP extensions.
    public private(set) var isGmail = false
    /// Label (as X-GM-LABELS names it) → the folder that shows it.
    private var gmailLabelFolders: [String: RemoteFolderOccurrence] = [:]
    /// [Gmail]/All Mail's server id (special-use \All).
    private var gmailAllMail: String?
    /// Spam and Trash: not in All Mail, left out of "all folders".
    private var gmailSkipped: Set<String> = []
    /// Where the CURRENT page's messages were listed (X-GM-MSGID → mailbox,
    /// UIDVALIDITY, UID), so a download needs no search. Replaced at every
    /// page; a message not in it (a retry after a restart) is found with
    /// UID SEARCH X-GM-MSGID.
    private var gmailLocations: [UInt64: (mailbox: String, validity: UInt32, uid: UInt32)] = [:]

    private var idle: [IMAPSession] = []
    private var open = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var consecutiveConnectFailures = 0

    // Diagnostics.
    public private(set) var connectionsOpened = 0

    /// `permission` is asked before every NEW connection (the engine asks
    /// before every request as well).
    public init(accountID: UUID, configuration: IMAPAccountConfiguration, credentials: CredentialStore,
                transportFactory: @escaping IMAPTransportFactory = IMAPTransports.system,
                permission: NetworkPermission? = nil, reconnect: IMAPReconnectPolicy = IMAPReconnectPolicy()) {
        self.accountID = accountID; self.configuration = configuration; self.credentials = credentials
        self.transportFactory = transportFactory; self.permission = permission; self.reconnect = reconnect
        self.mailHost = configuration.host
        switch configuration.auth {
        case .password: authorizationHost = nil; tokenAudience = nil
        case .oauth2(let audience, let host): authorizationHost = host; tokenAudience = audience
        }
    }

    /// An adapter for a registered IMAP `MailAccount` (server identity from the record).
    public init(account: MailAccount, security: IMAPSecurity? = nil, auth: IMAPAuthMethod = .password,
                credentials: CredentialStore, transportFactory: @escaping IMAPTransportFactory = IMAPTransports.system,
                permission: NetworkPermission? = nil) throws {
        try account.validate()
        guard account.provider == .imap, let host = account.host else { throw MailProviderError.permanent("not an IMAP account") }
        let port = UInt16(clamping: account.port ?? 993)
        let config = IMAPAccountConfiguration(host: host, port: port, security: security ?? (port == 143 ? .startTLS : .implicitTLS),
                                              login: account.loginName ?? account.displayIdentity, auth: auth)
        self.init(accountID: account.id, configuration: config, credentials: credentials,
                  transportFactory: transportFactory, permission: permission)
    }

    public func limits() async -> ProviderLimits {
        ProviderLimits(maxConcurrentDownloads: configuration.maxConnections, pageSize: configuration.pageSize,
                       changeTracking: .perFolder)
    }

    // MARK: Sessions

    private func credential(_ context: ProviderRequestContext) throws -> IMAPAuthentication {
        switch configuration.auth {
        case .password:
            guard let data = try credentials.read(.password, account: accountID), let password = String(data: data, encoding: .utf8),
                  !password.isEmpty else { throw MailProviderError.reauthorisationRequired }
            return .password(login: configuration.login, password: password)
        case .oauth2:
            if let token = context.accessToken, !token.isEmpty { return .oauth(login: configuration.login, accessToken: token) }
            guard let data = try credentials.read(.oauthTokenSet, account: accountID) else { throw MailProviderError.reauthorisationRequired }
            let set = try OAuthTokenSet.decode(data)
            return .oauth(login: configuration.login, accessToken: set.accessToken)
        }
    }

    private func openSession(_ context: ProviderRequestContext) async throws -> IMAPSession {
        let auth = try credential(context)
        if let permission {
            do {
                try permission(NetworkAsk(accountID: accountID, host: configuration.host, destination: .mailServer, operation: .request))
            } catch {
                throw MailProviderError.permanent("network use for this mail account is not permitted: \(error.localizedDescription)")
            }
        }
        let wait = reconnect.delay(afterFailures: consecutiveConnectFailures)
        if wait > 0 { try await reconnect.sleep(wait) }
        let endpoint = configuration.endpoint
        let transport: any IMAPByteTransport
        do {
            transport = try await transportFactory(endpoint)
        } catch {
            consecutiveConnectFailures += 1
            throw Self.map(error)
        }
        connectionsOpened += 1
        let session = IMAPSession(transport: transport, endpoint: endpoint, log: log)
        do {
            try await session.establish(auth)
        } catch {
            transport.close()
            let mapped = Self.map(error)
            if case MailProviderError.transient = mapped { consecutiveConnectFailures += 1 }
            throw mapped
        }
        consecutiveConnectFailures = 0
        return session
    }

    private func checkout(_ context: ProviderRequestContext) async throws -> IMAPSession {
        while true {
            if let s = idle.popLast() {
                if await s.isUsable { return s }
                open -= 1
                continue
            }
            if open < configuration.maxConnections {
                open += 1
                do { return try await openSession(context) } catch {
                    open -= 1
                    wakeOne()
                    throw error
                }
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func wakeOne() { if !waiters.isEmpty { waiters.removeFirst().resume() } }

    private func checkin(_ s: IMAPSession) async {
        if await s.isUsable { idle.append(s) } else { open -= 1 }
        wakeOne()
    }

    private func withSession<T: Sendable>(_ context: ProviderRequestContext, _ body: (IMAPSession) async throws -> T) async throws -> T {
        let s: IMAPSession
        do { s = try await checkout(context) } catch { throw Self.map(error) }
        do {
            let r = try await body(s)
            await checkin(s)
            return r
        } catch {
            if !(await s.isUsable) || error is CancellationError { await s.logout() }
            await checkin(s)
            throw Self.map(error)
        }
    }

    static func map(_ error: Error) -> Error {
        switch error {
        case let e as MailProviderError: return e
        case is CancellationError: return error
        case IMAPTransportError.plaintextRefused(let host):
            return MailProviderError.permanent("mailin does not connect to \(host) without encryption")
        case let e as IMAPTransportError: return MailProviderError.transient(e.localizedDescription)
        case let e as IMAPProtocolError: return MailProviderError.transient(e.localizedDescription)
        case let e as CredentialStoreError: return MailProviderError.permanent(e.localizedDescription)
        default: return MailProviderError.transient(error.localizedDescription)
        }
    }

    /// Closes every idle connection (LOGOUT).
    public func disconnect() async {
        let sessions = idle
        idle = []
        open -= sessions.count
        for s in sessions { await s.logout() }
    }

    // MARK: Folders

    private func displayPath(_ m: IMAPListedMailbox, personal: IMAPNamespace?) -> String {
        var name = m.name.name
        if name != "INBOX", let p = personal?.prefix, !p.isEmpty, name.hasPrefix(p), name.count > p.count {
            name = String(name.dropFirst(p.count))
        }
        guard let d = m.delimiter, !d.isEmpty else { return name.replacingOccurrences(of: "/", with: "\u{2215}") }
        return name.components(separatedBy: d)
            .map { d == "/" ? $0 : $0.replacingOccurrences(of: "/", with: "\u{2215}") }
            .joined(separator: "/")
    }

    private static let specialUses = ["\\ALL": "\\All", "\\ARCHIVE": "\\Archive", "\\DRAFTS": "\\Drafts", "\\FLAGGED": "\\Flagged",
                                      "\\JUNK": "\\Junk", "\\SENT": "\\Sent", "\\TRASH": "\\Trash"]

    public func listFolders(pageToken: String?, context: ProviderRequestContext) async throws -> FolderPage {
        let (listed, personal, gmail) = try await withSession(context) { s -> ([IMAPListedMailbox], IMAPNamespace?, Bool) in
            var all = try await s.list()
            if self.configuration.includeSharedNamespaces {
                for ns in await s.otherNamespaces where !ns.prefix.isEmpty {
                    let utf8 = await s.utf8Enabled
                    let pattern = String(decoding: IMAPMailboxName.wireBytes(for: ns.prefix, utf8: utf8), as: UTF8.self) + "*"
                    all += try await s.list(pattern: pattern)
                }
            }
            return (all, await s.personalNamespace, await s.hasGmailExtensions)
        }
        var out: [RemoteFolderOccurrence] = []
        var seen = Set<String>()
        var labels: [String: RemoteFolderOccurrence] = [:]
        var allMail: String?
        var skipped = Set<String>()
        for m in listed where seen.insert(m.name.name).inserted {
            let special = m.name.name == "INBOX" ? "INBOX"
                : Self.specialUses.first(where: { m.attributes.contains($0.key) })?.value
            let occ = RemoteFolderOccurrence(serverID: m.name.name, displayPath: displayPath(m, personal: personal),
                                             kind: .folder, specialUse: special)
            folders[m.name.name] = FolderInfo(wire: m.name.wire, occurrence: occ, selectable: m.isSelectable)
            out.append(occ)
            if gmail, m.isSelectable {
                if let label = Self.gmailLabel(forFolder: m) { labels[label.lowercased()] = occ }
                if m.attributes.contains("\\ALL") { allMail = m.name.name }
                if m.attributes.contains("\\JUNK") || m.attributes.contains("\\TRASH") { skipped.insert(m.name.name) }
            }
        }
        isGmail = gmail
        gmailLabelFolders = labels
        gmailAllMail = allMail
        gmailSkipped = skipped
        if let allMail, let i = out.firstIndex(where: { $0.serverID == allMail }) {
            // Read from All Mail first: every other folder's messages are then
            // already preserved and only gain a membership.
            out.insert(out.remove(at: i), at: 0)
        }
        return FolderPage(folders: out, nextPageToken: nil)
    }

    // MARK: Gmail labels (V4-16)

    /// The X-GM-LABELS name of the label a Gmail folder shows (nil for All Mail).
    static func gmailLabel(forFolder m: IMAPListedMailbox) -> String? {
        if m.name.name == "INBOX" { return "\\Inbox" }
        let system = ["\\SENT": "\\Sent", "\\DRAFTS": "\\Draft", "\\TRASH": "\\Trash", "\\JUNK": "\\Spam",
                      "\\FLAGGED": "\\Starred", "\\IMPORTANT": "\\Important"]
        if let s = system.first(where: { m.attributes.contains($0.key) }) { return s.value }
        if m.attributes.contains("\\ALL") { return nil }
        return m.name.name
    }

    /// Spam and Trash on Gmail: captured only when the person selects them.
    public func foldersSkippedByDefault() async -> Set<String> { isGmail ? gmailSkipped : [] }

    /// The folders a Gmail message's labels name. A user label with no listed
    /// folder (hidden from IMAP) is still a membership; a system label with
    /// no folder (e.g. \Important hidden) is not.
    private func gmailOccurrences(_ labels: [String]) -> [RemoteFolderOccurrence] {
        var out: [RemoteFolderOccurrence] = []
        for label in labels {
            if let occ = gmailLabelFolders[label.lowercased()] {
                if !out.contains(where: { $0.serverID == occ.serverID }) { out.append(occ) }
            } else if !label.hasPrefix("\\"), !out.contains(where: { $0.serverID == label }) {
                out.append(RemoteFolderOccurrence(serverID: label, displayPath: label, kind: .label))
            }
        }
        return out
    }

    private static func gmailRef(_ id: UInt64, _ occ: RemoteFolderOccurrence, _ size: Int64?) -> RemoteItemRef {
        RemoteItemRef(identity: .gmailIMAP(messageID: id), folder: occ, sizeHint: size)
    }

    private func info(_ serverID: String, utf8: Bool) -> FolderInfo {
        folders[serverID] ?? FolderInfo(wire: IMAPMailboxName.wireBytes(for: serverID, utf8: utf8),
                                        occurrence: RemoteFolderOccurrence(serverID: serverID, displayPath: serverID),
                                        selectable: true)
    }

    private func occurrence(_ serverID: String, uidValidity: UInt32) -> RemoteFolderOccurrence {
        var o = folders[serverID]?.occurrence ?? RemoteFolderOccurrence(serverID: serverID, displayPath: serverID)
        o.uidValidity = uidValidity
        return o
    }

    private func examine(_ s: IMAPSession, _ serverID: String, force: Bool = false) async throws -> IMAPMailboxStatus {
        let f = info(serverID, utf8: await s.utf8Enabled)
        do {
            return try await s.examine(f.wire, force: force)
        } catch MailProviderError.folderUnavailable {
            throw MailProviderError.folderUnavailable(serverID)
        }
    }

    // MARK: Enumeration (UID ranges)

    public func enumerate(folder: RemoteFolderOccurrence, cursor: String?, pageSize: Int,
                          context: ProviderRequestContext) async throws -> EnumerationPage {
        if let f = folders[folder.serverID], !f.selectable { return EnumerationPage(items: [], nextCursor: nil) }
        let pageSize = max(1, pageSize)
        return try await withSession(context) { s in
            // Always a fresh EXAMINE: a pooled connection's UIDNEXT may be stale.
            let status = try await self.examine(s, folder.serverID, force: true)
            var c = cursor.flatMap(IMAPEnumerationCursor.init)
            if let existing = c, existing.uidValidity != status.uidValidity {
                // UIDVALIDITY changed under the enumeration: start the folder
                // again; every identity listed now carries the new value.
                c = nil
            }
            var after = c?.after ?? 0
            var window = max(UInt32(clamping: pageSize), c?.window ?? 0)
            let occ = self.occurrence(folder.serverID, uidValidity: status.uidValidity)
            let gmail = await s.hasGmailExtensions
            if gmail { self.gmailLocations = [:] }      // only this page's messages
            guard status.exists > 0 else { return EnumerationPage(items: [], nextCursor: nil) }
            let top: UInt32? = status.uidNext.map { $0 > 0 ? $0 - 1 : 0 }
            var items: [RemoteItemRef] = []
            while true {
                if let top, after >= top { return EnumerationPage(items: items, nextCursor: nil) }
                let lo = after + 1
                let hi: UInt32? = top.map { UInt32(min(UInt64($0), UInt64(lo) + UInt64(window) - 1)) }
                let set = hi.map { "\(lo):\($0)" } ?? "\(lo):*"
                let listed: [IMAPGmailListing] = gmail
                    ? try await s.gmailListing(set)
                    : try await s.uidSizes(set).map { IMAPGmailListing(uid: $0.uid, size: $0.size, messageID: nil) }
                let found = listed
                    .filter { $0.uid >= lo && (hi == nil || $0.uid <= hi!) }
                    .sorted { $0.uid < $1.uid }
                let room = pageSize - items.count
                if found.count > room {
                    for f in found.prefix(room) {
                        items.append(self.listedRef(folder.serverID, status.uidValidity, f, occ))
                    }
                    after = found[room - 1].uid
                    let next = IMAPEnumerationCursor(uidValidity: status.uidValidity, after: after,
                                                     window: found.count > 2 * pageSize ? max(UInt32(clamping: pageSize), window / 2) : window)
                    return EnumerationPage(items: items, nextCursor: next.encoded)
                }
                for f in found { items.append(self.listedRef(folder.serverID, status.uidValidity, f, occ)) }
                guard let hi else {
                    // No UIDNEXT: "lo:*" returned everything after `lo`.
                    return EnumerationPage(items: items, nextCursor: nil)
                }
                after = hi
                if after >= top! { return EnumerationPage(items: items, nextCursor: nil) }
                if items.count * 2 >= pageSize {
                    let next = IMAPEnumerationCursor(uidValidity: status.uidValidity, after: after, window: window)
                    return EnumerationPage(items: items, nextCursor: next.encoded)
                }
                // Sparse UIDs: widen the window (bounded by UIDNEXT).
                if found.count * 4 < pageSize { window = window > UInt32.max / 2 ? UInt32.max : window * 2 }
            }
        }
    }

    private static func ref(_ mailbox: String, _ validity: UInt32, _ uid: UInt32, _ occ: RemoteFolderOccurrence, _ size: Int64?) -> RemoteItemRef {
        RemoteItemRef(identity: .imap(mailbox: mailbox, uidValidity: validity, uid: uid), folder: occ, sizeHint: size)
    }

    /// The ref of a listed message: its X-GM-MSGID on Gmail (where it was
    /// listed is remembered for the download), else mailbox + UIDVALIDITY + UID.
    private func listedRef(_ mailbox: String, _ validity: UInt32, _ f: IMAPGmailListing, _ occ: RemoteFolderOccurrence) -> RemoteItemRef {
        guard let id = f.messageID, id != 0 else { return Self.ref(mailbox, validity, f.uid, occ, f.size) }
        gmailLocations[id] = (mailbox, validity, f.uid)
        return Self.gmailRef(id, occ, f.size)
    }

    // MARK: Download

    public func fetchRaw(_ item: RemoteItemRef, into sink: RawByteSink, context: ProviderRequestContext) async throws -> FetchedItemMetadata {
        if case .gmailIMAP(let id) = item.identity { return try await fetchGmail(id, item, into: sink, context: context) }
        guard case .imap(let mailbox, let validity, let uid) = item.identity else {
            throw MailProviderError.permanent("not an IMAP identity")
        }
        let host = "\(configuration.host):\(configuration.port)"
        return try await withSession(context) { s in
            // A pooled connection's selection may be stale (it was opened
            // before the server changed): it is reused only while it agrees,
            // and re-EXAMINEd before any "unavailable" conclusion.
            var fresh = false
            var body: IMAPFetchedBody?
            while true {
                let status: IMAPMailboxStatus
                do {
                    status = try await self.examine(s, mailbox, force: fresh)
                } catch MailProviderError.folderUnavailable {
                    throw MailProviderError.itemUnavailable
                }
                // A different UIDVALIDITY means this UID may now be another
                // message: never fetch it under the old identity.
                if status.uidValidity == validity {
                    body = try await s.fetchBody(uid: uid, into: { try sink.write($0) })
                    if body != nil { break }
                }
                if fresh { throw MailProviderError.itemUnavailable }
                fresh = true
            }
            guard let body else { throw MailProviderError.itemUnavailable }
            var extra = ["imap.server": host, "imap.mailbox": mailbox, "imap.uidValidity": String(validity), "imap.uid": String(uid)]
            if let size = item.sizeHint { extra["imap.rfc822Size"] = String(size) }
            let metadata = ProviderMetadata(representation: .imapLiteral, internalDate: body.internalDate,
                                            revision: body.modSeq.map(String.init), flags: body.flags, extra: extra)
            return FetchedItemMetadata(occurrences: [self.occurrence(mailbox, uidValidity: validity)], metadata: metadata,
                                       expectedByteCount: body.byteCount)
        }
    }

    /// V4-16: one Gmail message, downloaded once wherever it is: from where
    /// this page listed it, else found by X-GM-MSGID in All Mail (then in the
    /// folder the ref names). Its memberships are the folder it was read
    /// from plus every label X-GM-LABELS names.
    private func fetchGmail(_ id: UInt64, _ item: RemoteItemRef, into sink: RawByteSink,
                            context: ProviderRequestContext) async throws -> FetchedItemMetadata {
        let host = "\(configuration.host):\(configuration.port)"
        let known = gmailLocations[id]
        var places: [String] = known.map { [$0.mailbox] } ?? []
        for p in [gmailAllMail, item.folder?.serverID].compactMap({ $0 }) where !places.contains(p) { places.append(p) }
        return try await withSession(context) { s in
            for mailbox in places {
                let cached = known.flatMap { $0.mailbox == mailbox ? $0 : nil }
                let status: IMAPMailboxStatus
                do {
                    // A search needs the folder's current state; a listed UID
                    // is valid for as long as UIDVALIDITY is unchanged.
                    status = try await self.examine(s, mailbox, force: cached == nil)
                } catch MailProviderError.folderUnavailable { continue }
                let uid: UInt32?
                if let cached, cached.validity == status.uidValidity { uid = cached.uid }
                else { uid = try await s.gmailSearch(messageID: id) }
                guard let uid, let body = try await s.fetchBody(uid: uid, into: { try sink.write($0) }) else { continue }
                if let got = body.gmailMessageID, got != id {
                    throw MailProviderError.permanent("the server sent message \(got) for a request of message \(id)")
                }
                let here = self.occurrence(mailbox, uidValidity: status.uidValidity)
                // Labels first, so the record's main folder is INBOX / Sent /
                // a label rather than All Mail (which holds every message).
                var occurrences = self.gmailOccurrences(body.gmailLabels)
                if !occurrences.contains(where: { $0.serverID == here.serverID }) { occurrences.append(here) }
                var extra = ["imap.server": host, "imap.mailbox": mailbox, "imap.uidValidity": String(status.uidValidity),
                             "imap.uid": String(uid), "imap.gmailMessageID": String(id)]
                if !body.gmailLabels.isEmpty, let json = try? JSONEncoder().encode(body.gmailLabels) {
                    extra["imap.gmailLabels"] = String(decoding: json, as: UTF8.self)
                }
                if let size = item.sizeHint { extra["imap.rfc822Size"] = String(size) }
                let metadata = ProviderMetadata(representation: .imapLiteral, internalDate: body.internalDate,
                                                revision: body.modSeq.map(String.init), flags: body.flags, extra: extra)
                return FetchedItemMetadata(occurrences: occurrences, metadata: metadata, expectedByteCount: body.byteCount)
            }
            throw MailProviderError.itemUnavailable
        }
    }

    // MARK: Changes

    private func folderID(_ scope: ChangeScope) throws -> String {
        guard case .folder(let f) = scope else { throw MailProviderError.permanent("IMAP tracks changes per folder") }
        return f.serverID
    }

    public func changeBoundary(scope: ChangeScope, context: ProviderRequestContext) async throws -> String {
        let id = try folderID(scope)
        if let f = folders[id], !f.selectable { return IMAPChangeToken.noSelect }
        return try await withSession(context) { s in
            let status = try await self.examine(s, id, force: true)
            let known = status.exists == 0 ? IMAPUIDSet() : try await s.searchAllUIDs()
            let condstore = await s.condstoreEnabled
            return IMAPChangeToken(uidValidity: status.uidValidity, uidNext: status.uidNext,
                                   modSeq: condstore ? status.highestModSeq : nil, exists: status.exists, known: known).encoded
        }
    }

    public func changes(scope: ChangeScope, since token: String, context: ProviderRequestContext) async throws -> ChangePage {
        let id = try folderID(scope)
        if token == IMAPChangeToken.noSelect {
            if let f = folders[id], !f.selectable { return ChangePage(changes: [], resume: token, hasMore: false) }
            throw MailProviderError.changeTokenExpired        // became selectable: bootstrap it
        }
        guard let old = IMAPChangeToken(token) else { throw MailProviderError.changeTokenExpired }
        let pageSize = configuration.pageSize
        return try await withSession(context) { s in
            let status = try await self.examine(s, id, force: true)
            guard status.uidValidity == old.uidValidity else { throw MailProviderError.changeTokenExpired }
            let condstore = await s.condstoreEnabled
            let modSeqNow = condstore ? status.highestModSeq : nil
            let final = IMAPChangeToken(uidValidity: status.uidValidity, uidNext: status.uidNext, modSeq: modSeqNow,
                                        exists: status.exists, known: old.known)

            // Nothing moved: same UIDNEXT, same count, same HIGHESTMODSEQ.
            if status.uidNext != nil, status.uidNext == old.uidNext, status.exists == old.exists,
               old.modSeq == modSeqNow, UInt64(old.known.count) == status.exists {
                return ChangePage(changes: [], resume: final.encoded, hasMore: false)
            }

            var arrivals: [UInt32] = []
            var deleted: [UInt32] = []
            if await s.qresyncEnabled, let m = old.modSeq, modSeqNow != nil {
                let (changed, vanished) = try await s.changedSince(m)
                arrivals = Array(Set(changed.filter { !old.known.contains($0) })).sorted()
                deleted = vanished.uids.filter { old.known.contains($0) }
            } else {
                let current = status.exists == 0 ? IMAPUIDSet() : try await s.searchAllUIDs()
                arrivals = current.subtracting(old.known)
                deleted = old.known.subtracting(current)
            }

            let occ = self.occurrence(id, uidValidity: status.uidValidity)
            let gmail = await s.hasGmailExtensions
            var changes: [RemoteChange] = []
            var next = old
            var consumed = 0
            for uid in deleted.prefix(pageSize) {
                // Gmail: a UID leaving a label folder is a label change, not a
                // deletion of the message (whose identity is its X-GM-MSGID).
                if !gmail { changes.append(.deleted(.imap(mailbox: id, uidValidity: status.uidValidity, uid: uid))) }
                next.known.remove(uid)
                consumed += 1
            }
            let page = Array(arrivals.prefix(max(0, pageSize - consumed)))
            if gmail {
                self.gmailLocations = [:]
                let listed = page.isEmpty ? [] : try await s.gmailListing(IMAPUIDSet(page).sequenceSet)
                let byUID = Dictionary(listed.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
                for uid in page {
                    consumed += 1
                    // Gone again before it could be listed: nothing to capture.
                    guard let f = byUID[uid] else { continue }
                    changes.append(.upserted(self.listedRef(id, status.uidValidity, f, occ), occurrences: [occ]))
                    next.known.insert(uid)
                }
            } else {
                for uid in page {
                    let ref = Self.ref(id, status.uidValidity, uid, occ, nil)
                    changes.append(.upserted(ref, occurrences: [occ]))
                    next.known.insert(uid)
                    consumed += 1
                }
            }
            let hasMore = deleted.count + arrivals.count > consumed
            if hasMore {
                // Progress is carried by the known set; the boundary values
                // stay old so the "nothing moved" shortcut is not taken early.
                return ChangePage(changes: changes, resume: next.encoded, hasMore: true)
            }
            var done = final
            done.known = next.known
            return ChangePage(changes: changes, resume: done.encoded, hasMore: false)
        }
    }

    // MARK: IDLE (optional)

    /// Waits up to `timeout` for `folder` to change, on its own connection.
    /// Returns false at once when the server has no IDLE (poll instead).
    public func waitForChange(in folder: RemoteFolderOccurrence, timeout: TimeInterval,
                              context: ProviderRequestContext) async throws -> Bool {
        try await withSession(context) { s in
            guard await s.capabilities.has("IDLE") else { return false }
            _ = try await self.examine(s, folder.serverID, force: true)
            return try await s.idle(timeout: timeout)
        }
    }
}

// MARK: - V4-11 server actions (additive)

extension IMAPAdapter {
    /// One pooled connection for a server action (`IMAPActionExecutor`). The
    /// cached selection is dropped before and after, so capture never reuses
    /// a mailbox the action opened read-write.
    func withActionSession<T: Sendable>(_ body: @Sendable (IMAPSession) async throws -> T) async throws -> T {
        let context = ProviderRequestContext(accountID: accountID, accessToken: nil, attempt: 0)
        // A server-action verdict (`RemoteRequestFailure`) passes through as
        // a value: `withSession` would map it onto a transport error, and the
        // connection stays usable after it.
        let result: Result<T, RemoteRequestFailure> = try await withSession(context) { s in
            await s.forgetSelection()
            do {
                let r = try await body(s)
                await s.forgetSelection()
                return .success(r)
            } catch let verdict as RemoteRequestFailure {
                await s.forgetSelection()
                return .failure(verdict)
            } catch {
                await s.forgetSelection()
                throw error
            }
        }
        return try result.get()
    }

    /// The mailbox's wire name as LISTed (or encoded from its name).
    func actionWire(_ serverID: String, utf8: Bool) -> [UInt8] { info(serverID, utf8: utf8).wire }
}
