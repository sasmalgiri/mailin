//
//  MIMEComposer.swift
//  MailConnectivity
//
//  Plan v4 V4-09 (§6 "Outbox and transport": prepare and persist MIME once,
//  with a stable Message-ID). Turns one authorised draft into its final
//  RFC 5322 bytes:
//
//  * deterministic — the same draft, sender and date give the same bytes
//    (boundaries derive from the draft, the Message-ID from its fixed token);
//  * headers folded at whitespace (≤ 78 columns where possible, never > 998);
//    non-ASCII display names and subjects as RFC 2047 encoded words;
//    internationalised domains as A-labels; a non-ASCII local part makes the
//    message SMTPUTF8 (`requiresSMTPUTF8`) and is written as UTF-8 (RFC 6532);
//  * text as UTF-8, 7bit when it can be, quoted-printable otherwise;
//    attachments base64; non-ASCII filenames as RFC 2231 `filename*` with an
//    encoded-word `name` for older readers;
//  * multipart/alternative (plain + HTML), multipart/related (HTML + inline
//    `cid:` parts), multipart/mixed (attachments); an attached message is
//    message/rfc822 with its bytes unchanged (CRLF canonical form);
//  * Bcc is never written into the header — only into the envelope.
//
//  Composition requires an `AuthorisedSender` for exactly this draft
//  revision (T34), and every attachment's bytes are re-verified against the
//  draft's recorded SHA-256 before they are written.
//

import CryptoKit
import Foundation

public struct ComposedMessage: Sendable, Equatable {
    public let bytes: Data
    /// With angle brackets.
    public let messageID: String
    /// The envelope sender (MAIL FROM).
    public let envelopeFrom: String
    /// To + Cc + Bcc, de-duplicated (RCPT TO). Bcc appears here and nowhere in `bytes`.
    public let envelopeRecipients: [String]
    public let requiresSMTPUTF8: Bool
    public let sha256: String
    public let draftID: UUID
    public let draftRevision: Int
    public let accountID: UUID
    public let identityID: UUID
}

public enum MIMEComposerError: LocalizedError, Equatable {
    case senderNotAuthorisedForDraft
    case noRecipients
    case attachmentChanged(name: String)
    case headerTooLong(String)

    public var errorDescription: String? {
        switch self {
        case .senderNotAuthorisedForDraft: return "The sending address was authorised for a different draft or version."
        case .noRecipients: return "Add at least one recipient."
        case .attachmentChanged(let name): return "The attachment “\(name)” changed after it was attached."
        case .headerTooLong(let name): return "The \(name) header is too long to send."
        }
    }
}

