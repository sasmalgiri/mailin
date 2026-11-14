//
//  ReplyBuilder.swift
//  MailConnectivity
//
//  Plan v4 V4-09 (§3 A13, §6): reply, reply-all and forward drafts built
//  from an archived message's own bytes.
//
//  * Reply goes to Reply-To when the original has one, else From (the old
//    sheet always used From).
//  * Reply-all adds the original To and Cc, removes EVERY self alias of the
//    replying account (and any former addresses the caller lists), and
//    de-duplicates across To/Cc.
//  * The original's Bcc is never read into a draft; forwarding the original
//    as an .eml attachment removes any Bcc header from the copy.
//  * Forward copies the selected original attachments byte for byte,
//    inline parts keeping their Content-IDs.
//  * Content that was only readable because it was decrypted (S/MIME,
//    OpenPGP) is left out unless the caller passes `includeProtectedContent`
//    — and either way the draft records it (`protectedContent`), and a reply
//    to encrypted mail says it will not be encrypted (`securityNotice`).
//  * The sending identity is never inferred from the archive: it is preset
//    only to an identity the caller passes, or to a verified identity of the
//    replying account that the original was actually addressed to.
//

import ArchiveCore
import CryptoKit
import Foundation

/// The parts of an archived message a reply or forward needs.
public struct ArchivedMessageSource: Sendable {
    public struct Attachment: Sendable, Equatable {
        public var index: Int
        public var filename: String
        public var mimeType: String
        public var disposition: DraftAttachment.Disposition
        public var contentID: String?
        public var data: Data
    }

    public enum Protection: Sendable, Equatable {
        case none
        /// Encrypted, and only the ciphertext is available.
        case encrypted
        /// Encrypted; the bodies and attachments here are the decrypted content.
        case decrypted
    }

    /// The original bytes as archived.
    public let raw: Data
    public var from: [MailAddress]
    public var replyTo: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var subject: String
    public var date: String?
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var plainBody: String
    public var htmlBody: String?
    public var attachments: [Attachment]
    public var protection: Protection

    /// Parses the archived bytes with the archive's `MIMEParser`. When the
    /// original is encrypted and the archive could decrypt it, pass the
    /// decrypted MIME as `decrypted`: bodies and attachments are read from it
    /// and marked `.decrypted`.
    public init(raw: Data, decrypted: Data? = nil) {
        self.raw = raw
        let parsed = MIMEParser.parseEmail(rawEmail: String(decoding: raw, as: UTF8.self))
        let h = parsed.headers
        func header(_ name: String) -> String? { h.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
        func addresses(_ name: String) -> [MailAddress] {
            guard let v = header(name), !v.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
            return (try? MailAddressParser.parseList(v, kind: .header)) ?? []
        }
        from = addresses("From"); replyTo = addresses("Reply-To"); to = addresses("To"); cc = addresses("Cc")
        subject = header("Subject").map { EncodedWord.decode($0) } ?? ""
        date = header("Date")
        messageID = header("Message-ID").flatMap { Self.messageIDs($0).first }
        inReplyTo = header("In-Reply-To").flatMap { Self.messageIDs($0).first }
        references = header("References").map(Self.messageIDs) ?? []

        let contentType = (header("Content-Type") ?? "").lowercased()
        let encrypted = contentType.hasPrefix("multipart/encrypted") || contentType.contains("pkcs7-mime")
            || String(decoding: raw, as: UTF8.self).contains("-----BEGIN PGP MESSAGE-----")
        var parts = parsed.parts
        if encrypted {
            if let decrypted {
                protection = .decrypted
                parts = MIMEParser.parseEmail(rawEmail: String(decoding: decrypted, as: UTF8.self)).parts
            } else {
                protection = .encrypted
                parts = []
            }
        } else {
            protection = .none
        }
        var plain: String?, html: String?
        var atts: [Attachment] = []
        Self.walk(parts, plain: &plain, html: &html, attachments: &atts)
        plainBody = plain ?? ""
        htmlBody = html
        attachments = atts
    }

    static func walk(_ parts: [MIMEPart], plain: inout String?, html: inout String?, attachments: inout [Attachment]) {
        for part in parts {
            let type = part.mimeType.lowercased()
            let disposition = part.contentDisposition.lowercased()
            let cidHeader = part.headers.first { $0.key.caseInsensitiveCompare("Content-ID") == .orderedSame }?.value
            if type.hasPrefix("multipart/") {
                walk(part.subparts, plain: &plain, html: &html, attachments: &attachments)
                continue
            }
            let isNamed = part.filename != nil || type.hasPrefix("message/rfc822")
            if !isNamed, !disposition.hasPrefix("attachment"), cidHeader == nil || type.hasPrefix("text/") {
                if type.hasPrefix("text/plain"), plain == nil { plain = part.body; continue }
                if type.hasPrefix("text/html"), html == nil { html = part.body; continue }
            }
            let mime = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "application/octet-stream"
            let cid = cidHeader.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t")) }
            let name = part.filename ?? (mime == "message/rfc822" ? "message.eml" : "attachment")
            attachments.append(Attachment(index: attachments.count, filename: name, mimeType: mime,
                                          disposition: disposition.hasPrefix("inline") && cid != nil ? .inline : .attachment,
                                          contentID: cid, data: decodedBytes(part)))
        }
    }

    /// The part's bytes, decoded from its transfer encoding (read from the raw body, not the text-decoded one).
    static func decodedBytes(_ part: MIMEPart) -> Data {
        let encoding = part.transferEncoding.lowercased().trimmingCharacters(in: .whitespaces)
        if encoding == "base64" { return Data(base64Encoded: part.rawBody, options: .ignoreUnknownCharacters) ?? Data() }
        if encoding == "quoted-printable" {
            var out: [UInt8] = []
            let u = Array(part.rawBody.utf8)
            var i = 0
            while i < u.count {
                if u[i] == 61 {
                    if i + 1 < u.count, u[i + 1] == 10 { i += 2; continue }
                    if i + 2 < u.count, u[i + 1] == 13, u[i + 2] == 10 { i += 3; continue }
                    if i + 2 < u.count, let v = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) { out.append(v); i += 3; continue }
                }
                out.append(u[i]); i += 1
            }
            return Data(out)
        }
        return Data(part.rawBody.utf8)
    }

