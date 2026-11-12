//
//  IMAPActionExecutor.swift
//  MailConnectivity
//
//  Plan v4 V4-11 (§3 A17, T42): IMAP server actions, by UID only, on the
//  adapter's own connection pool.
//
//    read / unread / flag / unflag   UID STORE <uid> ±FLAGS.SILENT (\Seen | \Flagged)
//    move / Trash / restore          UID MOVE <uid> <dest>            (MOVE offered)
//                                    else UID COPY <uid> <dest>
//                                         UID STORE <uid> +FLAGS.SILENT (\Deleted)
//                                         UID EXPUNGE <uid>          (UIDPLUS offered)
//                                    else REFUSED with an explanation.
//
//  A mailbox-wide `EXPUNGE` is never sent: it would also remove every
//  message another client had marked \Deleted (the old app's A17 defect).
//  Every command names exactly the one UID of the identity, under the
//  identity's UIDVALIDITY — a changed UIDVALIDITY means the UID may name a
//  different message, so the item is treated as gone (a conflict).
//

import ArchiveCore
import Foundation

public struct IMAPActionExecutor: RemoteActionExecutor {
    public let accountID: UUID
    public let provider: MailProviderKind = .imap
    let adapter: IMAPAdapter
    /// The account's Trash mailbox (LIST SPECIAL-USE \Trash); nil = none known.
    public let trashMailbox: String?
    let permission: NetworkPermission

    public init(adapter: IMAPAdapter, trashMailbox: String?, permission: @escaping NetworkPermission) {
        self.adapter = adapter; self.accountID = adapter.accountID; self.trashMailbox = trashMailbox; self.permission = permission
    }

    public static let noTargetedRemoval =
        "This mail server offers neither MOVE nor UIDPLUS, so mailin cannot remove only the selected message from the folder "
        + "without also erasing other messages marked for deletion. Nothing was changed; move or delete it in your mail app instead."

    private func ask() throws {
        do {
            try permission(NetworkAsk(accountID: accountID, host: adapter.mailHost, destination: .mailServer, operation: .request))
        } catch { throw RemoteRequestFailure.notSent(.networkNotPermitted(error.localizedDescription)) }
    }

    private func parts(_ identity: ProviderMessageIdentity) throws -> (mailbox: String, validity: UInt32, uid: UInt32) {
        guard case .imap(let m, let v, let u) = identity else { throw RemoteRequestFailure.notSent(.accountMismatch) }
        return (m, v, u)
    }

    /// The destination of a move-like change; nil for flag changes.
    func destination(_ request: RemoteChangeRequest) -> String? {
        switch request {
        case .move(_, let to): return to
        case .moveToTrash: return trashMailbox
        case .restoreFromTrash(let to): return to
        default: return nil
        }
    }

    // MARK: Contract

    public func resolve(_ request: RemoteChangeRequest, precondition: RemotePrecondition,
                        for identity: ProviderMessageIdentity) async throws -> ResolvedChange {
        let (mailbox, _, _) = try parts(identity)
        switch request {
        case .addLabel, .removeLabel:
            throw RemoteRequestFailure.notSent(.unsupported("IMAP folders are changed with Move; labels are a Gmail feature."))
        case .archiveOnServer:
            throw RemoteRequestFailure.notSent(.unsupported("For this server, move the message to its Archive folder."))
        case .move(let from, let to):
            guard from == mailbox else { throw RemoteRequestFailure.notSent(.unsupported("The message is in \(mailbox), not \(from).")) }
            guard to != from else { throw RemoteRequestFailure.notSent(.unsupported("The message is already in \(to).")) }
        case .moveToTrash(let from):
            guard from == mailbox else { throw RemoteRequestFailure.notSent(.unsupported("The message is in \(mailbox), not \(from).")) }
            guard let trash = trashMailbox else {
                throw RemoteRequestFailure.notSent(.unsupported("This server reports no Trash folder; choose Move and pick the folder."))
            }
            guard trash != mailbox else { throw RemoteRequestFailure.notSent(.unsupported("The message is already in Trash.")) }
        case .restoreFromTrash(let to):
            guard to != nil else { throw RemoteRequestFailure.notSent(.unsupported("Choose the folder to restore the message into.")) }
            guard let trash = trashMailbox, trash == mailbox else {
                throw RemoteRequestFailure.notSent(.unsupported("The message is not in this server's Trash folder."))
            }
        default: break
        }
        return ResolvedChange(request: request, precondition: precondition)
    }

