//
//  IWork09Encryption.swift
//  ArchiveCore
//
//  Audit R6 "protected iWork '09": Pages / Numbers / Keynote '09 documents
//  saved with a password, opened with the Unlock password (used for the one
//  call, never stored). New code (rule 14); `IWorkDocumentReader` calls it
//  only when a password is given — without one the document stays "locked".
//
//  The scheme, as published in John the Ripper's iwork2john.py / iwork_fmt
//  (Kholia & Hulliger 2015, from obriensp/iWorkFileFormat IWPasswordVerifier)
//  and confirmed here on Apache Tika's testPagesPwdProtected.pages
//  (password "tika"):
//
//    verifier   a central-directory extra field whose data starts "iwpv":
//               u16 version 1, u16 format 1, u32 iterations, 16-byte IV,
//               64-byte blob (anything after it is not used)
//    key        PBKDF2-HMAC-SHA1(password UTF-8, salt "someSalt", iterations,
//               16 bytes) — the fixed salt is what the '09 apps write
//    check      AES-128-CBC(key, IV) over the blob: the last 32 bytes are the
//               SHA-256 of the first 32; otherwise the password is wrong
//    members    Apple's ZIP methods 25451 (encrypted, stored) and 25452
//               (encrypted, deflated): 32 bytes precede the cipher text, the
//               second 16 of them its CBC chaining value; AES-128-CBC with
//               the key, PKCS#7 padding; 25452 is then raw DEFLATE
//
//  The ZIP CRC of a protected member covers the stored (encrypted) bytes, so
//  the plain text is checked by the verifier, the padding and the inflate.
//  Other extra fields seen: "iwph" (the password hint, not read) and "iwuu"
//  (a document UUID).
//

import Foundation
import CryptoKit

enum IWork09Encryption {

    static let encryptedStored: UInt16 = 25451
    static let encryptedDeflated: UInt16 = 25452
    static let salt = Array("someSalt".utf8)

    struct Verifier: Equatable {
        var iterations: UInt32
        var iv: [UInt8]
        var blob: [UInt8]
    }

    /// The password verifier from the central directory, or nil when the
    /// document carries none.
    static func verifier(in fileURL: URL) throws -> Verifier? {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let tailLength = min(size, 65_557)
        try handle.seek(toOffset: size - tailLength)
        let tail = [UInt8](try handle.read(upToCount: Int(tailLength)) ?? Data())
        guard tail.count >= 22 else { return nil }
        var eocd: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard let e = eocd else { return nil }
        let cdSize = UInt64(u32(tail, e + 12)), cdOffset = UInt64(u32(tail, e + 16))
        guard cdSize > 0, cdSize < 64 * 1_048_576, cdOffset + cdSize <= size else { return nil }
        try handle.seek(toOffset: cdOffset)
        let cd = [UInt8](try handle.read(upToCount: Int(cdSize)) ?? Data())
        var p = 0
        while p + 46 <= cd.count, u32(cd, p) == 0x0201_4B50 {
            let nameLength = Int(u16(cd, p + 28)), extraLength = Int(u16(cd, p + 30)), commentLength = Int(u16(cd, p + 32))
            var x = p + 46 + nameLength
            let extraEnd = min(x + extraLength, cd.count)
            while x + 4 <= extraEnd {
                let length = Int(u16(cd, x + 2))
                let start = x + 4
                guard start + length <= extraEnd else { break }
                if length >= 92, Array(cd[start..<(start + 4)]) == Array("iwpv".utf8) {
                    let version = u16(cd, start + 4), format = u16(cd, start + 6)
                    guard version == 1, format == 1 else {
                        throw ProtectedContentError.unsupported("iWork '09 password verifier version \(version) format \(format)")
                    }
                    return Verifier(iterations: u32(cd, start + 8), iv: Array(cd[(start + 12)..<(start + 28)]),
                                    blob: Array(cd[(start + 28)..<(start + 92)]))
                }
                x = start + length
            }
            p += 46 + nameLength + extraLength + commentLength
        }
        return nil
    }