public enum MIMEComposer {
    public static func compose(_ draft: Draft, sender: AuthorisedSender, date: Date,
                               attachmentBytes: (DraftAttachment) throws -> Data) throws -> ComposedMessage {
        guard sender.draftID == draft.id, sender.accountID == draft.accountID, sender.identity.accountID == draft.accountID,
              draft.senderIdentityID == sender.identity.id, sender.draftRevision == draft.revision else {
            throw MIMEComposerError.senderNotAuthorisedForDraft
        }
        try draft.validate()
        let recipients = draft.envelopeRecipients
        guard !recipients.isEmpty else { throw MIMEComposerError.noRecipients }

        let identity = sender.identity
        let utf8Headers = ([identity.address] + recipients + draft.replyTo + identity.replyTo).contains(where: \.requiresSMTPUTF8)

        // Attachment bytes, re-verified.
        var payloads: [(DraftAttachment, Data)] = []
        for att in draft.attachments {
            let data = try attachmentBytes(att)
            guard DraftStore.hex(SHA256.hash(data: data)) == att.sha256 else { throw MIMEComposerError.attachmentChanged(name: att.filename) }
            payloads.append((att, data))
        }

        // Headers.
        let messageID = "<\(draft.messageIDToken.uuidString.lowercased())@\(try MailAddressParser.asciiDomain(identity.address.domain))>"
        var head: [String] = []
        head.append(try fold("Date", rfc5322Date(date)))
        head.append(try fold("From", formatAddress(identity.address, utf8: utf8Headers)))
        let replyTo = draft.replyTo.isEmpty ? identity.replyTo : draft.replyTo
        if !replyTo.isEmpty { head.append(try fold("Reply-To", try replyTo.map { try formatAddress($0, utf8: utf8Headers) }.joined(separator: ", "))) }
        let to = MailAddressParser.deduplicated(draft.to)
        let cc = MailAddressParser.deduplicated(draft.cc, excluding: Set(to.map(\.normalizedKey)))
        if !to.isEmpty { head.append(try fold("To", try to.map { try formatAddress($0, utf8: utf8Headers) }.joined(separator: ", "))) }
        if !cc.isEmpty { head.append(try fold("Cc", try cc.map { try formatAddress($0, utf8: utf8Headers) }.joined(separator: ", "))) }
        head.append(try fold("Subject", unstructured(draft.subject)))
        head.append(try fold("Message-ID", messageID))
        if let irt = draft.inReplyTo { head.append(try fold("In-Reply-To", irt)) }
        if !draft.references.isEmpty { head.append(try fold("References", dedupedReferences(draft.references).joined(separator: " "))) }
        head.append("MIME-Version: 1.0")

        // Body tree.
        var plain = draft.plainBody
        if let sig = draft.signature { plain += "\n\n-- \n" + sig.plain }
        if let q = draft.quotedPlain { plain += "\n\n" + q }
        var textNode = Node.text(plain, subtype: "plain")
        let inline = payloads.filter { $0.0.disposition == .inline && $0.0.contentID != nil }
        var regular = payloads.filter { !($0.0.disposition == .inline && $0.0.contentID != nil) }
        if var html = draft.htmlBody {
            if let sig = draft.signature { html += "<div class=\"mailin-signature\">-- <br>" + (sig.html ?? escapeHTML(sig.plain).replacingOccurrences(of: "\n", with: "<br>")) + "</div>" }
            if let qh = draft.quotedHTML { html += qh } else if let q = draft.quotedPlain {
                html += "<blockquote type=\"cite\">" + escapeHTML(q).replacingOccurrences(of: "\n", with: "<br>") + "</blockquote>"
            }
            var htmlNode = Node.text(html, subtype: "html")
            if !inline.isEmpty { htmlNode = .multipart("related", [htmlNode] + inline.map { attachmentNode($0.0, $0.1) }) }
            textNode = .multipart("alternative", [textNode, htmlNode])
        } else {
            regular = payloads   // no HTML to reference them: inline parts travel as attachments
        }
        let root: Node = regular.isEmpty ? textNode : .multipart("mixed", [textNode] + regular.map { attachmentNode($0.0, $0.1) })

        // Boundaries derive from the draft; on the (astronomically unlikely)
        // chance one occurs inside a part, the next derivation is used.
        var salt = 0
        while root.boundaryCollides(seed: boundarySeed(draft, salt)) { salt += 1 }
        var path = 0
        let serialised = root.serialise(boundarySeed: boundarySeed(draft, salt), path: &path)

        var bytes = Data((head.joined(separator: "\r\n") + "\r\n").utf8)
        bytes.append(serialised)
        let fromAddress = utf8Headers && identity.address.requiresSMTPUTF8 ? identity.address.addrSpec : try identity.address.asciiAddrSpec()
        let envelope = try recipients.map { $0.requiresSMTPUTF8 ? "\(MailAddressParser.quotedLocalPartIfNeeded($0.localPart))@\(try MailAddressParser.asciiDomain($0.domain))" : try $0.asciiAddrSpec() }
        return ComposedMessage(bytes: bytes, messageID: messageID, envelopeFrom: fromAddress, envelopeRecipients: envelope,
                               requiresSMTPUTF8: utf8Headers, sha256: DraftStore.hex(SHA256.hash(data: bytes)),
                               draftID: draft.id, draftRevision: draft.revision, accountID: draft.accountID, identityID: identity.id)
    }

    static func boundarySeed(_ draft: Draft, _ salt: Int) -> String { "\(draft.id.uuidString)|\(draft.messageIDToken.uuidString)|\(salt)" }

    // MARK: Body nodes

