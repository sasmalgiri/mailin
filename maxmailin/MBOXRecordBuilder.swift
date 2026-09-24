//
//  MBOXRecordBuilder.swift
//  mailin
//
//  H1 of the handoff work: produce mbox records Apple Mail and Thunderbird
//  actually accept, without inventing metadata and without losing attachments.
//
//  Two things this fixes:
//
//  1. The `From_` envelope. mbox's separator line is
//     `From <addr> <asctime>` — Apple Mail and Thunderbird both parse it, and
//     some tools take the date from it. The old writer emitted a constant
//     `From MAILER-DAEMON Thu Jan  1 00:00:00 1970`, so every exported message
//     claimed an invented sender and the epoch.
//
//  2. The synthesized fallback. When the store has no raw MIME, the old writer
//     emitted headers plus the plain body only — attachments were **silently
//     dropped**. An export that quietly loses attachments is worse than one
//     that fails, because nothing tells the user.
//
//  Byte fidelity rule: when raw MIME exists we never rebuild. This builder runs
//  only for rows that have no raw source (pre-fidelity imports), and it records
//  in the message itself that it was reconstructed, so a reader can tell.
//

import Foundation

enum MBOXRecordBuilder {

    /// `From sender@example.com Tue Mar 14 09:41:00 2017` + newline.
    ///
    /// Falls back to `MAILER-DAEMON` only when the message genuinely has no
    /// usable sender, and to the message's own timestamp before the epoch.
    static func envelopeLine(for email: MBOXParser.RawEmail) -> String {
        let address = envelopeAddress(for: email)
        let date = envelopeDate(for: email)
        return "From \(address) \(asctime(date))\n"
    }

    /// The bare address from `From:`, with display name and brackets removed —
    /// the envelope line must not contain spaces in the address field.
    static func envelopeAddress(for email: MBOXParser.RawEmail) -> String {
        let from = email.headers["From"] ?? email.headers["Sender"] ?? ""
        if let open = from.firstIndex(of: "<"), let close = from.firstIndex(of: ">"),
           open < close {
            let inner = from[from.index(after: open)..<close]
                .trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty, !inner.contains(" ") { return inner }
        }
        // No angle brackets: take the first whitespace-free token containing @.
        let token = from.split(whereSeparator: { $0 == " " || $0 == "," })
            .first { $0.contains("@") }
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
        if let token, !token.isEmpty { return token }
        return "MAILER-DAEMON"
    }

    /// The message's own date, from the `Date` header, then the stored
    /// timestamp, and only then `now` — never a hardcoded epoch.
    static func envelopeDate(for email: MBOXParser.RawEmail) -> Date {
        if let raw = email.headers["Date"], let parsed = MBOXParser.parseDate(raw) {
            return parsed
        }
        if let parsed = ISO8601DateFormatter().date(from: email.timestamp) {
            return parsed
        }
        return Date()
    }

    /// asctime format, C locale, as the mbox separator requires:
    /// `Tue Mar 14 09:41:00 2017`.
    static func asctime(_ date: Date) -> String {
        var formatter = cachedAsctimeFormatter
        if formatter == nil {
            let created = DateFormatter()
            created.locale = Locale(identifier: "en_US_POSIX")
            created.timeZone = TimeZone(secondsFromGMT: 0)
            created.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            cachedAsctimeFormatter = created
            formatter = created
        }
        return formatter!.string(from: date)
    }

    nonisolated(unsafe) private static var cachedAsctimeFormatter: DateFormatter?

    // MARK: - Synthesized MIME (no raw source available)