    static func messageIDs(_ value: String) -> [String] {
        var out: [String] = []
        var current: String?
        for ch in value {
            if ch == "<" { current = "<" } else if ch == ">", var c = current { c.append(">"); if Draft.isMessageID(c) { out.append(c) }; current = nil } else if current != nil { if !ch.isWhitespace { current!.append(ch) } }
        }
        return out
    }
}

public enum ReplyBuilderError: LocalizedError, Equatable {
    case unknownAttachment(Int)
    case nothingToReplyTo

    public var errorDescription: String? {
        switch self {
        case .unknownAttachment(let i): return "The original message has no attachment \(i + 1)."
        case .nothingToReplyTo: return "The original message has no sender to reply to."
        }
    }
}

public enum ReplyBuilder {
    public enum Mode: Sendable { case reply, replyAll }

    /// - Parameters:
    ///   - identities: the replying account's identities (every alias, any permission) — all are excluded from reply-all.
    ///   - formerSelfAddresses: other addresses that are "me" (an archive's previous owner addresses), also excluded.
    ///   - identityID: the identity the user chose; nil leaves the choice to the user unless the original was addressed to exactly one verified identity of this account.
    public static func reply(to source: ArchivedMessageSource, mode: Mode, accountID: UUID, identities: [SendingIdentity],
                             formerSelfAddresses: [MailAddress] = [], identityID: UUID? = nil,
                             includeProtectedContent: Bool = false) throws -> DraftSeed {
        let own = identities.filter { $0.accountID == accountID }
        let selfKeys = Set((own.map(\.address) + formerSelfAddresses).map(\.normalizedKey))
        let fromIsSelf = source.from.contains { selfKeys.contains($0.normalizedKey) }

        var to: [MailAddress]
        if !source.replyTo.isEmpty { to = source.replyTo } else if fromIsSelf { to = source.to } else { to = source.from }
        var cc: [MailAddress] = []
        if mode == .replyAll {
            to += source.to
            cc = source.cc
        }
        to = MailAddressParser.deduplicated(to, excluding: selfKeys)
        cc = MailAddressParser.deduplicated(cc, excluding: selfKeys.union(to.map(\.normalizedKey)))
        if to.isEmpty, !cc.isEmpty { to = [cc.removeFirst()] }
        if to.isEmpty, mode == .reply, source.from.isEmpty, source.replyTo.isEmpty { throw ReplyBuilderError.nothingToReplyTo }

        var draft = Draft(accountID: accountID, senderIdentityID: chooseIdentity(identityID, own: own, source: source),
                          kind: mode == .reply ? .reply : .replyAll, to: to, cc: cc,
                          inReplyTo: source.messageID, references: referenceChain(source),
                          subject: prefixed("Re:", source.subject))
        applyQuote(source, to: &draft, forward: false, includeProtected: includeProtectedContent)
        if source.protection != .none { draft.securityNotice = .originalEncryptedReplyNotEncrypted }
        return DraftSeed(draft: draft)
    }

    /// Forward with the chosen original attachments (all when nil).
    public static func forward(_ source: ArchivedMessageSource, accountID: UUID, identities: [SendingIdentity],
                               identityID: UUID? = nil, attachmentIndexes: [Int]? = nil,
                               includeProtectedContent: Bool = false) throws -> DraftSeed {
        let own = identities.filter { $0.accountID == accountID }
        var draft = Draft(accountID: accountID, senderIdentityID: chooseIdentity(identityID, own: own, source: source), kind: .forward,
                          references: referenceChain(source), subject: prefixed("Fwd:", source.subject))
        applyQuote(source, to: &draft, forward: true, includeProtected: includeProtectedContent)
        var payloads: [DraftAttachmentPayload] = []
        if source.protection != .decrypted || includeProtectedContent {
            for index in attachmentIndexes ?? source.attachments.map(\.index) {
                guard let a = source.attachments.first(where: { $0.index == index }) else { throw ReplyBuilderError.unknownAttachment(index) }
                payloads.append(DraftAttachmentPayload(filename: a.filename, mimeType: a.mimeType, disposition: a.disposition,
                                                       contentID: a.contentID, data: a.data))
            }
        }
        return DraftSeed(draft: draft, attachments: payloads)
    }