    indirect enum Node {
        case leaf(headers: [String], body: Data)
        case multipart(String, [Node])

        static func text(_ text: String, subtype: String) -> Node {
            let crlf = normaliseLineEndings(text)
            let data = Data(crlf.utf8)
            let longLine = crlf.components(separatedBy: "\r\n").contains { $0.utf8.count > 998 }
            if data.allSatisfy({ $0 < 0x80 }) && !longLine {
                return .leaf(headers: ["Content-Type: text/\(subtype); charset=utf-8", "Content-Transfer-Encoding: 7bit"], body: data)
            }
            return .leaf(headers: ["Content-Type: text/\(subtype); charset=utf-8", "Content-Transfer-Encoding: quoted-printable"],
                         body: quotedPrintable(data))
        }

        func boundary(seed: String, path: Int) -> String {
            let digest = SHA256.hash(data: Data("\(seed)|\(path)".utf8))
            return "=_mailin_" + DraftStore.hex(digest).prefix(28)
        }

        /// Serialises the node; multipart boundaries are numbered depth-first.
        func serialise(boundarySeed: String, path: inout Int) -> Data {
            switch self {
            case .leaf(let headers, let body):
                var out = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
                out.append(body)
                return out
            case .multipart(let subtype, let children):
                let b = boundary(seed: boundarySeed, path: path)
                path += 1
                var out = Data("Content-Type: multipart/\(subtype);\r\n boundary=\"\(b)\"\r\n\r\n".utf8)
                for child in children {
                    out.append(Data("--\(b)\r\n".utf8))
                    out.append(child.serialise(boundarySeed: boundarySeed, path: &path))
                    out.append(Data("\r\n".utf8))
                }
                out.append(Data("--\(b)--\r\n".utf8))
                return out
            }
        }

        /// True when any boundary this seed would produce occurs inside a leaf body.
        func boundaryCollides(seed: String) -> Bool {
            var boundaries: [String] = []
            var leaves: [Data] = []
            var path = 0
            func walk(_ n: Node) {
                switch n {
                case .leaf(_, let body): leaves.append(body)
                case .multipart(_, let children):
                    boundaries.append(n.boundary(seed: seed, path: path)); path += 1
                    children.forEach(walk)
                }
            }
            walk(self)
            return boundaries.contains { b in leaves.contains { $0.range(of: Data(b.utf8)) != nil } }
        }
    }

    static func attachmentNode(_ att: DraftAttachment, _ data: Data) -> Node {
        var mimeType = att.mimeType.lowercased()
        let body: Data
        let cte: String
        if mimeType == "message/rfc822", let canonical = canonicalMessage(data) {
            body = canonical
            cte = canonical.allSatisfy({ $0 < 0x80 }) ? "7bit" : "8bit"
        } else {
            if mimeType == "message/rfc822" { mimeType = "application/octet-stream" }   // not 8bit-safe: sent as a file
            body = base64Lines(data)
            cte = "base64"
        }
        var headers: [String] = []
        headers.append("Content-Type: \(mimeType);\r\n " + nameParameter(att.filename))
        headers.append("Content-Transfer-Encoding: \(cte)")
        headers.append("Content-Disposition: \(att.disposition == .inline ? "inline" : "attachment");\r\n " + filenameParameter(att.filename))
        if let cid = att.contentID { headers.append("Content-ID: <\(cid)>") }
        return .leaf(headers: headers, body: body)
    }

    /// The message with bare LFs as CRLF (its canonical form); nil when it
    /// cannot travel as 7bit/8bit (NUL, bare CR, a line over 998 bytes).
    static func canonicalMessage(_ data: Data) -> Data? {
        var out = Data(capacity: data.count + data.count / 40)
        var lineLength = 0
        var previous: UInt8 = 0
        for byte in data {
            if byte == 0 { return nil }
            if previous == 0x0D && byte != 0x0A { return nil }
            if byte == 0x0A {
                if previous != 0x0D { out.append(0x0D) }
                out.append(0x0A)
                lineLength = 0
            } else {
                out.append(byte)
                if byte != 0x0D { lineLength += 1 }
                if lineLength > 998 { return nil }
            }
            previous = byte
        }
        if previous == 0x0D { return nil }
        return out
    }

    // MARK: Encodings

