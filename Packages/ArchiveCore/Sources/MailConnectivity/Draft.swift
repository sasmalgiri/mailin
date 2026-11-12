//
//  Draft.swift
//  MailConnectivity
//
//  Plan v4 V4-09 (§3 A13): one durable draft. The old compose sheet kept a
//  single global `compose_draft` in UserDefaults without its account,
//  attachment bytes or reply context. A `Draft` carries all of them: its
//  account (fixed — switching account clears the chosen identity), the
//  chosen sending identity (required, never defaulted to an archive's former
//  owner), structured To/Cc/Bcc, the draft's own Reply-To, In-Reply-To and
//  References, plain and HTML bodies, a signature, the quoted original, and
//  attachments held in protected draft storage (`DraftStore`). `revision`
//  counts autosaves; a stale autosave is refused rather than overwriting a
//  newer one.
//

import Foundation

public struct DraftSignature: Codable, Sendable, Equatable {
    public var plain: String
    public var html: String?
    public init(plain: String, html: String? = nil) { self.plain = plain; self.html = html }
}

public struct DraftAttachment: Codable, Sendable, Equatable, Identifiable {
    public enum Disposition: String, Codable, Sendable { case attachment, inline }

    /// Where the bytes are.
    public enum Storage: Codable, Sendable, Equatable {
        /// Copied into the draft's protected folder (path relative to the draft folder).
        case copied(relativePath: String)
        /// Left in place, by the user's choice; verified by SHA-256 before use.
        case reference(path: String, bookmark: Data?)
    }

    /// Why a referenced file cannot be used — shown, never silently dropped.
    public enum Unavailable: Codable, Sendable, Equatable {
        case missing
        case changedSinceAttached(expectedSHA256: String, foundSHA256: String)
        case unreadable(String)
    }

    public let id: UUID
    public var filename: String
    public var mimeType: String
    public var size: Int64
    /// Lowercase hex SHA-256 of the bytes as attached.
    public var sha256: String
    public var disposition: Disposition
    /// Content-ID without angle brackets (inline parts referenced as `cid:` from the HTML).
    public var contentID: String?
    public var storage: Storage

    public init(id: UUID = UUID(), filename: String, mimeType: String, size: Int64, sha256: String,
                disposition: Disposition = .attachment, contentID: String? = nil, storage: Storage) {
        self.id = id; self.filename = filename; self.mimeType = mimeType; self.size = size; self.sha256 = sha256
        self.disposition = disposition; self.contentID = contentID; self.storage = storage
    }
}

