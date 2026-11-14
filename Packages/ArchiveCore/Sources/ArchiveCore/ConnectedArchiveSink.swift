//
//  ConnectedArchiveSink.swift
//  ArchiveCore
//
//  Plan v4 V4-03 (§3 A08, §5.1, §5.2): the explicit ingestion boundary every
//  connected-mail provider adapter hands its messages to. It replaces the
//  unscoped `ingestEmails` path (accountID nil, sourceID nil, Message-ID
//  dedup) for online mail.
//
//  An item carries: the account (UUID), the provider identity (the occurrence
//  key), the folder / label observations, the DURABLE raw bytes (a staged file
//  of the RFC 822 bytes exactly as acquired + their SHA-256 + size) and
//  provider metadata (kept in records, never written into the preserved MIME).
//
//  Ordering, exactly (§5.2):
//    1. bytes staged and hashed         (adapter, through `StagingWriter`)
//    2. published atomically            (content-addressed blob tier: temp →
//                                         fsync → rename; the digest is checked
//                                         against the staged one)
//    3. record + occurrence + item outcome committed in ONE transaction
//    4. the durable item outcome is returned
//    5. a checkpoint may advance only when every item of the run is terminal
//  A kill between any two steps leaves either an orphan blob (collectable,
//  adopted by the replay because it is content-addressed) or a committed
//  record whose bytes are already durable — never a record pointing at
//  missing bytes, and never an advanced cursor over an unrecorded item.
//
//  Duplicates: never decided by Message-ID. The provider identity is the
//  occurrence key; a repeated provider event for the same identity adds only
//  new memberships. The same Message-ID with different bytes, or in another
//  account, is a separate record; the duplicate engine compares content
//  hashes later, as for imported files.
//

import CryptoKit
import Foundation

// MARK: - Public contract types

/// The provider family of a connected account.
public enum MailProviderKind: String, Sendable, Codable, CaseIterable {
    case gmail
    case microsoftGraph = "graph"
    case imap
}

/// The account-qualified identity of one message at its provider (§5.1).
/// The table key is (account UUID, `key()`), so the same value in two
/// accounts is two occurrences.
public enum ProviderMessageIdentity: Sendable, Hashable, Codable {
    /// Gmail: the provider message id (labels are memberships, not messages).
    case gmail(messageID: String)
    /// Microsoft Graph: mailbox identity + the requested IMMUTABLE id.
    case graph(mailbox: String, immutableID: String)
    /// IMAP: mailbox + UIDVALIDITY + UID. Never a sequence number, never a UID alone.
    case imap(mailbox: String, uidValidity: UInt32, uid: UInt32)
    /// V4-16: an IMAP account on a server that advertises X-GM-EXT-1 (Gmail).
    /// Gmail shows labels as folders, so one message has a different UID in
    /// INBOX, [Gmail]/All Mail and every label folder; its X-GM-MSGID is the
    /// same in all of them. Keyed by it, the message is ONE record and every
    /// folder / label it is seen in is a membership (as for the Gmail API).
    case gmailIMAP(messageID: UInt64)

    public var provider: MailProviderKind {
        switch self {
        case .gmail: return .gmail
        case .graph: return .microsoftGraph
        case .imap, .gmailIMAP: return .imap
        }
    }

    struct Fields { var mailbox: String?; var messageID: String?; var uidValidity: UInt32?; var uid: UInt32? }
    var fields: Fields {
        switch self {
        case .gmail(let id): return Fields(mailbox: nil, messageID: id, uidValidity: nil, uid: nil)
        case .graph(let mailbox, let id): return Fields(mailbox: mailbox, messageID: id, uidValidity: nil, uid: nil)
        case .imap(let mailbox, let validity, let uid): return Fields(mailbox: mailbox, messageID: nil, uidValidity: validity, uid: uid)
        case .gmailIMAP(let id): return Fields(mailbox: nil, messageID: String(id), uidValidity: nil, uid: nil)
        }
    }

