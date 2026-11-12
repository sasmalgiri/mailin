//
//  DraftStore.swift
//  MailConnectivity
//
//  Plan v4 V4-09 / T31: durable drafts in protected storage under the
//  archive store's directory:
//
//      <store>/ConnectedDrafts/            0700
//          <draft UUID>/                   0700
//              draft.json                  0600  (the draft, atomically replaced)
//              attachments/<attachment UUID> 0600 (copied bytes, SHA-256 recorded)
//
//  Every write goes to a temporary file in the same folder, is flushed to
//  the disk (F_FULLFSYNC), then renamed over the old file and the folder is
//  flushed — so a process killed at any instant leaves either the previous
//  revision or the new one, never a torn draft. Attachment bytes are
//  published before the draft that names them, so a restored draft never
//  names a file that is not there. Temporary files left by a killed save are
//  swept on open; attachment copies a killed save published but never
//  recorded are reported (not deleted). A referenced (not copied) file is
//  verified by SHA-256 before use and reported unavailable — never silently
//  dropped — when it is missing or changed. No size limit: bytes are copied
//  and hashed in 1 MiB chunks.
//

import CryptoKit
import Foundation

public struct DraftAttachmentPayload: Sendable, Equatable {
    public var filename: String
    public var mimeType: String
    public var disposition: DraftAttachment.Disposition
    public var contentID: String?
    public var data: Data
    public init(filename: String, mimeType: String, disposition: DraftAttachment.Disposition = .attachment, contentID: String? = nil, data: Data) {
        self.filename = filename; self.mimeType = mimeType; self.disposition = disposition; self.contentID = contentID; self.data = data
    }
}

/// A draft not yet saved plus the attachment bytes it starts with (a forward's originals).
public struct DraftSeed: Sendable {
    public var draft: Draft
    public var attachments: [DraftAttachmentPayload]
    public init(draft: Draft, attachments: [DraftAttachmentPayload] = []) { self.draft = draft; self.attachments = attachments }
}

public enum DraftAttachmentAvailability: Sendable, Equatable {
    case available
    case unavailable(DraftAttachment.Unavailable)
}

public struct DraftListing: Sendable {
    public var drafts: [Draft]
    /// Draft folders whose draft.json could not be read, with the reason.
    public var unreadable: [(id: String, reason: String)]
    /// Attachment copies on disk that no saved draft names (a save killed after publishing them).
    public var unrecordedAttachmentFiles: Int
}

public enum DraftStoreError: LocalizedError, Equatable {
    case notFound(UUID)
    case staleRevision(draft: UUID, saved: Int, given: Int)
    case corrupt(String)
    case newerFormat(Int)
    case io(String)
    case attachmentNotInDraft(UUID)
    case attachmentUnavailable(name: String, DraftAttachment.Unavailable)
    case attachmentCorrupted(name: String)
    /// Tests only: the process "was killed" at this point.
    case simulatedInterruption(DraftStore.FaultPoint)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "The draft no longer exists."
        case .staleRevision(_, let saved, let given): return "A newer version of this draft was saved (version \(saved)); this edit was based on version \(given)."
        case .corrupt(let why): return "A saved draft could not be read: \(why)."
        case .newerFormat(let v): return "This draft was saved by a newer version of mailin (format \(v))."
        case .io(let why): return "The draft could not be saved: \(why)"
        case .attachmentNotInDraft: return "That attachment is not part of this draft."
        case .attachmentUnavailable(let name, let why):
            switch why {
            case .missing: return "The attached file “\(name)” is no longer where it was."
            case .changedSinceAttached: return "The attached file “\(name)” has changed since it was attached."
            case .unreadable(let detail): return "The attached file “\(name)” cannot be read: \(detail)."
            }
        case .attachmentCorrupted(let name): return "The stored copy of “\(name)” is damaged."
        case .simulatedInterruption(let p): return "Interrupted at \(p)."
        }
    }
}