public struct Draft: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case new, reply, replyAll, forward, forwardAsAttachment }

    /// How protected (encrypted) content of the original was handled.
    public enum ProtectedContent: String, Codable, Sendable {
        /// The original was not protected.
        case none
        /// The original was protected; its decrypted text and attachments were left out.
        case omitted
        /// The user explicitly chose to include decrypted content (shown before sending).
        case includedByUserChoice
    }

    /// The security state a reply must show: reading encrypted mail does not
    /// imply the reply will be encrypted.
    public enum SecurityNotice: String, Codable, Sendable {
        case none
        /// The original was encrypted; this reply will be sent without encryption.
        case originalEncryptedReplyNotEncrypted
    }

    public static let formatVersion = 1

    public var formatVersion: Int = Draft.formatVersion
    public let id: UUID
    public private(set) var accountID: UUID
    /// The chosen sending identity; nil until the user chooses one.
    public var senderIdentityID: UUID?
    public var kind: Kind
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    /// The draft's own Reply-To header (not the original's).
    public var replyTo: [MailAddress]
    /// Message-ID of the message replied to, with angle brackets.
    public var inReplyTo: String?
    /// References chain, each with angle brackets.
    public var references: [String]
    public var subject: String
    public var plainBody: String
    public var htmlBody: String?
    public var signature: DraftSignature?
    /// The quoted original (or forwarded-message header block), kept apart so
    /// the signature goes between the new text and the quote.
    public var quotedPlain: String?
    public var quotedHTML: String?
    public var attachments: [DraftAttachment]
    public var protectedContent: ProtectedContent
    public var securityNotice: SecurityNotice
    /// Stable for the life of the draft; the Message-ID's left-hand side.
    public let messageIDToken: UUID
    /// Autosave counter: 0 = never saved; each save stores revision + 1.
    public internal(set) var revision: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), accountID: UUID, senderIdentityID: UUID? = nil, kind: Kind = .new,
                to: [MailAddress] = [], cc: [MailAddress] = [], bcc: [MailAddress] = [], replyTo: [MailAddress] = [],
                inReplyTo: String? = nil, references: [String] = [], subject: String = "", plainBody: String = "",
                htmlBody: String? = nil, signature: DraftSignature? = nil, quotedPlain: String? = nil, quotedHTML: String? = nil,
                attachments: [DraftAttachment] = [], protectedContent: ProtectedContent = .none, securityNotice: SecurityNotice = .none,
                messageIDToken: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id; self.accountID = accountID; self.senderIdentityID = senderIdentityID; self.kind = kind
        self.to = to; self.cc = cc; self.bcc = bcc; self.replyTo = replyTo
        self.inReplyTo = inReplyTo; self.references = references; self.subject = subject
        self.plainBody = plainBody; self.htmlBody = htmlBody; self.signature = signature
        self.quotedPlain = quotedPlain; self.quotedHTML = quotedHTML; self.attachments = attachments
        self.protectedContent = protectedContent; self.securityNotice = securityNotice
        self.messageIDToken = messageIDToken; self.revision = 0; self.createdAt = createdAt; self.updatedAt = createdAt
    }

    /// Moves the draft to another account. The chosen identity belonged to the
    /// old account, so it is cleared — the sender can never drift across accounts.
    public mutating func switchAccount(to account: UUID) {
        guard account != accountID else { return }
        accountID = account
        senderIdentityID = nil
    }

    /// Every recipient (To, Cc, Bcc), de-duplicated — the SMTP envelope.
    public var envelopeRecipients: [MailAddress] { MailAddressParser.deduplicated(to + cc + bcc) }

    /// Header-injection and structure checks: no control characters in any
    /// single-line field, Message-IDs well formed, attachment names and
    /// Content-IDs clean. Run on every save and before composition.
    public func validate() throws {
        func line(_ text: String, _ field: String) throws { try MailAddressParser.refuseControlCharacters(text, field: field, allowTab: false) }
        try line(subject, "subject")
        for a in to + cc + bcc + replyTo {
            try line(a.localPart, "recipient address"); try line(a.domain, "recipient address")
            if let n = a.displayName { try line(n, "recipient name") }
        }
        for id in ([inReplyTo].compactMap { $0 } + references) {
            guard Draft.isMessageID(id) else { throw DraftError.invalidMessageID(id) }
        }
        for att in attachments {
            try line(att.filename, "attachment name")
            try line(att.mimeType, "attachment type")
            guard att.mimeType.split(separator: "/").count == 2, !att.mimeType.contains(where: { $0 == ";" || $0 == " " || $0 == "\"" }) else {
                throw DraftError.invalidAttachment(att.filename, "its type “\(att.mimeType)” is not a MIME type")
            }
            if let cid = att.contentID {
                try line(cid, "attachment content ID")
                guard !cid.contains(where: { $0 == "<" || $0 == ">" || $0 == " " }), !cid.isEmpty else {
                    throw DraftError.invalidAttachment(att.filename, "its content ID is not valid")
                }
            }
        }
    }

    /// `<left@right>` with no whitespace or control characters.
    static func isMessageID(_ s: String) -> Bool {
        guard s.hasPrefix("<"), s.hasSuffix(">"), s.count > 2 else { return false }
        let inner = s.dropFirst().dropLast()
        return inner.contains("@") && !inner.contains(where: { $0 == "<" || $0 == ">" || $0.isWhitespace })
            && inner.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value != 0x7F }
    }
}

public enum DraftError: LocalizedError, Equatable {
    case invalidMessageID(String)
    case invalidAttachment(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidMessageID(let id): return "“\(id)” is not a valid message identifier."
        case .invalidAttachment(let name, let why): return "The attachment “\(name)” cannot be used: \(why)."
        }
    }
}