    /// The stable key within one account. Components are separated by U+001F,
    /// which a component may not contain (so two identities never collide).
    public func key() throws -> String {
        let separator = "\u{1F}"
        func checked(_ parts: [String]) throws -> String {
            for p in parts where p.isEmpty || p.contains(separator) {
                throw ConnectedArchiveError.invalidIdentity("an identity component is empty or contains U+001F")
            }
            return parts.joined(separator: separator)
        }
        switch self {
        case .gmail(let id): return try checked(["gmail", id])
        case .graph(let mailbox, let id): return try checked(["graph", mailbox, id])
        case .imap(let mailbox, let validity, let uid):
            guard validity != 0, uid != 0 else { throw ConnectedArchiveError.invalidIdentity("IMAP UIDVALIDITY and UID must be non-zero") }
            return try checked(["imap", mailbox, String(validity), String(uid)])
        case .gmailIMAP(let id):
            guard id != 0 else { throw ConnectedArchiveError.invalidIdentity("a Gmail X-GM-MSGID must be non-zero") }
            return try checked(["imap-gm", String(id)])
        }
    }
}

/// One folder or label a message was observed in.
public struct RemoteFolderOccurrence: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case folder, label }
    /// Gmail label id, Graph folder id, IMAP mailbox name.
    public var serverID: String
    /// "/"-separated path shown in the archive folder tree.
    public var displayPath: String
    public var kind: Kind
    /// INBOX, SENT, TRASH, SPAM, \Sent …, when the provider says so.
    public var specialUse: String?
    /// IMAP only: the mailbox UIDVALIDITY the observation was made under.
    public var uidValidity: UInt32?

    public init(serverID: String, displayPath: String, kind: Kind = .folder, specialUse: String? = nil, uidValidity: UInt32? = nil) {
        self.serverID = serverID; self.displayPath = displayPath; self.kind = kind
        self.specialUse = specialUse; self.uidValidity = uidValidity
    }

    var cleanPath: String { displayPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }
}

/// How the bytes were acquired. Graph MIME is a provider-produced
/// representation, not proof of the original SMTP or MAPI bytes (§5.2).
public enum SourceRepresentation: String, Sendable, Codable {
    case gmailRaw = "gmail-raw"
    case graphMIME = "graph-mime"
    case imapLiteral = "imap-literal"
}

public struct ProviderMetadata: Sendable, Equatable, Codable {
    public var representation: SourceRepresentation
    /// Provider receipt / internal date — a separate field from the header Date.
    public var internalDate: Date?
    /// Gmail historyId, Graph changeKey, IMAP MODSEQ.
    public var revision: String?
    public var flags: [String]
    public var extra: [String: String]

    public init(representation: SourceRepresentation, internalDate: Date? = nil, revision: String? = nil,
                flags: [String] = [], extra: [String: String] = [:]) {
        self.representation = representation; self.internalDate = internalDate; self.revision = revision
        self.flags = flags; self.extra = extra
    }
}

/// Bytes staged by `StagingWriter`: on disk, fsynced, hashed while written.
public struct StagedRawMessage: Sendable, Equatable {
    public let fileURL: URL
    public let sha256: String
    public let byteCount: Int64
}

public struct CaptureItem: Sendable {
    public var accountID: UUID
    public var identity: ProviderMessageIdentity
    public var occurrences: [RemoteFolderOccurrence]
    public var raw: StagedRawMessage
    public var metadata: ProviderMetadata

    public init(accountID: UUID, identity: ProviderMessageIdentity, occurrences: [RemoteFolderOccurrence],
                raw: StagedRawMessage, metadata: ProviderMetadata) {
        self.accountID = accountID; self.identity = identity; self.occurrences = occurrences
        self.raw = raw; self.metadata = metadata
    }
}

public enum CaptureItemState: String, Sendable, Codable {
    case pending
    case stored
    case alreadyPreserved
    case locallyDeleted
    case failed
    case unavailable

    public var isTerminal: Bool { self != .pending }
}