    /// Forward the original message itself as an .eml attachment — its bytes
    /// unchanged except that any Bcc header is removed.
    public static func forwardAsAttachment(_ source: ArchivedMessageSource, accountID: UUID, identities: [SendingIdentity],
                                           identityID: UUID? = nil) -> DraftSeed {
        let own = identities.filter { $0.accountID == accountID }
        let draft = Draft(accountID: accountID, senderIdentityID: chooseIdentity(identityID, own: own, source: source),
                          kind: .forwardAsAttachment, references: referenceChain(source), subject: prefixed("Fwd:", source.subject))
        let base = source.subject.isEmpty ? "message" : source.subject
        let safe = String(base.map { "/\\:*?\"<>|".contains($0) || $0.isNewline ? "-" : $0 }.prefix(120))
        return DraftSeed(draft: draft, attachments: [DraftAttachmentPayload(filename: safe + ".eml", mimeType: "message/rfc822",
                                                                           data: removingBcc(source.raw))])
    }

    // MARK: Helpers

    static func chooseIdentity(_ explicit: UUID?, own: [SendingIdentity], source: ArchivedMessageSource) -> UUID? {
        if let explicit { return explicit }
        let addressed = Set((source.to + source.cc).map(\.normalizedKey))
        let matches = own.filter { $0.permission == .verified && addressed.contains($0.address.normalizedKey) }
        return matches.count == 1 ? matches[0].id : nil
    }

    static func referenceChain(_ source: ArchivedMessageSource) -> [String] {
        var refs = source.references
        if refs.isEmpty, let irt = source.inReplyTo { refs = [irt] }
        if let id = source.messageID { refs.append(id) }
        var seen = Set<String>()
        return refs.filter { seen.insert($0).inserted }
    }

    static func prefixed(_ prefix: String, _ subject: String) -> String {
        let s = subject.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if s.lowercased().hasPrefix(prefix.lowercased()) { return s }
        return s.isEmpty ? prefix : "\(prefix) \(s)"
    }

    static func applyQuote(_ source: ArchivedMessageSource, to draft: inout Draft, forward: Bool, includeProtected: Bool) {
        switch source.protection {
        case .none: draft.protectedContent = .none
        case .encrypted: draft.protectedContent = .omitted; return
        case .decrypted:
            guard includeProtected else { draft.protectedContent = .omitted; return }
            draft.protectedContent = .includedByUserChoice
        }
        if forward {
            // Never the original Bcc.
            var lines = ["---------- Forwarded message ----------"]
            if !source.from.isEmpty { lines.append("From: " + source.from.map(\.description).joined(separator: ", ")) }
            if let date = source.date { lines.append("Date: " + date) }
            lines.append("Subject: " + source.subject)
            if !source.to.isEmpty { lines.append("To: " + source.to.map(\.description).joined(separator: ", ")) }
            if !source.cc.isEmpty { lines.append("Cc: " + source.cc.map(\.description).joined(separator: ", ")) }
            draft.quotedPlain = lines.joined(separator: "\n") + "\n\n" + source.plainBody
            if let html = source.htmlBody {
                draft.quotedHTML = "<div>" + lines.map(MIMEComposer.escapeHTML).joined(separator: "<br>") + "</div><br>" + html
            }
        } else {
            let who = source.from.first?.description ?? ""
            let intro = source.date.map { "On \($0), \(who) wrote:" } ?? "\(who) wrote:"
            draft.quotedPlain = intro + "\n" + source.plainBody.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            if let html = source.htmlBody {
                draft.quotedHTML = "<div>" + MIMEComposer.escapeHTML(intro) + "</div><blockquote type=\"cite\">" + html + "</blockquote>"
            }
        }
    }

    /// The message with every Bcc header (and its folded continuation lines) removed from its header block.
    static func removingBcc(_ raw: Data) -> Data {
        let bytes = [UInt8](raw)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        var skipping = false
        while i < bytes.count {
            var end = i
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            let lineEnd = min(end + 1, bytes.count)
            let line = Array(bytes[i..<lineEnd])
            let content = line.filter { $0 != 0x0D && $0 != 0x0A }
            if content.isEmpty {   // end of header block: copy the rest unchanged
                out += bytes[i...]
                return Data(out)
            }
            let continuation = content.first == 0x20 || content.first == 0x09
            if continuation {
                if !skipping { out += line }
            } else {
                skipping = String(decoding: content.prefix(4), as: UTF8.self).lowercased() == "bcc:"
                    || (String(decoding: content.prefix(4), as: UTF8.self).lowercased() == "bcc " && content.contains(0x3A))
                if !skipping { out += line }
            }
            i = lineEnd
        }
        return Data(out)
    }
}
