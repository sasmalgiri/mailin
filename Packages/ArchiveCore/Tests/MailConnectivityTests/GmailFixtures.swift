//
//  GmailFixtures.swift
//  MailConnectivityTests
//
//  V4-05: raw RFC 822 fixtures for the Gmail simulator — multipart/mixed with
//  a binary attachment (Unicode RFC 2231 filename), multipart/related with an
//  inline CID image, an 8-bit UTF-8 HTML body and an encoded-word subject.
//  Deterministic: the same id always yields the same bytes.
//

import Foundation
import CryptoKit

enum GmailFixtures {
    struct Attachment { let filename: String; let data: Data; let contentID: String? }
    struct Built { let raw: Data; let attachments: [Attachment] }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Deterministic binary bytes, every value 0…255 present.
    static func binary(seed: Int, count: Int) -> Data {
        var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 | 1
        var out = Data(capacity: count)
        for i in 0..<count {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            out.append(i < 256 ? UInt8(i) : UInt8(truncatingIfNeeded: state))
        }
        return out
    }

    static func wrapped(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    static func message(_ id: String, attachmentSize: Int = 3_000, inline: Bool = true) -> Built {
        let seed = id.unicodeScalars.reduce(7) { $0 &* 31 &+ Int($1.value) }
        let pdf = Data("%PDF-1.4\n".utf8) + binary(seed: seed, count: attachmentSize)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + binary(seed: seed &+ 1, count: 700)
        let subject = "Bericht – März ✓ \(id)"
        let encodedSubject = "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
        let filename = "Bericht – März \(id).pdf"
        let rfc2231 = filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) ?? filename
        let mixed = "mix-\(id)", related = "rel-\(id)", cid = "logo-\(id)@sim.example"
        var s = ""
        s += "Message-ID: <\(id)@sim.example>\r\n"
        s += "From: =?UTF-8?Q?Asha_R=C3=A4o?= <asha@example.com>\r\n"
        s += "To: ravi@example.org\r\n"
        s += "Subject: \(encodedSubject)\r\n"
        s += "Date: Mon, 6 Jan 2025 10:00:00 +0530\r\n"
        s += "MIME-Version: 1.0\r\n"
        s += "Content-Type: multipart/mixed; boundary=\"\(mixed)\"\r\n\r\n"
        s += "--\(mixed)\r\n"
        var attachments: [Attachment] = []
        if inline {
            s += "Content-Type: multipart/related; boundary=\"\(related)\"\r\n\r\n"
            s += "--\(related)\r\n"
            s += "Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
            s += "<html><body><p>Grüße — Übersicht \(id) 日本語</p><img src=\"cid:\(cid)\"></body></html>\r\n"
            s += "--\(related)\r\n"
            s += "Content-Type: image/png; name=\"logo.png\"\r\nContent-Transfer-Encoding: base64\r\n"
            s += "Content-ID: <\(cid)>\r\nContent-Disposition: inline; filename=\"logo.png\"\r\n\r\n"
            s += wrapped(png) + "\r\n"
            s += "--\(related)--\r\n"
            attachments.append(Attachment(filename: "logo.png", data: png, contentID: cid))
        } else {
            s += "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
            s += "Grüße — plain body \(id) ü\r\n"
        }
        s += "--\(mixed)\r\n"
        s += "Content-Type: application/pdf; name*=UTF-8''\(rfc2231)\r\nContent-Transfer-Encoding: base64\r\n"
        s += "Content-Disposition: attachment; filename*=UTF-8''\(rfc2231)\r\n\r\n"
        s += wrapped(pdf) + "\r\n"
        s += "--\(mixed)--\r\n"
        attachments.append(Attachment(filename: filename, data: pdf, contentID: nil))
        return Built(raw: Data(s.utf8), attachments: attachments)
    }
}
