//
//  MIMECarver.swift
//  ArchiveCore
//
//  3.1 R9: recover RFC 5322 messages from any byte stream — a damaged mailbox,
//  an unknown blob, an extract of unallocated disk space. The file is read in
//  bounded windows (memory stays flat at any size). A candidate starts where a
//  run of message header lines begins at a line start; it ends at the next
//  candidate, an mbox "From " separator, a user template footer, or the size
//  ceiling. Only candidates that parse as a message with a sender and a date or
//  Message-ID are kept, so random data yields nothing.
//
//  User templates (AXIOM-style header/footer carving) cover odd containers:
//  a start marker, an optional end marker and a maximum length.
//

import Foundation

public struct CarvingTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Bytes that start a message (UTF-8 text or "hex:0A0B…").
    public var header: String
    /// Optional bytes that end it.
    public var footer: String?
    public var maxLength: Int

    public init(name: String, header: String, footer: String? = nil, maxLength: Int = 4 * 1_048_576) {
        self.name = name; self.header = header; self.footer = footer; self.maxLength = maxLength
    }

    var headerBytes: [UInt8] { Self.bytes(header) }
    var footerBytes: [UInt8]? { footer.map(Self.bytes) }

    static func bytes(_ s: String) -> [UInt8] {
        if s.hasPrefix("hex:") {
            let hex = Array(s.dropFirst(4).filter { !$0.isWhitespace })
            var out: [UInt8] = []
            var i = 0
            while i + 1 < hex.count {
                if let b = UInt8(String(hex[i...i + 1]), radix: 16) { out.append(b) }
                i += 2
            }
            return out
        }
        return Array(s.utf8)
    }
}

public struct CarvingResult: Sendable {
    var emails: [MBOXParser.RawEmail]
    public var candidates: Int
    public var rejected: Int
    public var bytesScanned: Int64
    /// Messages verified and kept (emitted or in `emails`).
    public var kept = 0
}

public enum MIMECarver {
    /// Header names that can open a message.
    static let openers: [[UInt8]] = ["Return-Path:", "Received:", "From:", "Message-ID:", "Message-Id:",
                                     "Delivered-To:", "X-Mozilla-Status:", "MIME-Version:", "Date:"].map { Array($0.utf8) }
    static let maxMessage = 8 * 1_048_576
    static let window = 4 * 1_048_576

    /// Carves every verifiable message from `url`. `templates` add custom start markers.
    /// With `emit`, messages are handed over in batches of `batchSize` and not
    /// kept (memory stays flat); `result.emails` then holds none and
    /// `result.kept` counts them.
    static func carve(url: URL, templates: [CarvingTemplate] = [],
                             senderEmail: String = "",
                             batchSize: Int = 200,
                             emit: (([MBOXParser.RawEmail]) async throws -> Void)? = nil,
                             progress: ((Int64, Int64) -> Void)? = nil) async throws -> CarvingResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        var result = CarvingResult(emails: [], candidates: 0, rejected: 0, bytesScanned: 0)
        var buffer: [UInt8] = []
        var bufferStart: Int64 = 0
        var eof = false
        var seen = Set<String>()

