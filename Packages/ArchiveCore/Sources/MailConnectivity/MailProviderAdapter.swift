//
//  MailProviderAdapter.swift
//  MailConnectivity
//
//  Plan v4 V4-04 (§5.2, §5.3): the ONE contract every connector (Gmail API,
//  Microsoft Graph, IMAP) implements. The adapter only talks to its provider;
//  ordering, durability, retries, fairness, checkpoints and completeness are
//  the `SyncEngine`'s job and must not be re-implemented in a connector.
//
//  Rules for implementers (read before writing a connector):
//   • Never ask the network on your own initiative: the engine calls the
//     policy (`NetworkPermission`) before every call it makes into you. Do
//     not add hidden retries, redirects to other hosts or background refresh.
//   • Pagination is COMPLETE: return every page; `nextPageToken == nil` /
//     `nextCursor == nil` means "this is really the end", never "enough".
//     No total caps (rule 6). Page size is a hint the engine passes in.
//   • Raw bytes are streamed into the `RawByteSink` as they arrive — never
//     buffered whole, never decoded to a String (Gmail: format=raw decoded
//     from base64url chunk by chunk; Graph: `/$value`; IMAP: the literal).
//   • Map provider failures onto `MailProviderError` exactly (429/503 with
//     Retry-After → `.rateLimited`, quota → `.quotaExceeded`, 401 →
//     `.unauthorized`, 404/gone for one message → `.itemUnavailable`,
//     expired history / invalid delta / UIDVALIDITY change → `.changeTokenExpired`).
//   • Cursors and change tokens are opaque strings the engine persists and
//     hands back verbatim after a restart; they must be resumable.
//

import ArchiveCore
import Foundation

// MARK: - Limits and scope

/// How a provider reports changes after the bootstrap.
public enum ChangeTracking: String, Sendable, Codable {
    /// One account-wide change log (Gmail history).
    case accountWide
    /// One change cursor per folder (Graph delta per folder, IMAP CONDSTORE/QRESYNC per mailbox).
    case perFolder
    /// No change log: every sync re-enumerates the selection (plain IMAP).
    case none
}

/// The provider's own constraints. Internal controls, not mailbox caps.
public struct ProviderLimits: Sendable, Equatable {
    /// Downloads this account may run at once (a provider fairness rule).
    public var maxConcurrentDownloads: Int
    /// Preferred enumeration page size.
    public var pageSize: Int
    public var changeTracking: ChangeTracking

    public init(maxConcurrentDownloads: Int = 4, pageSize: Int = 500, changeTracking: ChangeTracking) {
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
        self.pageSize = max(1, pageSize)
        self.changeTracking = changeTracking
    }
}

/// Where a change cursor applies.
public enum ChangeScope: Sendable, Hashable {
    case account
    case folder(RemoteFolderOccurrence)

    /// The `sync_checkpoints.scope` the engine stores the change cursor under.
    public var checkpointScope: String {
        switch self {
        case .account: return "sync"
        case .folder(let f): return "changes:\(f.serverID)"
        }
    }
}

// MARK: - Pages

public struct FolderPage: Sendable {
    /// Every folder / label on this page, empty ones included.
    public var folders: [RemoteFolderOccurrence]
    /// nil = the folder list is complete.
    public var nextPageToken: String?
    public init(folders: [RemoteFolderOccurrence], nextPageToken: String?) {
        self.folders = folders; self.nextPageToken = nextPageToken
    }
}

/// One listed message: its identity, where it was listed, and what the
/// provider knows about it without downloading it.
public struct RemoteItemRef: Sendable, Hashable {
    public var identity: ProviderMessageIdentity
    /// The folder / label the listing came from (nil for a change-log entry
    /// that names no folder).
    public var folder: RemoteFolderOccurrence?
    /// historyId / changeKey / MODSEQ, when listed.
    public var changeToken: String?
    /// Provider's size estimate, used for the disk check before download.
    public var sizeHint: Int64?
    /// REC-07: the date the listing states (Graph receivedDateTime, IMAP
    /// INTERNALDATE), when it states one. nil = not known before download.
    public var receivedAt: Date?
    /// REC-07: the sender address the listing states, when it states one.
    public var sender: String?