public actor DraftStore {
    public enum FaultPoint: String, Sendable {
        /// Half an attachment written to its temporary file.
        case attachmentPartiallyWritten
        /// Attachment fully written and flushed, not yet published (renamed).
        case attachmentWrittenNotPublished
        /// Attachment published, draft naming it not yet saved.
        case attachmentPublishedDraftNotSaved
        /// New draft.json written and flushed to its temporary file, not yet renamed.
        case draftWrittenNotPublished
        /// Half of the new draft.json written.
        case draftPartiallyWritten
    }

    public static let folderName = "ConnectedDrafts"
    static let chunk = 1 << 20

    public nonisolated let root: URL
    private var fault: FaultPoint?

    /// `storeDirectory` is the archive store's directory; drafts live in its
    /// `ConnectedDrafts` folder (owner-only).
    public init(storeDirectory: URL) throws {
        root = storeDirectory.appendingPathComponent(Self.folderName, isDirectory: true)
        try Self.makeProtectedDirectory(root)
        Self.sweepTemporaryFiles(under: root)
    }

    /// Tests only: the next pass through `point` throws `.simulatedInterruption`
    /// without cleaning up — what a killed process leaves behind.
    func injectFault(_ point: FaultPoint?) { fault = point }

    private func check(_ point: FaultPoint) throws {
        if fault == point { fault = nil; throw DraftStoreError.simulatedInterruption(point) }
    }

    // MARK: Paths

    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func draftFile(_ id: UUID) -> URL { folder(id).appendingPathComponent("draft.json") }
    func attachmentsFolder(_ id: UUID) -> URL { folder(id).appendingPathComponent("attachments", isDirectory: true) }

    // MARK: Drafts

    /// Saves (autosaves) a draft. The draft's `revision` must equal the saved
    /// one (0 for a new draft); the stored revision becomes revision + 1.
    /// Attachment copies the draft no longer names are removed after the save.
    @discardableResult
    public func save(_ draft: Draft) throws -> Draft {
        try draft.validate()
        let saved = try? load(draft.id)
        let savedRevision = saved?.revision ?? 0
        guard savedRevision == draft.revision else {
            throw DraftStoreError.staleRevision(draft: draft.id, saved: savedRevision, given: draft.revision)
        }
        for att in draft.attachments {
            if case .copied(let rel) = att.storage, !FileManager.default.fileExists(atPath: folder(draft.id).appendingPathComponent(rel).path) {
                throw DraftStoreError.attachmentUnavailable(name: att.filename, .missing)
            }
        }
        var next = draft
        next.revision = draft.revision + 1
        next.updatedAt = Date()
        try Self.makeProtectedDirectory(folder(draft.id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data: Data
        do { data = try encoder.encode(next) } catch { throw DraftStoreError.io(error.localizedDescription) }
        try writeDurably(data, to: draftFile(draft.id), partial: .draftPartiallyWritten, beforePublish: .draftWrittenNotPublished)
        // Copies no longer named: removed only after the new draft is durable.
        let kept = Set(next.attachments.compactMap { a -> String? in if case .copied(let r) = a.storage { return r }; return nil })
        for old in saved?.attachments ?? [] {
            if case .copied(let rel) = old.storage, !kept.contains(rel) {
                try? FileManager.default.removeItem(at: folder(draft.id).appendingPathComponent(rel))
            }
        }
        return next
    }

    /// Creates a draft with its starting attachments (a forward's originals):
    /// every attachment is copied and published first, then the draft is
    /// saved once — a kill before that leaves no half-built draft.
    public func create(_ seed: DraftSeed) throws -> Draft {
        var draft = seed.draft
        guard draft.revision == 0 else { throw DraftStoreError.staleRevision(draft: draft.id, saved: 0, given: draft.revision) }
        for payload in seed.attachments {
            draft.attachments.append(try storeBytes(payload.data, filename: payload.filename, mimeType: payload.mimeType,
                                                    disposition: payload.disposition, contentID: payload.contentID, draftID: draft.id))
        }
        return try save(draft)
    }

    public func draft(_ id: UUID) throws -> Draft { try load(id) }

    func load(_ id: UUID) throws -> Draft {
        let url = draftFile(id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw DraftStoreError.notFound(id) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw DraftStoreError.io(error.localizedDescription) }
        let draft: Draft
        do { draft = try JSONDecoder().decode(Draft.self, from: data) } catch {
            throw DraftStoreError.corrupt("\(id.uuidString): \(error.localizedDescription)")
        }
        guard draft.formatVersion <= Draft.formatVersion else { throw DraftStoreError.newerFormat(draft.formatVersion) }
        guard draft.id == id else { throw DraftStoreError.corrupt("\(id.uuidString) holds draft \(draft.id.uuidString)") }
        return draft
    }

    /// Every saved draft (newest first). Unreadable drafts are listed with a
    /// reason, never hidden; leftover temporary files are swept first.
    public func drafts() -> DraftListing {
        Self.sweepTemporaryFiles(under: root)
        var out: [Draft] = []
        var unreadable: [(String, String)] = []
        var unrecorded = 0
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for f in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: f.lastPathComponent) else { continue }
            let attFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: attachmentsFolder(id).path)) ?? [])
            do {
                let d = try load(id)
                out.append(d)
                let named = Set(d.attachments.compactMap { a -> String? in
                    if case .copied(let r) = a.storage { return (r as NSString).lastPathComponent }; return nil
                })
                unrecorded += attFiles.subtracting(named).count
            } catch DraftStoreError.notFound {
                unrecorded += attFiles.count   // a creation killed before its first save
            } catch {
                unreadable.append((id.uuidString, error.localizedDescription))
            }
        }
        out.sort { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
        return DraftListing(drafts: out, unreadable: unreadable, unrecordedAttachmentFiles: unrecorded)
    }

    /// The user discarded the draft: its folder (and copies) are removed.
    public func discard(_ id: UUID) throws {
        let f = folder(id)
        guard FileManager.default.fileExists(atPath: f.path) else { return }
        do { try FileManager.default.removeItem(at: f) } catch { throw DraftStoreError.io(error.localizedDescription) }
    }

    // MARK: Attachments

    /// Copies a file into protected draft storage (hashing as it copies) and
    /// saves the draft with it. Returns the saved draft.
    public func addAttachment(copying file: URL, to draft: Draft, mimeType: String? = nil,
                              disposition: DraftAttachment.Disposition = .attachment, contentID: String? = nil) throws -> Draft {
        let attID = UUID()
        let dir = attachmentsFolder(draft.id)
        try Self.makeProtectedDirectory(folder(draft.id))
        try Self.makeProtectedDirectory(dir)
        let finalURL = dir.appendingPathComponent(attID.uuidString)
        let tmp = dir.appendingPathComponent(".\(attID.uuidString).partial")
        guard let input = try? FileHandle(forReadingFrom: file) else { throw DraftStoreError.attachmentUnavailable(name: file.lastPathComponent, .missing) }
        defer { try? input.close() }
        let output = try Self.createProtectedFile(tmp)
        var hasher = SHA256()
        var size: Int64 = 0
        do {
            defer { try? output.close() }
            while true {
                let piece: Data
                do { piece = try input.read(upToCount: Self.chunk) ?? Data() } catch {
                    throw DraftStoreError.attachmentUnavailable(name: file.lastPathComponent, .unreadable(error.localizedDescription))
                }
                if piece.isEmpty { break }
                hasher.update(data: piece)
                do { try output.write(contentsOf: piece) } catch { throw DraftStoreError.io(error.localizedDescription) }
                size += Int64(piece.count)
                if size >= Int64(Self.chunk) { try check(.attachmentPartiallyWritten) }
            }
            try Self.flush(output)
        }
        try check(.attachmentWrittenNotPublished)
        try Self.publish(tmp, as: finalURL)
        try check(.attachmentPublishedDraftNotSaved)
        var next = draft
        next.attachments.append(DraftAttachment(id: attID, filename: file.lastPathComponent,
                                                mimeType: mimeType ?? Self.mimeType(forExtension: file.pathExtension), size: size,
                                                sha256: Self.hex(hasher.finalize()), disposition: disposition, contentID: contentID,
                                                storage: .copied(relativePath: "attachments/\(attID.uuidString)")))
        return try save(next)
    }

    /// Adds bytes (an original message's attachment) and saves the draft.
    public func addAttachment(_ payload: DraftAttachmentPayload, to draft: Draft) throws -> Draft {
        var next = draft
        next.attachments.append(try storeBytes(payload.data, filename: payload.filename, mimeType: payload.mimeType,
                                               disposition: payload.disposition, contentID: payload.contentID, draftID: draft.id))
        return try save(next)
    }

    /// Records a reference to a file left in place (the user chose not to
    /// copy it), with its SHA-256 so a later change is detected.
    public func addReference(to file: URL, in draft: Draft, mimeType: String? = nil) throws -> Draft {
        let (size, sha) = try Self.hashFile(file, name: file.lastPathComponent)
        let bookmark = try? file.bookmarkData()
        var next = draft
        next.attachments.append(DraftAttachment(filename: file.lastPathComponent, mimeType: mimeType ?? Self.mimeType(forExtension: file.pathExtension),
                                                size: size, sha256: sha, storage: .reference(path: file.path, bookmark: bookmark)))
        return try save(next)
    }

    private func storeBytes(_ data: Data, filename: String, mimeType: String, disposition: DraftAttachment.Disposition,
                            contentID: String?, draftID: UUID) throws -> DraftAttachment {
        let attID = UUID()
        let dir = attachmentsFolder(draftID)
        try Self.makeProtectedDirectory(folder(draftID))
        try Self.makeProtectedDirectory(dir)
        try writeDurably(data, to: dir.appendingPathComponent(attID.uuidString), partial: .attachmentPartiallyWritten,
                         beforePublish: .attachmentWrittenNotPublished)
        try check(.attachmentPublishedDraftNotSaved)
        return DraftAttachment(id: attID, filename: filename, mimeType: mimeType, size: Int64(data.count),
                               sha256: Self.hex(SHA256.hash(data: data)), disposition: disposition, contentID: contentID,
                               storage: .copied(relativePath: "attachments/\(attID.uuidString)"))
    }

    /// Whether the attachment's bytes can be used now, verified by SHA-256.
    public func availability(of attachment: DraftAttachment, in draftID: UUID) -> DraftAttachmentAvailability {
        do { _ = try bytes(of: attachment, in: draftID); return .available } catch DraftStoreError.attachmentUnavailable(_, let why) {
            return .unavailable(why)
        } catch DraftStoreError.attachmentCorrupted {
            return .unavailable(.unreadable("the stored copy is damaged"))
        } catch {
            return .unavailable(.unreadable(error.localizedDescription))
        }
    }

    /// The attachment's bytes, verified against the recorded SHA-256.
    public func bytes(of attachment: DraftAttachment, in draftID: UUID) throws -> Data {
        switch attachment.storage {
        case .copied(let rel):
            let url = folder(draftID).appendingPathComponent(rel)
            guard let data = try? Data(contentsOf: url) else { throw DraftStoreError.attachmentUnavailable(name: attachment.filename, .missing) }
            guard Self.hex(SHA256.hash(data: data)) == attachment.sha256 else { throw DraftStoreError.attachmentCorrupted(name: attachment.filename) }
            return data
        case .reference(let path, let bookmark):
            var url = URL(fileURLWithPath: path)
            if let bookmark {
                var stale = false
                if let resolved = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) { url = resolved }
            }
            guard FileManager.default.fileExists(atPath: url.path) else { throw DraftStoreError.attachmentUnavailable(name: attachment.filename, .missing) }
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                throw DraftStoreError.attachmentUnavailable(name: attachment.filename, .unreadable(error.localizedDescription))
            }
            let found = Self.hex(SHA256.hash(data: data))
            guard found == attachment.sha256 else {
                throw DraftStoreError.attachmentUnavailable(name: attachment.filename, .changedSinceAttached(expectedSHA256: attachment.sha256, foundSHA256: found))
            }
            return data
        }
    }

    // MARK: Composition

    /// Authorises the sender (T34 — before any attachment is read), then
    /// composes the draft's RFC 5322 bytes once.
    public func compose(_ draftID: UUID, account: MailAccount, identities: [SendingIdentity], date: Date) throws -> ComposedMessage {
        let draft = try load(draftID)
        let sender = try SenderAuthorisation.authorise(draft, account: account, identities: identities)
        return try MIMEComposer.compose(draft, sender: sender, date: date) { att in try self.bytes(of: att, in: draftID) }
    }

    // MARK: Durable file primitives

    private func writeDurably(_ data: Data, to url: URL, partial: FaultPoint, beforePublish: FaultPoint) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let handle = try Self.createProtectedFile(tmp)
        do {
            defer { try? handle.close() }
            if fault == partial {
                try? handle.write(contentsOf: data.prefix(data.count / 2))
                try Self.flush(handle)
                try check(partial)
            }
            do { try handle.write(contentsOf: data) } catch { throw DraftStoreError.io(error.localizedDescription) }
            try Self.flush(handle)
        }
        try check(beforePublish)
        try Self.publish(tmp, as: url)
    }

    static func createProtectedFile(_ url: URL) throws -> FileHandle {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes) else {
            throw DraftStoreError.io("could not create \(url.lastPathComponent)")
        }
        do { return try FileHandle(forWritingTo: url) } catch { throw DraftStoreError.io(error.localizedDescription) }
    }

    static func flush(_ handle: FileHandle) throws {
        // F_FULLFSYNC asks the drive itself to flush, not only the OS cache.
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 {
            do { try handle.synchronize() } catch { throw DraftStoreError.io(error.localizedDescription) }
        }
    }

    /// rename(2) replaces atomically; the folder is then flushed so the new name is durable.
    static func publish(_ tmp: URL, as url: URL) throws {
        guard rename(tmp.path, url.path) == 0 else { throw DraftStoreError.io(String(cString: strerror(errno))) }
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
    }

    static func makeProtectedDirectory(_ url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
            }
        } catch { throw DraftStoreError.io(error.localizedDescription) }
    }

    /// Removes `.tmp` / `.partial` files a killed save left behind — they were never named by any draft.
    static func sweepTemporaryFiles(under root: URL) {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".tmp") || name.hasSuffix(".partial") { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func hashFile(_ url: URL, name: String) throws -> (Int64, String) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw DraftStoreError.attachmentUnavailable(name: name, .missing) }
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let piece: Data
            do { piece = try handle.read(upToCount: chunk) ?? Data() } catch {
                throw DraftStoreError.attachmentUnavailable(name: name, .unreadable(error.localizedDescription))
            }
            if piece.isEmpty { break }
            hasher.update(data: piece)
            size += Int64(piece.count)
        }
        return (size, hex(hasher.finalize()))
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        case "csv": return "text/csv"
        case "eml": return "message/rfc822"
        case "zip": return "application/zip"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default: return "application/octet-stream"
        }
    }
}
