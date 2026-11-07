//
//  RFC822Renderer.swift
//  ArchiveCore
//
//  Plan v4 §13.8 step 3: one RFC 5322 rendering of a parsed message, for
//  messages that have no raw source of their own — a message embedded in an
//  Outlook .msg, a TNEF body, a PST/MSG message exported as .eml. Headers,
//  the text and HTML alternatives, every attachment base64-encoded; nothing
//  is invented and nothing is dropped. The result parses back through
//  `MBOXParser.processRawMessage`, so an embedded message travels as an
//  attached message and its own attachments become children.
//

import Foundation

enum RFC822Renderer {

    /// The message as RFC 5322 bytes (CRLF line ends, UTF-8, base64 bodies).
    static func render(_ email: MBOXParser.RawEmail) -> Data {
        var out = ""
        func header(_ name: String, _ value: String) {
            let flat = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
            out += "\(name): \(flat)\r\n"
        }
        let first = ["From", "To", "Cc", "Bcc", "Subject", "Date", "Message-ID", "In-Reply-To", "References", "Reply-To", "Thread-Topic"]
        var written = Set<String>()
        for name in first {
            if let value = email.headers[name], !value.isEmpty { header(name, value); written.insert(name.lowercased()) }
        }
        if !written.contains("date"), let date = ISO8601DateFormatter().date(from: email.timestamp) {
            header("Date", rfc2822(date)); written.insert("date")
        }
        for (name, value) in email.headers.sorted(by: { $0.key < $1.key }) {
            let lower = name.lowercased()
            guard !written.contains(lower), !value.isEmpty, !lower.hasPrefix("content-"), lower != "mime-version" else { continue }
            header(name, value); written.insert(lower)
        }
        header("MIME-Version", "1.0")

        let plain = email.plainBody
        let html = email.htmlBody
        let attachments = email.attachments
        var bodyPart = ""
        if !plain.isEmpty, !html.isEmpty {
            let boundary = "=_mailin_alt_" + UUID().uuidString
            bodyPart += "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n\r\n"
            bodyPart += "--\(boundary)\r\n" + textPart("text/plain", plain)
            bodyPart += "--\(boundary)\r\n" + textPart("text/html", html)
            bodyPart += "--\(boundary)--\r\n"
        } else if !html.isEmpty {
            bodyPart += textPart("text/html", html)
        } else {
            bodyPart += textPart("text/plain", plain)
        }

        if attachments.isEmpty {
            out += bodyPart
        } else {
            let boundary = "=_mailin_mixed_" + UUID().uuidString
            out += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
            out += "--\(boundary)\r\n" + bodyPart
            for attachment in attachments {
                out += "--\(boundary)\r\n" + attachmentPart(attachment)
            }
            out += "--\(boundary)--\r\n"
        }
        return Data(out.utf8)
    }

    private static func textPart(_ type: String, _ text: String) -> String {
        "Content-Type: \(type); charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n" + wrapped(Data(text.utf8).base64EncodedString()) + "\r\n"
    }

    private static func attachmentPart(_ attachment: AttachmentMetadata) -> String {
        let name = attachment.filename.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
        let mime = attachment.mimeType.isEmpty ? "application/octet-stream" : attachment.mimeType
        var part = "Content-Type: \(mime); name=\"\(name)\"\r\n"
        part += "Content-Transfer-Encoding: base64\r\n"
        if attachment.isInline, let contentID = attachment.contentID, !contentID.isEmpty {
            part += "Content-ID: <\(contentID.trimmingCharacters(in: CharacterSet(charactersIn: "<>")))>\r\n"
            part += "Content-Disposition: inline; filename=\"\(name)\"\r\n\r\n"
        } else {
            part += "Content-Disposition: attachment; filename=\"\(name)\"\r\n\r\n"
        }
        let bytes = attachment.fileURL.flatMap { try? Data(contentsOf: $0) }
            ?? attachment.base64.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
            ?? Data()
        part += wrapped(bytes.base64EncodedString()) + "\r\n"
        return part
    }

    /// Base64 at 76 columns, as RFC 2045 asks.
    private static func wrapped(_ base64: String) -> String {
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 76, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return lines.joined(separator: "\r\n")
    }

    static func rfc2822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