        func refill() throws {
            if eof { return }
            let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: window) }) ?? Data()
            if chunk.isEmpty { eof = true; return }
            buffer.append(contentsOf: chunk)
        }

        try refill()
        var i = 0
        while true {
            // Keep at least one full message ahead of the cursor.
            if !eof && buffer.count - i < maxMessage + 1024 {
                if i > 0 {
                    buffer.removeFirst(i)
                    bufferStart += Int64(i)
                    i = 0
                }
                try refill()
                continue
            }
            if i >= buffer.count { break }
            var matched: (start: Int, end: Int, template: CarvingTemplate?)?
            if let t = templates.first(where: { startsWith(buffer, at: i, $0.headerBytes) }) {
                let limit = min(buffer.count, i + t.maxLength)
                var end = limit
                if let footer = t.footerBytes, let f = find(buffer, footer, from: i + t.headerBytes.count, to: limit) {
                    end = f + footer.count
                }
                matched = (i, end, t)
            } else if (i == 0 || buffer[i - 1] == 0x0A), isHeaderRun(buffer, at: i) {
                let end = messageEnd(buffer, from: i)
                matched = (i, end, nil)
            }
            if let m = matched, m.end > m.start {
                result.candidates += 1
                let bytes = Array(buffer[m.start..<m.end])
                let offset = bufferStart + Int64(m.start)
                if let email = verify(bytes, offset: offset, template: m.template?.name, senderEmail: senderEmail) {
                    let key = (email.headers["Message-ID"] ?? "") + "|" + (email.headers["Date"] ?? "") + "|" + (email.headers["Subject"] ?? "")
                    if seen.insert(key).inserted {
                        result.kept += 1
                        result.emails.append(email)
                        if let emit, result.emails.count >= batchSize {
                            try await emit(result.emails)
                            result.emails.removeAll(keepingCapacity: true)
                        }
                    }
                    i = m.end
                    continue
                } else {
                    result.rejected += 1
                }
            }
            i += 1
            if i % 1_048_576 == 0 {
                progress?(bufferStart + Int64(i), size)
                try Task.checkCancellation()
            }
        }
        if let emit, !result.emails.isEmpty {
            try await emit(result.emails)
            result.emails.removeAll()
        }
        result.bytesScanned = bufferStart + Int64(buffer.count)
        progress?(result.bytesScanned, size)
        return result
    }

    /// At least two consecutive "Name: value" lines, one of them an opener.
    static func isHeaderRun(_ b: [UInt8], at i: Int) -> Bool {
        guard openers.contains(where: { startsWith(b, at: i, $0) }) else { return false }
        var lines = 0
        var p = i
        while lines < 3, p < b.count {
            guard let nl = find(b, [0x0A], from: p, to: min(b.count, p + 2000)) else { return false }
            let line = b[p..<nl]
            guard let colon = line.firstIndex(of: 0x3A), colon > p,
                  line[p..<colon].allSatisfy({ ($0 >= 0x21 && $0 <= 0x7E) }) else {
                // Continuation lines (start with space/tab) are fine.
                if let first = line.first, first == 0x20 || first == 0x09 { p = nl + 1; continue }
                return lines >= 2
            }
            lines += 1
            p = nl + 1
        }
        return lines >= 2
    }

    /// End of a message: next mbox separator, next header run after a blank
    /// line, or the ceiling.
    static func messageEnd(_ b: [UInt8], from start: Int) -> Int {
        let limit = min(b.count, start + maxMessage)
        var p = start + 1
        while p < limit {
            guard let nl = find(b, [0x0A], from: p, to: limit) else { return limit }
            let next = nl + 1
            if next >= limit { return limit }
            if startsWith(b, at: next, Array("From ".utf8)) { return nl + 1 }
            // A blank line followed by a fresh header run starts the next message.
            if nl > 0, b[nl - 1] == 0x0A || (nl > 1 && b[nl - 1] == 0x0D && b[nl - 2] == 0x0A) {
                if isHeaderRun(b, at: next), openers.prefix(5).contains(where: { startsWith(b, at: next, $0) }),
                   next - start > 200 {
                    return next
                }
            }
            p = next
        }
        return limit
    }

    /// A candidate counts only when it parses with a sender and a date or
    /// Message-ID and has a header/body separator.
    static func verify(_ bytes: [UInt8], offset: Int64, template: String?, senderEmail: String) -> MBOXParser.RawEmail? {
        guard find(bytes, [0x0A, 0x0A], from: 0, to: bytes.count) != nil
                || find(bytes, [0x0D, 0x0A, 0x0D, 0x0A], from: 0, to: bytes.count) != nil else { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        guard var email = try? MBOXParser.processRawMessage(text, senderEmail: senderEmail) else { return nil }
        let hasFrom = !(email.headers["From"] ?? "").isEmpty
        let hasDateOrID = !(email.headers["Date"] ?? "").isEmpty || !(email.headers["Message-ID"] ?? "").isEmpty
        guard hasFrom && hasDateOrID else { return nil }
        let truncated = bytes.count >= maxMessage
        email.recovery = RecoveryInfo(state: .carved, method: template.map { "template:\($0)" } ?? "mime-carve",
                                      evidence: "message header run at byte \(offset)",
                                      offset: offset, partial: truncated || email.plainBody.isEmpty && email.htmlBody.isEmpty)
        return email
    }

    static func startsWith(_ b: [UInt8], at i: Int, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, i + needle.count <= b.count else { return false }
        for k in 0..<needle.count where b[i + k] != needle[k] { return false }
        return true
    }

    static func find(_ b: [UInt8], _ needle: [UInt8], from: Int, to: Int) -> Int? {
        guard !needle.isEmpty, from >= 0 else { return nil }
        var p = from
        while p + needle.count <= to {
            if b[p] == needle[0] && startsWith(b, at: p, needle) { return p }
            p += 1
        }
        return nil
    }
}