    public init(identity: ProviderMessageIdentity, folder: RemoteFolderOccurrence?, changeToken: String? = nil, sizeHint: Int64? = nil,
                receivedAt: Date? = nil, sender: String? = nil) {
        self.identity = identity; self.folder = folder; self.changeToken = changeToken; self.sizeHint = sizeHint
        self.receivedAt = receivedAt; self.sender = sender
    }
}

public struct EnumerationPage: Sendable {
    public var items: [RemoteItemRef]
    /// Resume point AFTER this page; nil = the folder is fully enumerated.
    /// Persisted verbatim and passed back after a restart.
    public var nextCursor: String?
    public init(items: [RemoteItemRef], nextCursor: String?) {
        self.items = items; self.nextCursor = nextCursor
    }
}

/// What the download returns besides the bytes it streamed.
public struct FetchedItemMetadata: Sendable {
    /// Every folder / label the provider reports the message in NOW
    /// (Gmail labelIds, Graph parentFolderId, IMAP mailbox).
    public var occurrences: [RemoteFolderOccurrence]
    public var metadata: ProviderMetadata
    /// When the provider states the exact size, a short stream is a transfer
    /// failure (retried), never a preserved message.
    public var expectedByteCount: Int64?

    public init(occurrences: [RemoteFolderOccurrence], metadata: ProviderMetadata, expectedByteCount: Int64? = nil) {
        self.occurrences = occurrences; self.metadata = metadata; self.expectedByteCount = expectedByteCount
    }
}

public enum RemoteChange: Sendable {
    /// New message, or new / changed membership. `occurrences` is the
    /// message's membership as the change reports it.
    case upserted(RemoteItemRef, occurrences: [RemoteFolderOccurrence])
    /// The message no longer exists on the server (expunged / hard-deleted /
    /// moved out of every selected scope).
    case deleted(ProviderMessageIdentity)
}

public struct ChangePage: Sendable {
    public var changes: [RemoteChange]
    /// Opaque resume token after this page: the next `changes(since:)`
    /// argument (encode page token + start point if the provider needs both).
    public var resume: String
    /// false = `resume` is the new reconciliation point (history id / delta link).
    public var hasMore: Bool
    public init(changes: [RemoteChange], resume: String, hasMore: Bool) {
        self.changes = changes; self.resume = resume; self.hasMore = hasMore
    }
}

// MARK: - Request context and errors

/// Passed into every adapter call. The engine obtained the token through the
/// single-flight `TokenRefreshCoordinator`, for `tokenAudience` only.
public struct ProviderRequestContext: Sendable {
    public var accountID: UUID
    /// nil for adapters that authenticate themselves (IMAP with an app password).
    public var accessToken: String?
    /// 0 for the first attempt of this request, then 1, 2 …
    public var attempt: Int
    public init(accountID: UUID, accessToken: String?, attempt: Int) {
        self.accountID = accountID; self.accessToken = accessToken; self.attempt = attempt
    }
}

public enum MailProviderError: Error, Sendable, Equatable {
    /// 429 / 503 / throttling. Retry after `retryAfter` seconds when given.
    case rateLimited(retryAfter: TimeInterval?)
    /// Daily / mailbox quota exhausted: the ACCOUNT pauses until `resetAfter`.
    case quotaExceeded(resetAfter: TimeInterval?)
    /// Timeouts, resets, 5xx: retried with exponential backoff.
    case transient(String)
    /// 401 / AUTHENTICATIONFAILED: the engine refreshes once, then asks for sign-in.
    case unauthorized
    /// Sign-in is required (revoked grant, app password changed).
    case reauthorisationRequired
    /// This one message is gone (404 / deleted / expunged) — recorded
    /// `unavailable`, never `captured`.
    case itemUnavailable
    /// History / delta / UIDVALIDITY no longer valid: full reconciliation.
    case changeTokenExpired
    /// The folder vanished / was renamed mid-enumeration.
    case folderUnavailable(String)
    /// Will not succeed by retrying (malformed response, forbidden).
    case permanent(String)
}