    public func state(of identity: ProviderMessageIdentity) async throws -> RemoteItemState {
        let (mailbox, validity, uid) = try parts(identity)
        try ask()
        let trash = trashMailbox
        let adapter = self.adapter
        do {
            return try await adapter.withActionSession { s in
                let wire = await adapter.actionWire(mailbox, utf8: await s.utf8Enabled)
                let status: IMAPMailboxStatus
                do { status = try await s.examine(wire, force: true) } catch MailProviderError.folderUnavailable {
                    throw RemoteRequestFailure.gone
                }
                guard status.uidValidity == validity else { throw RemoteRequestFailure.gone }
                guard let flags = try await Self.flags(s, uid) else { throw RemoteRequestFailure.gone }
                let upper = Set(flags.map { $0.uppercased() })
                return RemoteItemState(exists: true, isRead: upper.contains("\\SEEN"), isFlagged: upper.contains("\\FLAGGED"),
                                       folders: [mailbox], inTrash: mailbox == trash)
            }
        } catch let f as RemoteRequestFailure { throw f } catch {
            throw RemoteRequestFailure.refused(IMAPAdapter.map(error).localizedDescription)
        }
    }

    public func apply(_ change: ResolvedChange, to identity: ProviderMessageIdentity, before: RemoteItemState) async throws -> ProviderMessageIdentity? {
        let (mailbox, validity, uid) = try parts(identity)
        try ask()
        let destination = self.destination(change.request)
        let adapter = self.adapter
        let request = change.request
        do {
            return try await adapter.withActionSession { s in
                let utf8 = await s.utf8Enabled
                let caps = await s.capabilities
                // Decided BEFORE anything is changed: no targeted removal → refuse.
                if destination != nil, !caps.has("MOVE"), !caps.has("UIDPLUS") {
                    throw RemoteRequestFailure.notSent(.targetedRemovalUnavailable(Self.noTargetedRemoval))
                }
                try await Self.select(s, await adapter.actionWire(mailbox, utf8: utf8), validity: validity)
                switch request {
                case .markRead: try await Self.store(s, uid, "+FLAGS.SILENT (\\Seen)"); return nil
                case .markUnread: try await Self.store(s, uid, "-FLAGS.SILENT (\\Seen)"); return nil
                case .flag: try await Self.store(s, uid, "+FLAGS.SILENT (\\Flagged)"); return nil
                case .unflag: try await Self.store(s, uid, "-FLAGS.SILENT (\\Flagged)"); return nil
                default: break
                }
                guard let destination else { throw RemoteRequestFailure.notSent(.unsupported("Not offered for IMAP accounts.")) }
                let destWire = await adapter.actionWire(destination, utf8: utf8)
                if caps.has("MOVE") {
                    let r = try await Self.command(s, [.raw("UID MOVE \(uid)"), .string(destWire)])
                    guard r.completion.status == .ok else { throw Self.refusal(r, "move") }
                    let moved = Self.copyUID(r, source: uid, mailbox: destination)
                    // A UID command on a UID that no longer exists succeeds and does
                    // nothing: no COPYUID and no EXPUNGE means another client took it first.
                    let expunged = r.untagged.contains { if case .numbered(_, "EXPUNGE") = $0 { return true }; return false }
                    if moved == nil && !expunged { throw RemoteRequestFailure.gone }
                    return moved
                }
                // UIDPLUS: COPY, mark exactly this UID, expunge exactly this UID.
                let copied = try await Self.command(s, [.raw("UID COPY \(uid)"), .string(destWire)])
                guard copied.completion.status == .ok else { throw Self.refusal(copied, "copy") }
                guard let newIdentity = Self.copyUID(copied, source: uid, mailbox: destination) else {
                    throw RemoteRequestFailure.gone          // nothing was copied: the UID is gone
                }
                do {
                    try await Self.store(s, uid, "+FLAGS.SILENT (\\Deleted)")
                    let expunged = try await Self.command(s, [.raw("UID EXPUNGE \(uid)")])
                    guard expunged.completion.status == .ok else {
                        // Leave no pending deletion behind for another client's EXPUNGE.
                        _ = try? await Self.command(s, [.raw("UID STORE \(uid) -FLAGS.SILENT (\\Deleted)")])
                        throw RemoteRequestFailure.uncertain("the message was copied to \(destination) but the original could not be removed (\(expunged.completion.text)); both copies exist")
                    }
                } catch {
                    if case RemoteRequestFailure.uncertain = error { throw error }
                    throw RemoteRequestFailure.uncertain("the message was copied to \(destination) but the original could not be removed; both copies may exist")
                }
                return newIdentity
            }
        } catch let f as RemoteRequestFailure { throw f } catch {
            throw RemoteRequestFailure.uncertain("the connection to \(adapter.mailHost) failed during the change (\(IMAPAdapter.map(error).localizedDescription))")
        }
    }

