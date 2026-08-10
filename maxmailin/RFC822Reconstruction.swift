//
//  RFC822Reconstruction.swift
//  maxmailin
//
//  Best-effort RFC-822 view for emails whose raw source was never stored
//  (pre-v2 migrations). Emits ONLY valid, real header fields:
//  - RFC 5322 field names contain no spaces/colons — the old v1 parser
//    sometimes stored the mbox "From ..." ENVELOPE line as a fake header
//    (split at the first colon inside its timestamp); those are dropped
//  - mailin's internal bookkeeping keys (sourceFile) are not email headers
//

import Foundation

enum RFC822Reconstruction {

    /// Keys mailin injects for its own bookkeeping — never RFC headers.
    static let internalKeys: Set<String> = ["sourceFile", "X-Source-File"]

    /// RFC 5322 field-name: printable US-ASCII except colon, no spaces.
    static func isValidFieldName(_ key: String) -> Bool {
        !key.isEmpty && key.range(of: "^[!-9;-~]+$", options: .regularExpression) != nil
    }

    static func build(headers: [String: String], body: String) -> String {
        var lines: [String] = []
        let canonical = ["From", "To", "Cc", "Bcc", "Subject", "Date", "Message-ID"]
        for key in canonical {
            if let value = headers[key], !value.isEmpty { lines.append("\(key): \(value)") }
        }
        for key in headers.keys.sorted() where !canonical.contains(key) {
            guard isValidFieldName(key), !internalKeys.contains(key),
                  let value = headers[key], !value.isEmpty else { continue }
            lines.append("\(key): \(value)")
        }
        return lines.joined(separator: "\n") + "\n\n" + body
    }
}