    /// The document key for `password`, or `wrongPassword`.
    static func key(password: String, verifier: Verifier) throws -> [UInt8] {
        guard verifier.iterations > 0, verifier.iterations <= 10_000_000 else {
            throw ProtectedContentError.malformed("iWork '09 iteration count \(verifier.iterations)")
        }
        let key = CryptoPrimitives.pbkdf2SHA1(password: password, salt: salt, rounds: verifier.iterations, length: 16)
        let plain = try CryptoPrimitives.aesCBC(verifier.blob, key: key, iv: verifier.iv, encrypt: false)
        guard plain.count == 64, Array(SHA256.hash(data: plain[0..<32])) == Array(plain[32..<64]) else {
            throw OfficeTextExtractor.ExtractError.wrongPassword
        }
        return key
    }

    /// The plain bytes of one protected member's stored data.
    static func decrypt(stored: Data, method: UInt16, key: [UInt8], limit: Int) throws -> Data {
        let bytes = [UInt8](stored)
        guard bytes.count >= 48, (bytes.count - 32) % 16 == 0 else {
            throw OfficeTextExtractor.ExtractError.notAPackage("protected iWork member of \(bytes.count) bytes is not whole AES blocks")
        }
        var plain = try CryptoPrimitives.aesCBC(Array(bytes[32...]), key: key, iv: Array(bytes[16..<32]), encrypt: false)
        guard let pad = plain.last, pad >= 1, pad <= 16, Int(pad) <= plain.count,
              plain.suffix(Int(pad)).allSatisfy({ $0 == pad }) else {
            throw OfficeTextExtractor.ExtractError.notAPackage("protected iWork member: bad padding after decryption")
        }
        plain.removeLast(Int(pad))
        switch method {
        case encryptedStored:
            guard plain.count <= limit else { throw OfficeTextExtractor.ExtractError.notAPackage("protected member over the \(limit)-byte guard") }
            return Data(plain)
        case encryptedDeflated:
            do { return try RawDeflate.inflate(Data(plain), limit: limit) } catch {
                throw OfficeTextExtractor.ExtractError.notAPackage("protected iWork member does not inflate: \(error)")
            }
        default:
            throw ProtectedContentError.unsupported("ZIP method \(method)")
        }
    }

    /// A plain ZIP of the document (protected members decrypted, the others
    /// copied when within the part guard) in `scratch`, plus the names that
    /// were left out (over the guard; listed by the caller as not read).
    static func unlock(fileURL: URL, members: [ZIPArchiveReader.Member], password: String, scratch: URL,
                       limit: Int64) throws -> (url: URL, leftOut: [String]) {
        guard let verifier = try verifier(in: fileURL) else {
            throw OfficeTextExtractor.ExtractError.notAPackage("protected iWork '09 document without its password verifier")
        }
        let key = try key(password: password, verifier: verifier)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var entries: [MiniZIPWriter.Entry] = []
        var leftOut: [String] = []
        for member in members where !member.isDirectory {
            if member.method == encryptedStored || member.method == encryptedDeflated {
                guard member.compressedSize <= limit + 64 else { leftOut.append(member.name); continue }
                let stored = try storedBytes(of: member, handle: handle)
                entries.append(.init(name: member.name, data: try decrypt(stored: stored, method: member.method, key: key, limit: Int(limit)), deflate: false))
            } else if member.uncompressedSize <= limit {
                entries.append(.init(name: member.name, data: try DocumentTextExtractor.memberData(member, from: fileURL, scratch: scratch), deflate: false))
            } else {
                leftOut.append(member.name)
            }
        }
        let url = scratch.appendingPathComponent(UUID().uuidString + ".zip")
        try MiniZIPWriter.archive(entries).write(to: url)
        return (url, leftOut)
    }

    /// The stored bytes of a member (after its local header).
    static func storedBytes(of member: ZIPArchiveReader.Member, handle: FileHandle) throws -> Data {
        try handle.seek(toOffset: UInt64(member.localHeaderOffset))
        let header = [UInt8](try handle.read(upToCount: 30) ?? Data())
        guard header.count == 30, u32(header, 0) == 0x0403_4B50 else {
            throw OfficeTextExtractor.ExtractError.notAPackage("\(member.name): no local header")
        }
        let skip = UInt64(u16(header, 26)) + UInt64(u16(header, 28))
        try handle.seek(toOffset: UInt64(member.localHeaderOffset) + 30 + skip)
        let data = try handle.read(upToCount: Int(member.compressedSize)) ?? Data()
        guard data.count == Int(member.compressedSize) else { throw OfficeTextExtractor.ExtractError.notAPackage("\(member.name): truncated") }
        return data
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}