    public func verify(_ change: ResolvedChange, original: ProviderMessageIdentity,
                       resulting: ProviderMessageIdentity?) async throws -> RemoteVerification {
        guard destination(change.request) != nil else {
            let after: RemoteItemState
            do { after = try await state(of: original) } catch RemoteRequestFailure.gone { after = .gone }
            return RemoteStateRules.satisfied(change.request, after) ? .reached(after) : .notReached(after)
        }
        // A move: the original UID must be gone from the source …
        let source: RemoteItemState
        do { source = try await state(of: original) } catch RemoteRequestFailure.gone { source = .gone }
        if source.exists { return .notReached(source) }
        // … and the copy present in the destination.
        guard let resulting else {
            return .reachedUnconfirmed("the message left the folder; the server did not report its new UID in the destination")
        }
        let after: RemoteItemState
        do { after = try await state(of: resulting) } catch RemoteRequestFailure.gone { after = .gone }
        return RemoteStateRules.satisfied(change.request, after) ? .reached(after) : .notReached(after)
    }

    public func safeToResend(_ change: ResolvedChange) async -> Bool {
        guard destination(change.request) != nil else { return true }       // flag changes are idempotent
        // MOVE is atomic (a source still there was never moved); COPY is not.
        return (try? await adapter.withActionSession { s in await s.capabilities.has("MOVE") }) ?? false
    }

    // MARK: Commands (one UID each)

    static func command(_ s: IMAPSession, _ args: [IMAPArgument]) async throws -> IMAPCommandResult {
        try await s.run(args, context: .other)
    }

    static func refusal(_ r: IMAPCommandResult, _ what: String) -> RemoteRequestFailure {
        let text = r.completion.text.isEmpty ? r.completion.status.rawValue : r.completion.text
        if r.completion.code?.name == "NONEXISTENT" || r.completion.code?.name == "EXPUNGEISSUED" { return .gone }
        if r.completion.code?.name == "TRYCREATE" { return .refused("the destination folder does not exist (\(text))") }
        return .refused("the server refused the \(what): \(text)")
    }

    /// SELECT (read-write) and check the identity's UIDVALIDITY still holds.
    static func select(_ s: IMAPSession, _ wire: [UInt8], validity: UInt32) async throws {
        let r = try await s.run([.raw("SELECT"), .string(wire)], context: .examine)
        guard r.completion.status == .ok else {
            if r.completion.code?.name == "NONEXISTENT" { throw RemoteRequestFailure.gone }
            throw RemoteRequestFailure.refused("the folder could not be opened for changes: \(r.completion.text)")
        }
        if r.completion.code?.name == "READ-ONLY" { throw RemoteRequestFailure.refused("the server opened the folder read-only") }
        var current: UInt32?
        for case .untaggedStatus(let st) in r.untagged where st.code?.name == "UIDVALIDITY" {
            current = st.code?.number.flatMap { UInt32(exactly: $0) }
        }
        guard current == validity else { throw RemoteRequestFailure.gone }   // the UID may now name another message
    }

    static func store(_ s: IMAPSession, _ uid: UInt32, _ change: String) async throws {
        let r = try await command(s, [.raw("UID STORE \(uid) \(change)")])
        guard r.completion.status == .ok else { throw refusal(r, "change") }
    }

    /// The message's flags, or nil when the UID does not exist.
    static func flags(_ s: IMAPSession, _ uid: UInt32) async throws -> [String]? {
        let r = try await s.run([.raw("UID FETCH \(uid) (UID FLAGS)")], context: .fetch)
        guard r.completion.status == .ok else { return nil }
        for case .fetch(_, let items) in r.untagged {
            guard items.first(where: { $0.name == "UID" })?.value.number == UInt64(uid) else { continue }
            if let list = items.first(where: { $0.name == "FLAGS" })?.value.list { return list.compactMap(\.atomText) }
        }
        return nil
    }

    /// RFC 4315 `COPYUID <uidvalidity> <source-uids> <dest-uids>` (tagged OK
    /// for COPY; an untagged OK for MOVE).
    static func copyUID(_ r: IMAPCommandResult, source uid: UInt32, mailbox: String) -> ProviderMessageIdentity? {
        var codes: [IMAPResponseCode] = []
        for case .untaggedStatus(let st) in r.untagged { if let c = st.code { codes.append(c) } }
        if let c = r.completion.code { codes.append(c) }
        for code in codes where code.name == "COPYUID" {
            let words = code.argument.split(separator: " ").map(String.init)
            guard words.count == 3, let validity = UInt32(words[0]), validity != 0,
                  let src = IMAPUIDSet(sequenceSet: words[1]), let dst = IMAPUIDSet(sequenceSet: words[2]) else { continue }
            let s = src.uids, d = dst.uids
            guard s.count == d.count, let i = s.firstIndex(of: uid), d[i] != 0 else { continue }
            return .imap(mailbox: mailbox, uidValidity: validity, uid: d[i])
        }
        return nil
    }
}
