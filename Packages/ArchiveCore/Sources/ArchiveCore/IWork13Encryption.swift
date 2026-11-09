//
//  IWork13Encryption.swift
//  ArchiveCore
//
//  Password-protected iWork 2013+ documents (Pages / Numbers / Keynote,
//  IWA format), opened with the Unlock password — used for the one call,
//  never stored. New code (rule 14); `IWorkDocumentReader` calls it only when
//  the document carries a `.iwpv2` verifier and a password is given; without
//  one the document stays "locked", as before.
//
//  The scheme, as described publicly by John the Ripper's iwork2john.py /
//  iwork_fmt (format 2, from obriensp/iWorkFileFormat), written here from
//  that description and confirmed on documents saved with a password by
//  Pages, Numbers and Keynote 14.4 (Fixtures/derived/iwork-password):
//
//    verifier   the member ".iwpv2" at the top of the document or bundle,
//               104 bytes: u16 version 2, u16 format 1, u32 iterations
//               (100,000 seen), 16-byte salt, 16-byte IV, 64-byte blob
//    key        PBKDF2-HMAC-SHA1(password UTF-8, salt, iterations, 16 bytes)
//    check      AES-128-CBC(key, IV) over the blob: the last 32 bytes are the
//               SHA-256 of the first 32; otherwise the password is wrong
//    members    every Index/*.iwa (in the single file, or inside the bundle's
//               Index.zip; Data/ files too, which are not text): 16 bytes
//               (differ on every save), 16-byte IV, AES-128-CBC cipher text
//               with PKCS#7 padding, 20 trailing bytes. The plain text is an
//               ordinary snappy-framed IWA file.
//
//  The 20 trailing bytes are the same for the same plain text across saves;
//  how they are keyed is not in the public description, so they are not
//  checked. The plain text is checked by the verifier, the padding and the
//  IWA framing that the reader parses next. ".iwph" holds the password hint
//  (not read); Metadata/ stays plain.
//

import Foundation
import CryptoKit

enum IWork13Encryption {

    static let verifierName = ".iwpv2"
    static let hintName = ".iwph"
    /// Bytes around a member's cipher text: 16 + 16-byte IV before, 20 after.
    static let headerBytes = 32
    static let trailerBytes = 20

    struct Verifier: Equatable {
        var iterations: UInt32
        var salt: [UInt8]
        var iv: [UInt8]
        var blob: [UInt8]
    }

    /// True for the document's ".iwpv2" member (any bundle prefix).
    static func isVerifier(_ name: String) -> Bool { (name as NSString).lastPathComponent == verifierName }

    static func parse(_ bytes: [UInt8]) throws -> Verifier {
        guard bytes.count >= 104 else { throw ProtectedContentError.malformed("iWork password verifier of \(bytes.count) bytes") }
        let version = u16(bytes, 0), format = u16(bytes, 2)
        guard version == 2, format == 1 else {
            throw ProtectedContentError.unsupported("iWork password verifier version \(version) format \(format)")
        }
        return Verifier(iterations: u32(bytes, 4), salt: Array(bytes[8..<24]), iv: Array(bytes[24..<40]), blob: Array(bytes[40..<104]))
    }

    /// The document key for `password`, or `ExtractError.wrongPassword`.
    static func key(password: String, verifier: Verifier) throws -> [UInt8] {
        guard verifier.iterations > 0, verifier.iterations <= 10_000_000 else {
            throw ProtectedContentError.malformed("iWork iteration count \(verifier.iterations)")
        }
        let key = CryptoPrimitives.pbkdf2SHA1(password: password, salt: verifier.salt, rounds: verifier.iterations, length: 16)
        let plain = try CryptoPrimitives.aesCBC(verifier.blob, key: key, iv: verifier.iv, encrypt: false)
        guard plain.count == 64, Array(SHA256.hash(data: plain[0..<32])) == Array(plain[32..<64]) else {
            throw OfficeTextExtractor.ExtractError.wrongPassword
        }
        return key
    }