// MARK: - Byte stream

/// Where an adapter streams one message's raw bytes: an owner-only staging
/// file, hashed while written (`StagingWriter`). Thread-safe.
public final class RawByteSink: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: StagingWriter
    private var written: Int64 = 0

    init(writer: StagingWriter) { self.writer = writer }

    /// The staging file (owner-only) the bytes go to.
    public var fileURL: URL { writer.fileURL }

    /// Appends the next chunk exactly as received.
    public func write(_ chunk: Data) throws {
        try lock.withLock {
            try Task.checkCancellation()
            try writer.append(chunk)
            written += Int64(chunk.count)
        }
    }

    public var bytesWritten: Int64 { lock.withLock { written } }

    func finish() throws -> StagedRawMessage { try lock.withLock { try writer.finish() } }
    func discard() { lock.withLock { writer.discard() } }
}

// MARK: - The adapter

public protocol MailProviderAdapter: Sendable {
    var accountID: UUID { get }
    var provider: MailProviderKind { get }
    /// The provider API / IMAP host every capture request goes to (policy check).
    var mailHost: String { get }
    /// OAuth token endpoint host (policy check before a refresh); nil without OAuth.
    var authorizationHost: String? { get }
    /// The token audience the engine requests; nil = the adapter authenticates itself.
    var tokenAudience: String? { get }

    func limits() async -> ProviderLimits

    /// One page of the account's folders / labels. Called until `nextPageToken` is nil.
    func listFolders(pageToken: String?, context: ProviderRequestContext) async throws -> FolderPage

    /// One page of `folder`'s messages after `cursor` (nil = from the start).
    func enumerate(folder: RemoteFolderOccurrence, cursor: String?, pageSize: Int,
                   context: ProviderRequestContext) async throws -> EnumerationPage

    /// Streams the message's COMPLETE raw MIME into `sink` and returns its
    /// metadata. Throws `.itemUnavailable` when the message is gone.
    func fetchRaw(_ item: RemoteItemRef, into sink: RawByteSink, context: ProviderRequestContext) async throws -> FetchedItemMetadata

    /// The provider's current change point for `scope`, taken BEFORE the
    /// bootstrap enumerates it (Gmail: profile historyId; Graph: a delta
    /// link obtained with $deltatoken=latest; IMAP: UIDVALIDITY + HIGHESTMODSEQ/UIDNEXT).
    /// Throws `.permanent` for `.none` tracking (never called then).
    func changeBoundary(scope: ChangeScope, context: ProviderRequestContext) async throws -> String

    /// Changes after `token`, one page at a time. `.changeTokenExpired`
    /// triggers a full reconciliation.
    func changes(scope: ChangeScope, since token: String, context: ProviderRequestContext) async throws -> ChangePage
}

// MARK: - Network policy and credentials

/// The kind of network step the engine is about to take (the app maps it
/// onto `MailNetworkOperation`).
public enum SyncNetworkOperation: String, Sendable, CaseIterable {
    case request, download, retry, oauthRefresh
}

/// Asked before EVERY adapter call and token fetch, including retries.
public struct NetworkAsk: Sendable, Equatable {
    public enum Destination: String, Sendable { case mailServer, authorization }
    public var accountID: UUID
    public var host: String
    public var destination: Destination
    public var operation: SyncNetworkOperation
    public init(accountID: UUID, host: String, destination: Destination, operation: SyncNetworkOperation) {
        self.accountID = accountID; self.host = host; self.destination = destination; self.operation = operation
    }
}

/// Throws (any error) to refuse. The app wires `MailNetworkPolicy.permit`
/// with purpose `.preserveMail`; a refusal stops the account's sync without
/// a retry loop.
public typealias NetworkPermission = @Sendable (NetworkAsk) throws -> Void

/// Access tokens per account and audience, single-flight refreshed.
/// `TokenRefreshCoordinator` conforms.
public protocol AccessTokenSource: Sendable {
    func accessToken(for account: UUID, audience: String) async throws -> String
    func refreshAfterRejection(account: UUID, audience: String) async throws -> String
}

extension TokenRefreshCoordinator: AccessTokenSource {}