/// The durable outcome of one capture, returned only after it committed.
public struct CaptureOutcome: Sendable, Equatable {
    public var identity: ProviderMessageIdentity
    /// `.stored`, `.alreadyPreserved` (a repeated provider event) or
    /// `.locallyDeleted` (the user deleted this occurrence; not resurrected).
    public var state: CaptureItemState
    public var emailID: UUID?
    public var sha256: String
    public var byteCount: Int64
    public var newMemberships: Int
}

public struct CaptureRunReceipt: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable { case completed, partial }
    public var runID: String
    public var accountID: UUID
    public var stored: Int
    public var alreadyPreserved: Int
    public var locallyDeleted: Int
    public var failed: Int
    public var unavailable: Int
    public var pending: Int
    public var state: State
    public var accounted: Int { stored + alreadyPreserved + locallyDeleted + failed + unavailable }
    public var total: Int { accounted + pending }
}

public struct SyncCheckpoint: Sendable, Equatable {
    public var accountID: UUID
    public var scope: String
    public var cursor: String
    public var bootstrapState: String
    public var runID: String
    public var committedAt: Date
}

/// Where kill-safety tests interrupt a capture.
public enum CaptureBoundary: String, Sendable, CaseIterable {
    case afterStaging, afterPublish, afterCommit, beforeCheckpoint
}

public struct ConnectedReconcileReport: Sendable, Equatable {
    /// Staged files of captures that never committed, removed (the provider is re-asked).
    public var stagedFilesRemoved: Int
    /// Runs a previous process left `running`.
    public var runsInterrupted: Int
    /// Connected records whose bytes are missing from the blob tier — always
    /// zero unless the archive was damaged outside mailin; they are marked
    /// so the next capture of that identity republishes the bytes.
    public var recordsMissingBytes: Int
    public var recordsChecked: Int
}

/// The persisted account metadata. Holds NO secret (§7).
public struct ConnectedAccountRecord: Sendable, Equatable, Codable {
    public var accountID: UUID
    public var provider: MailProviderKind
    public var issuer: String
    public var tenant: String?
    public var host: String?
    public var port: Int?
    public var loginName: String?
    public var displayIdentity: String
    public var grantedScopes: [String]
    public var enabledModes: [String]
    public var connectionState: String
    public var createdAt: Date
    public var updatedAt: Date
    /// The archive source the account's messages hang under (set by the store).
    public var archiveSourceID: Int64?