    /// The plain bytes of one protected member.
    static func decrypt(_ stored: Data, key: [UInt8], name: String) throws -> Data {
        let bytes = [UInt8](stored)
        let cipherCount = bytes.count - headerBytes - trailerBytes
        guard cipherCount >= 16, cipherCount % 16 == 0 else {
            throw OfficeTextExtractor.ExtractError.notAPackage("protected iWork member \(name) of \(bytes.count) bytes is not whole AES blocks")
        }
        var plain = try CryptoPrimitives.aesCBC(Array(bytes[headerBytes..<(headerBytes + cipherCount)]), key: key,
                                                iv: Array(bytes[16..<32]), encrypt: false)
        guard let pad = plain.last, pad >= 1, pad <= 16, Int(pad) <= plain.count,
              plain.suffix(Int(pad)).allSatisfy({ $0 == pad }) else {
            throw OfficeTextExtractor.ExtractError.notAPackage("protected iWork member \(name): bad padding after decryption")
        }
        plain.removeLast(Int(pad))
        return Data(plain)
    }

    /// A plain ZIP of the document's Index/*.iwa members (decrypted; those of
    /// a bundle's inner Index.zip included) in `scratch`, plus the members
    /// over the part guard, named for the caller's "skipped" list.
    static func unlock(fileURL: URL, members: [ZIPArchiveReader.Member], password: String, scratch: URL,
                       limit: Int64) throws -> (url: URL, skipped: [String]) {
        guard let verifierMember = members.filter({ isVerifier($0.name) && !$0.isDirectory })
            .min(by: { $0.name.count < $1.name.count }) else {
            throw OfficeTextExtractor.ExtractError.notAPackage("protected iWork document without its password verifier")
        }
        guard verifierMember.uncompressedSize <= 4096 else {
            throw OfficeTextExtractor.ExtractError.notAPackage("iWork password verifier of \(verifierMember.uncompressedSize) bytes")
        }
        let verifier: Verifier
        do { verifier = try parse([UInt8](try DocumentTextExtractor.memberData(verifierMember, from: fileURL, scratch: scratch))) } catch let error as ProtectedContentError {
            throw OfficeTextExtractor.ExtractError.notAPackage(error.localizedDescription)
        }
        let key = try key(password: password, verifier: verifier)

        var entries: [MiniZIPWriter.Entry] = []
        var skipped: [String] = []
        func add(_ member: ZIPArchiveReader.Member, from archive: URL) throws {
            guard member.uncompressedSize <= limit + Int64(headerBytes + trailerBytes) else {
                skipped.append("\(member.name) (\(member.uncompressedSize) bytes, over the \(limit)-byte guard)")
                return
            }
            let stored = try DocumentTextExtractor.memberData(member, from: archive, scratch: scratch)
            entries.append(.init(name: member.name, data: try decrypt(stored, key: key, name: member.name), deflate: false))
        }
        for member in members where !member.isDirectory {
            let name = member.name
            if (name as NSString).lastPathComponent == "Index.zip" {
                guard member.uncompressedSize <= ExtractionLimits.effective.totalArchiveBytes else {
                    skipped.append("\(name) (\(member.uncompressedSize) bytes, over the \(ExtractionLimits.effective.totalArchiveBytes)-byte guard)")
                    continue
                }
                let innerURL = scratch.appendingPathComponent(UUID().uuidString + ".zip")
                try ZIPArchiveReader.extract(member, from: fileURL, to: innerURL)
                let inner: [ZIPArchiveReader.Member]
                do { inner = try ZIPArchiveReader.members(of: innerURL) } catch {
                    throw OfficeTextExtractor.ExtractError.notAPackage("\(name): \(error)")
                }
                for innerMember in inner where !innerMember.isDirectory && isIWA(innerMember.name) {
                    try add(innerMember, from: innerURL)
                }
                try? FileManager.default.removeItem(at: innerURL)
            } else if isIWA(name) {
                try add(member, from: fileURL)
            }
        }
        let url = scratch.appendingPathComponent(UUID().uuidString + ".zip")
        try MiniZIPWriter.archive(entries).write(to: url)
        return (url, skipped)
    }

    /// "Index/…/*.iwa", with or without a bundle prefix.
    static func isIWA(_ name: String) -> Bool {
        guard name.hasSuffix(".iwa") else { return false }
        return name.hasPrefix("Index/") || name.contains("/Index/")
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}
