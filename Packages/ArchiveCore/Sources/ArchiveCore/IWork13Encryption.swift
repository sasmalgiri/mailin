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
//  how they are keyed is not in the public description (SHA-1 / HMAC-SHA1
//  of the plain or cipher text with the key, salt or member header were
//  tried on the Pages fixture; none matched), so they are not checked.
//  CUR-06: three separate facts — the PASSWORD is checked by the verifier;
//  the content PARSES (padding, then the IWA framing the reader decodes
//  next); its INTEGRITY is not cryptographically verified, and every reading
//  says so (`integrityNote` in `OfficeTextExtractor.Result.notes`). ".iwph" holds the password hint
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

    /// What every reading opened this way says beside its text (CUR-06): the
    /// password check, the parse and the payload's integrity are separate
    /// facts, and only the first two are checked.
    static let integrityNote = "password verified; content read, but its integrity is not cryptographically verified (the 20-byte member trailer is not checked), so damage inside the encrypted data may go undetected"

    /// CUR-05: a full disk or another write failure while making the plain
    /// copy — named; nothing half-written is left in scratch.
    enum UnlockError: Error, LocalizedError, Equatable {
        case diskFull(member: String)
        case writeFailed(member: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .diskFull(let member):
                return "the unlocked copy of \(member) could not be written: the disk is full (nothing was kept)"
            case .writeFailed(let member, let detail):
                return "the unlocked copy of \(member) could not be written: \(detail) (nothing was kept)"
            }
        }

        static func from(_ error: Error, member: String) -> Error {
            if error is UnlockError || error is CancellationError { return error }
            let ns = error as NSError
            func isENOSPC(_ e: NSError) -> Bool { e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC) }
            let full = isENOSPC(ns) || (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
                || ((ns.userInfo[NSUnderlyingErrorKey] as? NSError).map(isENOSPC) ?? false)
            return full ? UnlockError.diskFull(member: member) : UnlockError.writeFailed(member: member, detail: ns.localizedDescription)
        }
    }

    /// A plain ZIP of the document's Index/*.iwa members (decrypted; those of
    /// a bundle's inner Index.zip included) in `scratch`, plus the members
    /// over the part guard, named for the caller's "skipped" list.
    ///
    /// CUR-05: streamed. Each member is extracted to a scratch file, decrypted
    /// in 1 MiB blocks into a second scratch file, copied into a file-backed
    /// ZIP (`StreamingZIPWriter`, central directory spooled to disk), and both
    /// scratch files are removed — live memory is a few MiB whatever the
    /// member count or the sum of their sizes. `isCancelled` is asked before
    /// every member and every block (`CancellationError`); a failed write is
    /// `UnlockError` (a full disk named). On any error the partial ZIP and the
    /// scratch files are removed before it is thrown.
    static func unlock(fileURL: URL, members: [ZIPArchiveReader.Member], password: String, scratch: URL,
                       limit: Int64, isCancelled: () -> Bool = { Task.isCancelled },
                       makeSink: StreamingZIPWriter.SinkFactory = { try FileZIPSink(url: $0) }) throws -> (url: URL, skipped: [String]) {
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

        let url = scratch.appendingPathComponent(UUID().uuidString + ".zip")
        let writer: StreamingZIPWriter
        do { writer = try StreamingZIPWriter(destination: url, makeSink: makeSink) } catch {
            throw UnlockError.from(error, member: "the document")
        }
        var skipped: [String] = []
        func add(_ member: ZIPArchiveReader.Member, from archive: URL) throws {
            if isCancelled() { throw CancellationError() }
            guard member.uncompressedSize <= limit + Int64(headerBytes + trailerBytes) else {
                skipped.append("\(member.name) (\(member.uncompressedSize) bytes, over the \(limit)-byte guard)")
                return
            }
            let stored = scratch.appendingPathComponent(UUID().uuidString)
            let plain = scratch.appendingPathComponent(UUID().uuidString)
            defer {
                try? FileManager.default.removeItem(at: stored)
                try? FileManager.default.removeItem(at: plain)
            }
            // One pool per member: FileHandle reads hand back autoreleased
            // buffers, which would otherwise live until the whole unlock ends.
            try autoreleasepool {
                try ZIPArchiveReader.extract(member, from: archive, to: stored)
                let (size, crc) = try decryptFile(stored, to: plain, key: key, name: member.name, isCancelled: isCancelled, makeSink: makeSink)
                do { try writer.addStored(name: member.name, contentsOf: plain, size: size, crc: crc) } catch {
                    throw UnlockError.from(error, member: member.name)
                }
            }
        }
        do {
            for member in members where !member.isDirectory {
                let name = member.name
                if (name as NSString).lastPathComponent == "Index.zip" {
                    guard member.uncompressedSize <= ExtractionLimits.effective.totalArchiveBytes else {
                        skipped.append("\(name) (\(member.uncompressedSize) bytes, over the \(ExtractionLimits.effective.totalArchiveBytes)-byte guard)")
                        continue
                    }
                    let innerURL = scratch.appendingPathComponent(UUID().uuidString + ".zip")
                    defer { try? FileManager.default.removeItem(at: innerURL) }
                    try ZIPArchiveReader.extract(member, from: fileURL, to: innerURL)
                    let inner: [ZIPArchiveReader.Member]
                    do { inner = try ZIPArchiveReader.members(of: innerURL) } catch {
                        throw OfficeTextExtractor.ExtractError.notAPackage("\(name): \(error)")
                    }
                    for innerMember in inner where !innerMember.isDirectory && isIWA(innerMember.name) {
                        try add(innerMember, from: innerURL)
                    }
                } else if isIWA(name) {
                    try add(member, from: fileURL)
                }
            }
            if isCancelled() { throw CancellationError() }
            do { try writer.finish() } catch { throw UnlockError.from(error, member: "the document") }
        } catch {
            writer.abandon()
            throw error
        }
        return (url, skipped)
    }

    /// Decrypts one stored member file (16 bytes, IV, cipher text, 20-byte
    /// trailer) into `destination` in 1 MiB blocks; returns the plain size and
    /// CRC-32. The last block's padding is checked; the trailer is not (see
    /// `integrityNote`). On any error `destination` is removed.
    static func decryptFile(_ source: URL, to destination: URL, key: [UInt8], name: String,
                            isCancelled: () -> Bool = { Task.isCancelled },
                            makeSink: StreamingZIPWriter.SinkFactory = { try FileZIPSink(url: $0) }) throws -> (size: UInt64, crc: UInt32) {
        let total = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        let cipherCount = total - Int64(headerBytes + trailerBytes)
        guard cipherCount >= 16, cipherCount % 16 == 0 else {
            throw OfficeTextExtractor.ExtractError.notAPackage("protected iWork member \(name) of \(total) bytes is not whole AES blocks")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let header = try input.read(upToCount: headerBytes) ?? Data()
        guard header.count == headerBytes else {
            throw OfficeTextExtractor.ExtractError.notAPackage("protected iWork member \(name): truncated header")
        }
        let decryptor: RARCrypto.CBCDecryptor
        do { decryptor = try RARCrypto.CBCDecryptor(key: key, iv: Array(header[16..<32])) } catch {
            throw OfficeTextExtractor.ExtractError.notAPackage("protected iWork member \(name): the AES decryptor could not be started")
        }
        let sink: ZIPByteSink
        do { sink = try makeSink(destination) } catch { throw UnlockError.from(error, member: name) }
        var done = false
        defer { if !done { try? sink.close(); try? FileManager.default.removeItem(at: destination) } }
        var crc = ZIPArchiveReader.CRC32()
        var size: UInt64 = 0
        var held: [UInt8] = []          // the last plain block, written once the next one (or the end) arrives
        var remaining = cipherCount
        while remaining > 0 {
            if isCancelled() { throw CancellationError() }
            try autoreleasepool {
                let want = Int(min(Int64(StreamingZIPWriter.chunkBytes), remaining))
                let chunk = try input.read(upToCount: want) ?? Data()
                guard chunk.count == want else {
                    throw OfficeTextExtractor.ExtractError.notAPackage("protected iWork member \(name): truncated cipher text")
                }
                remaining -= Int64(want)
                let plain: [UInt8]
                do { plain = try decryptor.update([UInt8](chunk)) } catch {
                    throw OfficeTextExtractor.ExtractError.notAPackage("protected iWork member \(name): AES decryption failed")
                }
                let out = Data(held + plain.dropLast(16))
                held = Array(plain.suffix(16))
                if !out.isEmpty {
                    do { try sink.write(out) } catch { throw UnlockError.from(error, member: name) }
                    crc.update(out); size += UInt64(out.count)
                }
            }
        }
        guard let pad = held.last, pad >= 1, pad <= 16, held.suffix(Int(pad)).allSatisfy({ $0 == pad }) else {
            throw OfficeTextExtractor.ExtractError.notAPackage("protected iWork member \(name): bad padding after decryption (damaged, or not this scheme)")
        }
        let last = Data(held.dropLast(Int(pad)))
        do {
            if !last.isEmpty { try sink.write(last) }
            done = true
            try sink.close()
        } catch {
            done = true
            try? sink.close()
            try? FileManager.default.removeItem(at: destination)
            throw UnlockError.from(error, member: name)
        }
        crc.update(last); size += UInt64(last.count)
        return (size, crc.value)
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