    static func normaliseLineEndings(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    static func base64Lines(_ data: Data) -> Data {
        data.base64EncodedData(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    /// RFC 2045 §6.7 quoted-printable over CRLF-separated lines.
    static func quotedPrintable(_ data: Data) -> Data {
        let hex = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        let bytes = [UInt8](data)
        var lines: [[UInt8]] = [[]]
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0D, i + 1 < bytes.count, bytes[i + 1] == 0x0A { lines.append([]); i += 2; continue }
            lines[lines.count - 1].append(bytes[i]); i += 1
        }
        for (n, line) in lines.enumerated() {
            var column = 0
            for (j, b) in line.enumerated() {
                let last = j == line.count - 1
                var token: [UInt8]
                if (b >= 33 && b <= 126 && b != 61) || ((b == 32 || b == 9) && !last) {
                    token = [b]
                } else {
                    token = [61, hex[Int(b >> 4)], hex[Int(b & 15)]]
                }
                if column + token.count > 75 { out += [61, 13, 10]; column = 0 }
                out += token
                column += token.count
            }
            if n < lines.count - 1 { out += [13, 10] }
        }
        return Data(out)
    }

    static let attrChars: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8))

    /// `filename="…"` for printable ASCII; RFC 2231 `filename*=UTF-8''…` otherwise.
    static func filenameParameter(_ name: String) -> String {
        if name.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
            return "filename=\"\(quoteParam(name))\""
        }
        let encoded = Data(name.utf8).map { attrChars.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
        if encoded.count <= 900 { return "filename*=UTF-8''\(encoded)" }
        // RFC 2231 continuations, each on its own folded line.
        var pieces: [String] = []
        var current = ""
        for unit in Data(name.utf8).map({ attrChars.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }) {
            if current.count + unit.count > 60 { pieces.append(current); current = "" }
            current += unit
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.enumerated().map { i, p in i == 0 ? "filename*0*=UTF-8''\(p)" : "filename*\(i)*=\(p)" }.joined(separator: ";\r\n ")
    }

    static func nameParameter(_ name: String) -> String {
        if name.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) { return "name=\"\(quoteParam(name))\"" }
        return "name=\"" + EncodedWord.encode(name).joined(separator: "\r\n ") + "\""
    }

    static func quoteParam(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    static func formatAddress(_ a: MailAddress, utf8: Bool) throws -> String {
        let spec = a.requiresSMTPUTF8 ? "\(MailAddressParser.quotedLocalPartIfNeeded(a.localPart))@\(try MailAddressParser.asciiDomain(a.domain))"
                                      : try a.asciiAddrSpec()
        guard let name = a.displayName else { return spec }
        return "\(phrase(name)) <\(spec)>"
    }

    static let phraseSafe: Set<Character> = MailAddressParser.atext.union([" "])

    static func phrase(_ name: String) -> String {
        if name.allSatisfy({ phraseSafe.contains($0) }) && !name.contains("=?") { return name }
        if name.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) && !name.contains("=?") { return "\"\(quoteParam(name))\"" }
        return EncodedWord.encode(name).joined(separator: " ")
    }

    static func unstructured(_ text: String) -> String {
        if text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) && !text.contains("=?") { return text }
        return EncodedWord.encode(text).joined(separator: " ")
    }

    static func dedupedReferences(_ refs: [String]) -> [String] {
        var seen = Set<String>()
        return refs.filter { seen.insert($0).inserted }
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Folds `Name: value` at spaces so lines stay within 78 columns where a
    /// space allows; a line that cannot be brought under 998 is refused.
    static func fold(_ name: String, _ value: String) throws -> String {
        let words = value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var lines: [String] = []
        var current = "\(name):"
        for word in words {
            let candidate = current + " " + word
            if candidate.utf8.count > 78, current.utf8.count > name.utf8.count + 1 {
                lines.append(current)
                current = " " + word
            } else {
                current = candidate
            }
        }
        lines.append(current)
        guard lines.allSatisfy({ $0.utf8.count <= 998 }) else { throw MIMEComposerError.headerTooLong(name) }
        return lines.joined(separator: "\r\n")
    }

    static func rfc5322Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss '+0000'"
        return f.string(from: date)
    }
}