    public init(accountID: UUID, provider: MailProviderKind, issuer: String, tenant: String? = nil, host: String? = nil,
                port: Int? = nil, loginName: String? = nil, displayIdentity: String, grantedScopes: [String] = [],
                enabledModes: [String] = [], connectionState: String, createdAt: Date, updatedAt: Date) {
        self.accountID = accountID; self.provider = provider; self.issuer = issuer; self.tenant = tenant
        self.host = host; self.port = port; self.loginName = loginName; self.displayIdentity = displayIdentity
        self.grantedScopes = grantedScopes; self.enabledModes = enabledModes; self.connectionState = connectionState
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// What the archive can say about where a connected message came from.
public struct ConnectedProvenance: Sendable, Equatable, Codable {
    public var emailID: UUID
    public var accountID: UUID
    public var provider: String
    public var identityKey: String
    public var mailbox: String?
    public var providerMessageID: String?
    public var uidValidity: UInt32?
    public var uid: UInt32?
    public var sha256: String
    public var byteCount: Int64
    public var representation: String
    public var internalDate: Date?
    public var firstCapturedAt: Date
    public var issuer: String
    public var tenant: String?
    public var host: String?
    public var displayIdentity: String
    public var memberships: [String]
}

public enum ConnectedArchiveError: LocalizedError, Equatable {
    case stagedFileMissing(String)
    case stagedBytesMismatch(expected: String, actual: String)
    case stagedSizeMismatch(expected: Int64, actual: Int64)
    case unknownAccount(UUID)
    case accountMismatch
    case runNotFound(String)
    case runNotRunning(String)
    case itemsNotTerminal(runID: String, pending: Int)
    case invalidIdentity(String)
    case stagingFailed(String)
    /// V4-12: the archive's volume ran out of space while a download was staged.
    case volumeFull(String)

    public var errorDescription: String? {
        switch self {
        case .volumeFull(let why): return "The archive's disk is full; the download was not kept (\(why))."
        case .stagedFileMissing(let p): return "The downloaded message file \(p) is missing; it was not preserved and will be downloaded again."
        case .stagedBytesMismatch(let e, let a): return "A downloaded message changed before it was preserved (expected \(e.prefix(12))…, found \(a.prefix(12))…); it was not preserved."
        case .stagedSizeMismatch(let e, let a): return "A downloaded message is \(a) bytes, not the \(e) bytes staged; it was not preserved."
        case .unknownAccount(let id): return "No connected account \(id.uuidString) exists in this archive."
        case .accountMismatch: return "The message belongs to a different account than the capture run."
        case .runNotFound(let id): return "Capture run \(id) does not exist."
        case .runNotRunning(let id): return "Capture run \(id) has already ended."
        case .itemsNotTerminal(_, let n): return "\(n) listed messages are not yet preserved or accounted for; the sync position was not advanced."
        case .invalidIdentity(let why): return "Invalid provider message identity: \(why)."
        case .stagingFailed(let why): return "A downloaded message could not be staged: \(why)."
        }
    }
}

// MARK: - Staging

/// Owner-only staging of one message's bytes, hashed while they arrive. The
/// bytes are written as received — never converted through a String.
public final class StagingWriter {
    public let fileURL: URL
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var count: Int64 = 0

    init(directory: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch { throw ConnectedArchiveError.stagingFailed(error.localizedDescription) }
        ArtifactProtection.applyBackgroundReadable(to: directory)
        fileURL = directory.appendingPathComponent("stage-\(UUID().uuidString).eml")
        guard fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw ConnectedArchiveError.stagingFailed("cannot create \(fileURL.lastPathComponent)")
        }
        self.handle = handle
    }

    public func append(_ data: Data) throws {
        guard let handle else { throw ConnectedArchiveError.stagingFailed("the staging file is closed") }
        do { try handle.write(contentsOf: data) } catch {
            discard()
            throw ArchiveWriteError.isOutOfSpace(error) ? ConnectedArchiveError.volumeFull(error.localizedDescription)
                                                        : ConnectedArchiveError.stagingFailed(error.localizedDescription)
        }
        hasher.update(data: data)
        count += Int64(data.count)
    }

    /// fsyncs and closes; the bytes are durable when this returns.
    public func finish() throws -> StagedRawMessage {
        guard let handle else { throw ConnectedArchiveError.stagingFailed("the staging file is closed") }
        do { try handle.synchronize(); try handle.close() } catch {
            discard()
            throw ArchiveWriteError.isOutOfSpace(error) ? ConnectedArchiveError.volumeFull(error.localizedDescription)
                                                        : ConnectedArchiveError.stagingFailed(error.localizedDescription)
        }
        self.handle = nil
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return StagedRawMessage(fileURL: fileURL, sha256: digest, byteCount: count)
    }

    public func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - The sink

public actor ConnectedArchiveSink {
    nonisolated let store: SQLiteEmailStore
    /// Tests only: throws at a boundary to simulate the process being killed there.
    var faultHook: (@Sendable (CaptureBoundary) throws -> Void)?
    /// Tests only: throws to simulate the reader failing on the published bytes (T20).
    var parseFaultHook: (@Sendable (Data) throws -> Void)?
    func setParseFaultHook(_ hook: (@Sendable (Data) throws -> Void)?) { parseFaultHook = hook }

    /// The archive at `storeDirectory` (opened on its own connection).
    public init(storeDirectory: URL) {
        self.store = SQLiteEmailStore(directory: storeDirectory)
    }

    /// The app passes its shared store so all writes share one connection.
    init(store: SQLiteEmailStore) { self.store = store }

    /// V4-08 (plan §5.5): told about every NEWLY stored record, after its
    /// commit, so the app indexes captured mail into search exactly as it
    /// indexes an import. A repeated provider event (`alreadyPreserved`) and a
    /// locally deleted occurrence are not reported — they were indexed when
    /// they were stored. A process that dies between the commit and the
    /// observer leaves a row the launch-time search reconcile indexes.
    var storedObserver: (@Sendable (UUID) async -> Void)?
    public func setStoredObserver(_ observer: (@Sendable (UUID) async -> Void)?) { storedObserver = observer }

    func setFaultHook(_ hook: (@Sendable (CaptureBoundary) throws -> Void)?) { faultHook = hook }

    /// `<store>/connected-staging` — owner-only; holds bytes not yet published.
    public nonisolated var stagingDirectory: URL {
        store.storeDirectory.appendingPathComponent("connected-staging", isDirectory: true)
    }

    public nonisolated func makeStagingWriter() throws -> StagingWriter {
        try StagingWriter(directory: stagingDirectory)
    }

    // MARK: Accounts

    public func saveAccount(_ record: ConnectedAccountRecord) async throws {
        try await store.saveConnectedAccount(record)
    }

    public func accountRecords() async throws -> [ConnectedAccountRecord] {
        try await store.connectedAccounts()
    }

    public func recordFolders(accountID: UUID, folders: [RemoteFolderOccurrence]) async throws {
        try await store.recordRemoteFolders(accountID: accountID, folders: folders)
    }

    // MARK: Runs

    public func beginRun(accountID: UUID, selection: String) async throws -> String {
        try await store.beginCaptureRun(accountID: accountID, selection: selection)
    }

    /// Items the provider listed; each must reach a terminal state before a
    /// checkpoint of this run may advance.
    public func recordDiscovered(runID: String, identities: [ProviderMessageIdentity]) async throws {
        try await store.recordDiscovered(runID: runID, identities: identities)
    }

    public func recordFailure(runID: String, identity: ProviderMessageIdentity, state: CaptureItemState, reason: String) async throws {
        try await store.recordCaptureFailure(runID: runID, identity: identity, state: state, reason: reason)
    }

    public func finishRun(_ runID: String) async throws -> CaptureRunReceipt {
        try await store.finishCaptureRun(runID: runID)
    }

    // MARK: Capture

    /// Publishes the staged bytes, commits record + occurrence + outcome in
    /// one transaction, and returns the durable outcome. The staged file is
    /// removed only after the commit.
    public func capture(_ item: CaptureItem, runID: String) async throws -> CaptureOutcome {
        let key = try item.identity.key()
        let fm = FileManager.default
        guard fm.fileExists(atPath: item.raw.fileURL.path) else {
            throw ConnectedArchiveError.stagedFileMissing(item.raw.fileURL.lastPathComponent)
        }
        let run = try await store.runAccount(runID: runID)
        guard run.account == item.accountID else { throw ConnectedArchiveError.accountMismatch }
        guard run.state == "running" else { throw ConnectedArchiveError.runNotRunning(runID) }
        try faultHook?(.afterStaging)

        // 2. Publish: temp → fsync → atomic rename, hashed again while copied.
        let blob = try store.blobStore.write(contentsOf: item.raw.fileURL)
        guard blob.digest == item.raw.sha256 else {
            throw ConnectedArchiveError.stagedBytesMismatch(expected: item.raw.sha256, actual: blob.digest)
        }
        guard blob.length == item.raw.byteCount else {
            throw ConnectedArchiveError.stagedSizeMismatch(expected: item.raw.byteCount, actual: blob.length)
        }
        try faultHook?(.afterPublish)

        // 3. Commit.
        let outcome: CaptureOutcome
        if let existing = try await store.existingRemoteMessage(accountID: item.accountID, key: key) {
            // A repeated provider event: one record, new memberships only.
            // A record the user deleted stays deleted (no resurrection).
            let state: CaptureItemState = existing.emailExists ? .alreadyPreserved : .locallyDeleted
            let added = try await store.recordRepeatObservation(item, key: key, runID: runID, existing: existing, state: state)
            if existing.digest == blob.digest { try? await store.markRemotePresence(accountID: item.accountID, key: key, bytesMissing: false) }
            outcome = CaptureOutcome(identity: item.identity, state: state, emailID: existing.emailID,
                                     sha256: existing.digest, byteCount: existing.length, newMemberships: added)
        } else {
            // V4-04 (§5.2, T20): a message whose bytes cannot be parsed is
            // still PRESERVED — the record points at the published bytes and
            // carries the parse failure, so preserved and readable counts stay
            // distinct and the parse can be retried from the retained bytes.
            var item = item
            let email: MBOXParser.RawEmail
            // Sent mail is classified as for an import: the account's own
            // address is the sender to recognise (and a Sent folder / label
            // occurrence says so on its own).
            let ownAddress = (try? await store.connectedAccountAddress(accountID: item.accountID)) ?? ""
            do {
                email = try Self.record(from: blob, store: store, occurrences: item.occurrences,
                                        accountAddress: ownAddress, parseHook: parseFaultHook)
            } catch {
                item.metadata.extra[Self.parseErrorKey] = error.localizedDescription
                email = try Self.unreadableRecord(occurrences: item.occurrences, reason: error.localizedDescription)
            }
            let added = try await store.commitConnectedCapture(email, blob: blob, item: item, key: key, runID: runID)
            outcome = CaptureOutcome(identity: item.identity, state: .stored, emailID: email.id,
                                     sha256: blob.digest, byteCount: blob.length, newMemberships: added)
        }
        try faultHook?(.afterCommit)
        try? fm.removeItem(at: item.raw.fileURL)
        if outcome.state == .stored, let id = outcome.emailID, let storedObserver { await storedObserver(id) }
        return outcome
    }

    /// The archive record parsed from the PUBLISHED bytes (not the staging
    /// file). Labels and folders become memberships; provider flags stay in
    /// the connected projection, never in the archive's folders.
    static func record(from blob: BlobReference, store: SQLiteEmailStore,
                       occurrences: [RemoteFolderOccurrence],
                       accountAddress: String = "",
                       parseHook: (@Sendable (Data) throws -> Void)? = nil) throws -> MBOXParser.RawEmail {
        let data = try store.blobStore.read(blob)
        try parseHook?(data)
        // Decoded as the rest of the store decodes raw MIME (`rawMIME`):
        // UTF-8, else ISO-8859-1 — which maps every byte to one character, so
        // 8-bit Latin-1 mail keeps its "é" instead of U+FFFD.
        let text = Self.decodeRaw(data)
        // No temporary copy per attachment (as bulk import): the bytes stay in
        // the published blob and are read from there when needed.
        var email = try MBOXParser.processRawMessage(text, senderEmail: accountAddress, materializeAttachments: false)
        if occurrences.contains(where: Self.isSentOccurrence) { email.messageType = "sent" }
        let paths = occurrences.map(\.cleanPath).filter { !$0.isEmpty }
        email.folderPath = paths.first
        for path in paths.dropFirst() where !email.tags.contains(path) { email.tags.append(path) }
        return email
    }

    /// Raw message bytes as text, the store's way: UTF-8, else ISO-8859-1.
    static func decodeRaw(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// A Sent folder or label: Gmail's SENT label, an IMAP `\Sent` mailbox,
    /// Graph's sentitems well-known folder.
    static func isSentOccurrence(_ o: RemoteFolderOccurrence) -> Bool {
        let use = (o.specialUse ?? "").lowercased()
        if ["sent", "\\sent", "sentitems"].contains(use) { return true }
        return o.kind == .label && o.serverID == "SENT"
    }

    /// `remote_messages.metadata_json` key holding the reader failure of a
    /// preserved-but-unreadable connected message.
    public static let parseErrorKey = "mailinParseError"

    /// The record of a message whose bytes the reader could not parse: no
    /// header is invented (the parser's empty-input defaults only), the
    /// failure is an anomaly on the record, and the raw bytes stay the
    /// published blob.
    static func unreadableRecord(occurrences: [RemoteFolderOccurrence], reason: String) throws -> MBOXParser.RawEmail {
        var email = try MBOXParser.processRawMessage("", senderEmail: "", materializeAttachments: false)
        email.anomalies.append("connected-parse-failed: \(reason)")
        let paths = occurrences.map(\.cleanPath).filter { !$0.isEmpty }
        email.folderPath = paths.first
        for path in paths.dropFirst() where !email.tags.contains(path) { email.tags.append(path) }
        return email
    }

    // MARK: Checkpoints

    /// Advances the cursor for (account, scope) — only when every item this
    /// run listed has a terminal outcome.
    public func advanceCheckpoint(accountID: UUID, scope: String, cursor: String, bootstrapState: String = "",
                                  runID: String) async throws {
        let pending = try await store.pendingItemCount(runID: runID)
        guard pending == 0 else { throw ConnectedArchiveError.itemsNotTerminal(runID: runID, pending: pending) }
        try faultHook?(.beforeCheckpoint)
        try await store.writeCheckpoint(accountID: accountID, scope: scope, cursor: cursor,
                                        bootstrapState: bootstrapState, runID: runID)
    }

    public func checkpoint(accountID: UUID, scope: String) async throws -> SyncCheckpoint? {
        try await store.readCheckpoint(accountID: accountID, scope: scope)
    }

    // MARK: Restart

    /// Call once at launch, before any capture starts: removes staged bytes of
    /// captures that never committed, marks interrupted runs, and checks that
    /// every connected record's bytes are in the blob tier.
    public func reconcileAfterRestart() async throws -> ConnectedReconcileReport {
        let fm = FileManager.default
        var removed = 0
        if let files = try? fm.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("stage-") {
                if (try? fm.removeItem(at: file)) != nil { removed += 1 }
            }
        }
        let interrupted = try await store.markRunningRunsInterrupted()
        let rows = try await store.remoteMessageDigests()
        var missing = 0
        for row in rows where !store.blobStore.exists(BlobReference(digest: row.digest, length: 0)) {
            missing += 1
            try await store.markRemotePresence(accountID: row.account, key: row.key, bytesMissing: true)
        }
        return ConnectedReconcileReport(stagedFilesRemoved: removed, runsInterrupted: interrupted,
                                        recordsMissingBytes: missing, recordsChecked: rows.count)
    }

    // MARK: Provenance

    public func provenance(emailID: UUID) async throws -> ConnectedProvenance? {
        try await store.connectedProvenance(emailID: emailID)
    }

    /// Writes `mailin-connected-provenance.json` into a finished export
    /// folder: for every exported file of a connected message, the account
    /// (provider, issuer/tenant or host, display identity — never a
    /// credential), the provider identity, the folder/label memberships, the
    /// captured SHA-256 and whether the exported file is byte-identical to
    /// the captured bytes. Returns nil when the export holds no connected message.
    @discardableResult
    public func writeProvenanceSidecar(exportFolder: URL) async throws -> URL? {
        let inventory = try ExportInventory.load(folder: exportFolder)
        var entries: [ConnectedProvenanceSidecar.Entry] = []
        for file in inventory.files {
            guard let idText = file.emailID, let id = UUID(uuidString: idText),
                  let provenance = try await store.connectedProvenance(emailID: id) else { continue }
            entries.append(.init(path: file.path, fileSHA256: file.sha256,
                                 bytesIdenticalToCapture: file.sha256 == provenance.sha256, provenance: provenance))
        }
        guard !entries.isEmpty else { return nil }
        let sidecar = ConnectedProvenanceSidecar(createdAt: Date(), entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = exportFolder.appendingPathComponent(ConnectedProvenanceSidecar.filename)
        try encoder.encode(sidecar).write(to: url, options: .atomic)
        return url
    }

    /// The provenance sidecar of a CONTAINER export (mbox, PST), beside it as
    /// `<container>.mailin-connected-provenance.json`: one entry per record of
    /// the container's manifest that is connected mail, with its ordinal in
    /// the container. A container record is never the captured byte stream
    /// itself (mbox framing and `>From` quoting, PST properties), so
    /// `bytesIdenticalToCapture` is false and `fileSHA256` is the SHA-256 of
    /// the record's bytes in the container when the manifest locates them
    /// (mbox), else empty (PST). Returns nil when no record is connected mail
    /// or the container has no manifest.
    @discardableResult
    public func writeProvenanceSidecar(container: URL) async throws -> URL? {
        let manifestURL = ContainerManifest.url(for: container)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let connected = try await store.connectedEmailIDs()
        guard !connected.isEmpty else { return nil }
        var hits: [(ordinal: Int, id: String, offset: UInt64?, length: UInt64?)] = []
        try ContainerManifest.forEachLine(url: manifestURL) { line, _ in
            if line.kind == .record, let id = line.emailID, connected.contains(id) {
                hits.append((line.ordinal ?? hits.count, id, line.offset, line.length))
            }
            return true
        }
        var entries: [ConnectedProvenanceSidecar.Entry] = []
        let handle = try? FileHandle(forReadingFrom: container)
        defer { try? handle?.close() }
        for hit in hits {
            guard let id = UUID(uuidString: hit.id), let provenance = try await store.connectedProvenance(emailID: id) else { continue }
            var recordHash = ""
            if let handle, let offset = hit.offset, let length = hit.length {
                try handle.seek(toOffset: offset)
                var hasher = SHA256()
                var remaining = Int(length)
                while remaining > 0, let chunk = try handle.read(upToCount: min(remaining, 1 << 20)), !chunk.isEmpty {
                    hasher.update(data: chunk); remaining -= chunk.count
                }
                if remaining == 0 { recordHash = hasher.finalize().map { String(format: "%02x", $0) }.joined() }
            }
            entries.append(.init(path: container.lastPathComponent, fileSHA256: recordHash, bytesIdenticalToCapture: false,
                                 provenance: provenance, ordinal: hit.ordinal))
        }
        guard !entries.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = ConnectedProvenanceSidecar.url(forContainer: container)
        try encoder.encode(ConnectedProvenanceSidecar(createdAt: Date(), entries: entries)).write(to: url, options: .atomic)
        return url
    }
}

public struct ConnectedProvenanceSidecar: Codable, Sendable, Equatable {
    public static let filename = "mailin-connected-provenance.json"
    public struct Entry: Codable, Sendable, Equatable {
        public var path: String
        public var fileSHA256: String
        public var bytesIdenticalToCapture: Bool
        public var provenance: ConnectedProvenance
        /// Container exports: the record's ordinal within the container (nil for a per-message file).
        public var ordinal: Int? = nil
    }

    /// The sidecar of a container export, beside the container.
    public static func url(forContainer container: URL) -> URL {
        container.deletingLastPathComponent().appendingPathComponent(container.lastPathComponent + "." + filename)
    }
    public var version = 1
    public var createdAt: Date
    public var entries: [Entry]
}

/// Where connected-account metadata is persisted (MailConnectivity's
/// account registry writes through it). Every call is one transaction and
/// throws its failure; nothing is swallowed.
public protocol ConnectedAccountRecordStore: Sendable {
    func saveAccount(_ record: ConnectedAccountRecord) async throws
    func accountRecords() async throws -> [ConnectedAccountRecord]
}

extension ConnectedArchiveSink: ConnectedAccountRecordStore {}

extension SQLiteEmailStore {
    func runAccount(runID: String) throws -> (account: UUID, state: String) {
        try captureRunAccount(try ensureDB(), runID: runID)
    }
}