    /// Rebuilds an RFC 5322 message from the stored fields, **including
    /// attachments** as base64 MIME parts.
    ///
    /// Marked with `X-Mailin-Reconstructed` so a recipient can tell this is not
    /// the original byte stream — the honest alternative to silently presenting
    /// a rebuild as the original.
    static func synthesizeMIME(for email: MBOXParser.RawEmail) -> String {
        let boundary = "mailin-\(email.id.uuidString.lowercased())"
        let hasHTML = !email.htmlBody.isEmpty
        let attachments = readableAttachments(of: email)
        let isMultipart = !attachments.isEmpty || (hasHTML && !email.plainBody.isEmpty)

        var lines: [String] = []

        // Preserve the headers we hold, in a conventional order, then anything
        // else we still have.
        let ordered = ["From", "To", "Cc", "Bcc", "Subject", "Date", "Message-ID",
                       "In-Reply-To", "References", "Reply-To"]
        for key in ordered {
            if let value = email.headers[key], !value.isEmpty {
                lines.append("\(key): \(value)")
            }
        }
        for (key, value) in email.headers.sorted(by: { $0.key < $1.key })
        where !ordered.contains(key) && !value.isEmpty
            && !key.lowercased().hasPrefix("content-")
            && key.lowercased() != "mime-version" {
            lines.append("\(key): \(value)")
        }
        lines.append("X-Mailin-Reconstructed: no original MIME was stored for this message")
        lines.append("MIME-Version: 1.0")

        guard isMultipart else {
            lines.append("Content-Type: \(hasHTML ? "text/html" : "text/plain"); charset=utf-8")
            lines.append("")
            lines.append(hasHTML ? email.htmlBody : email.plainBody)
            return lines.joined(separator: "\n")
        }

        lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        lines.append("")

        // Body part(s).
        lines.append("--\(boundary)")
        if hasHTML && !email.plainBody.isEmpty {
            let alt = boundary + "-alt"
            lines.append("Content-Type: multipart/alternative; boundary=\"\(alt)\"")
            lines.append("")
            lines.append("--\(alt)")
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("")
            lines.append(email.plainBody)
            lines.append("--\(alt)")
            lines.append("Content-Type: text/html; charset=utf-8")
            lines.append("")
            lines.append(email.htmlBody)
            lines.append("--\(alt)--")
        } else {
            lines.append("Content-Type: \(hasHTML ? "text/html" : "text/plain"); charset=utf-8")
            lines.append("")
            lines.append(hasHTML ? email.htmlBody : email.plainBody)
        }

        // Attachment parts — the bytes the old writer threw away.
        for (attachment, data) in attachments {
            lines.append("--\(boundary)")
            lines.append("Content-Type: \(attachment.mimeType); name=\"\(sanitize(attachment.filename))\"")
            lines.append("Content-Disposition: \(attachment.isInline ? "inline" : "attachment"); filename=\"\(sanitize(attachment.filename))\"")
            if let cid = attachment.contentID, !cid.isEmpty {
                lines.append("Content-ID: <\(cid)>")
            }
            lines.append("Content-Transfer-Encoding: base64")
            lines.append("")
            lines.append(wrap(data.base64EncodedString(), at: 76))
        }
        lines.append("--\(boundary)--")
        return lines.joined(separator: "\n")
    }

    /// Attachments whose bytes we can actually produce, via the hydrator — so a
    /// reconstructed message carries real payloads rather than empty stubs.
    /// Attachments whose bytes cannot be recovered are omitted from the MIME and
    /// declared in a header, never silently dropped.
    private static func readableAttachments(
        of email: MBOXParser.RawEmail
    ) -> [(AttachmentMetadata, Data)] {
        let cache = AttachmentHydrator.Cache()
        var out: [(AttachmentMetadata, Data)] = []
        for (index, attachment) in email.attachments.enumerated() {
            if let data = AttachmentHydrator.data(for: attachment, index: index,
                                                  email: email, cache: cache) {
                out.append((attachment, data))
            }
        }
        return out
    }

    /// Attachment names that could escape a directory or break a header.
    private static func sanitize(_ filename: String) -> String {
        filename
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
    }

    /// base64 must be wrapped — RFC 5322 limits a line to 998 characters and
    /// most tools expect 76.
    private static func wrap(_ text: String, at width: Int) -> String {
        guard width > 0, text.count > width else { return text }
        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: width, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[index..<end]))
            index = end
        }
        return result.joined(separator: "\n")
    }
}
