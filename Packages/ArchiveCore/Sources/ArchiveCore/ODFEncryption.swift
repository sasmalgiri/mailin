//
//  ODFEncryption.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "Protected mail/documents": password-protected
//  OpenDocument packages, read by the OpenDocument 1.2 part 3 §4.8 rules
//  (`META-INF/manifest.xml`, `manifest:encryption-data`):
//
//    start key        SHA-1 (ODF 1.0/1.1 default) or SHA-256 of the UTF-8 password
//    key derivation   PBKDF2-HMAC-SHA1 over the start key, the entry's salt and
//                     iteration count (OpenOffice.org 1,024; LibreOffice 100,000);
//                     or Argon2id (LibreOffice 7.x/24.x option; audit R6): RFC 9106
//                     over the start key and salt with the manifest's argon2-
//                     iterations / -memory / -lanes (Argon2.swift)
//    cipher           Blowfish in 8-bit CFB (ODF 1.0/1.1, "Blowfish CFB"),
//                     AES-128/192/256-CBC with W3C padding (ODF 1.2),
//                     AES-256-GCM (LibreOffice 24.2+, xmlenc11)
//    checksum         SHA1/1K or SHA256/1K: the digest of the first 1,024 bytes
//                     of the DECRYPTED (still deflated) entry — the password check
//    payload          after decryption the entry is raw DEFLATE (RFC 1951)
//
//  Every encrypted entry is stored (method 0) in the ZIP; `manifest:size` is
//  the plain size. Nothing here keeps a password or a key. A wrong password is
//  `OfficeTextExtractor.ExtractError.wrongPassword`; a key derivation or cipher
//  this build cannot do is named ("locked: Argon2 key derivation not supported")
//  and never guessed around.
//
//  `encrypt(members:password:parameters:)` builds a protected package the same
//  way LibreOffice does, so tests can round-trip spec-built fixtures with
//  LibreOffice-compatible parameters; the real check is Apache Tika's
//  LibreOffice-written `testODTEncrypted.odt` (password "tika").
//

import Foundation
import CommonCrypto
import CryptoKit
import Compression

enum ODFEncryption {

    // MARK: - Manifest

    /// One `manifest:encryption-data` element, as written.
    struct EntryEncryption: Sendable, Equatable {
        var fullPath: String
        /// `manifest:size` — the plain (inflated) size, when given.
        var plainSize: Int?
        var checksumType: String?
        var checksum: Data?
        var algorithmName: String?
        var iv: Data?
        var keyDerivationName: String?
        var keySize: Int?
        var iterationCount: Int?
        var salt: Data?
        var startKeyGenerationName: String?
        var startKeySize: Int?
        /// LibreOffice Argon2id parameters (loext), when present.
        var argon2Iterations: Int?
        var argon2Memory: Int?
        var argon2Lanes: Int?
    }

    /// Entries of a manifest that carry encryption data, by full path.
    static func encryptedEntries(manifest: Data) -> [String: EntryEncryption] {
        let collector = ManifestCollector()
        guard collector.parse(manifest) else { return [:] }
        return collector.entries
    }

    /// True when any entry of the package is encrypted.
    static func isEncrypted(manifest: Data) -> Bool { !encryptedEntries(manifest: manifest).isEmpty }

    /// Argon2id key derivation names (ODF 1.5 and LibreOffice's earlier loext name).
    static let argon2idName = "urn:oasis:names:tc:opendocument:xmlns:manifest:1.5#argon2id"
    static let argon2idNameLibreOffice = "urn:org:documentfoundation:names:experimental:office:manifest:argon2id"

    // MARK: - Errors

    enum UnlockError: Error, LocalizedError, Equatable {
        case keyDerivationUnsupported(String)
        case algorithmUnsupported(String)
        case checksumUnsupported(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .keyDerivationUnsupported(let name): return "locked: \(name) key derivation not supported"
            case .algorithmUnsupported(let name): return "locked: \(name) encryption not supported"
            case .checksumUnsupported(let name): return "locked: \(name) checksum not supported"
            case .malformed(let what): return "encrypted OpenDocument entry is malformed: \(what)"
            }
        }
    }

    // MARK: - Decryption

    /// The plain (inflated) bytes of one encrypted entry, or `wrongPassword`.
    /// - Parameter limit: the most plain bytes allowed (the caller's part guard).
    static func decrypt(entry: EntryEncryption, cipherText: Data, password: String, limit: Int) throws -> Data {
        let deflated = try decryptToDeflated(entry: entry, cipherText: cipherText, password: password)
        return try RawDeflate.inflate(deflated, limit: limit)
    }

    /// The decrypted but still deflated bytes (what the checksum covers).
    static func decryptToDeflated(entry: EntryEncryption, cipherText: Data, password: String) throws -> Data {
        guard let iv = entry.iv, let salt = entry.salt else { throw UnlockError.malformed("\(entry.fullPath): missing salt or initialisation vector") }
        let algorithm = try Algorithm(name: entry.algorithmName)
        let keySize = entry.keySize ?? algorithm.defaultKeySize

        // Start key: a digest of the password (SHA-1 unless the manifest says SHA-256).
        let startKey: [UInt8]
        switch (entry.startKeyGenerationName ?? "").lowercased() {
        case "", "http://www.w3.org/2000/09/xmldsig#sha1", "sha1":
            startKey = Array(Insecure.SHA1.hash(data: Data(password.utf8)))
        case "http://www.w3.org/2000/09/xmldsig#sha256", "sha256":
            startKey = Array(SHA256.hash(data: Data(password.utf8)))
        default:
            throw UnlockError.keyDerivationUnsupported("start key \(entry.startKeyGenerationName ?? "")")
        }

        // Derived key.
        let key: [UInt8]
        switch (entry.keyDerivationName ?? "PBKDF2").lowercased() {
        case "pbkdf2", "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0#pbkdf2":
            let rounds = UInt32(clamping: entry.iterationCount ?? 1024)
            guard rounds > 0, rounds <= 10_000_000 else { throw UnlockError.malformed("\(entry.fullPath): iteration count \(rounds)") }
            key = pbkdf2SHA1(password: startKey, salt: Array(salt), rounds: rounds, length: keySize)
        case Self.argon2idName.lowercased(), Self.argon2idNameLibreOffice.lowercased():
            // Audit R6: LibreOffice's Argon2id (ZipFile.cxx: argon2id_ctx over the
            // start key and the entry's salt, version 0x13, no secret or data).
            guard let t = entry.argon2Iterations, let m = entry.argon2Memory, let p = entry.argon2Lanes, t > 0, m > 0, p > 0 else {
                throw UnlockError.malformed("\(entry.fullPath): Argon2id without its iterations, memory and lanes")
            }
            do {
                key = try Argon2.hash(password: startKey, salt: Array(salt), iterations: UInt32(t), memoryKiB: UInt32(m), lanes: UInt32(p),
                                      tagLength: keySize, variant: .id)
            } catch let failure as Argon2.Failure {
                throw UnlockError.keyDerivationUnsupported("Argon2id (\(failure.localizedDescription))")
            }
        case let name where name.contains("argon2"):
            throw UnlockError.keyDerivationUnsupported("Argon2")
        default:
            throw UnlockError.keyDerivationUnsupported(entry.keyDerivationName ?? "")
        }

        var plain = try algorithm.decrypt(cipherText, key: key, iv: Array(iv))
        if algorithm.hasW3CPadding {
            // W3C XML Encryption padding: the last byte is the pad length.
            guard let last = plain.last, last >= 1, Int(last) <= 16, Int(last) <= plain.count else {
                throw OfficeTextExtractor.ExtractError.wrongPassword
            }
            plain.removeLast(Int(last))
        }

        // Checksum: the first 1,024 bytes of the decrypted, deflated entry
        // (after padding removal, as LibreOffice finalizes short entries).
        if let checksum = entry.checksum {
            let covered = Data(plain.prefix(1024))
            let digest: [UInt8]
            switch (entry.checksumType ?? "").lowercased() {
            case "sha1/1k", "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0#sha1-1k":
                digest = Array(Insecure.SHA1.hash(data: covered))
            case "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0#sha256-1k", "sha256/1k":
                digest = Array(SHA256.hash(data: covered))
            case "sha1":
                digest = Array(Insecure.SHA1.hash(data: Data(plain)))
            default:
                throw UnlockError.checksumUnsupported(entry.checksumType ?? "")
            }
            guard digest == Array(checksum) else { throw OfficeTextExtractor.ExtractError.wrongPassword }
        } else if algorithm != .aes256GCM {
            // No checksum and no authenticated cipher: the deflate stream itself
            // must parse, which `RawDeflate.inflate` enforces; a wrong key fails there.
            if plain.isEmpty { throw OfficeTextExtractor.ExtractError.wrongPassword }
        }
        return Data(plain)
    }

    enum Algorithm: Equatable {
        case blowfishCFB, aesCBC(bits: Int), aes256GCM

        init(name: String?) throws {
            switch (name ?? "Blowfish CFB").lowercased() {
            case "blowfish cfb", "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0#blowfish": self = .blowfishCFB
            case "http://www.w3.org/2001/04/xmlenc#aes256-cbc": self = .aesCBC(bits: 256)
            case "http://www.w3.org/2001/04/xmlenc#aes192-cbc": self = .aesCBC(bits: 192)
            case "http://www.w3.org/2001/04/xmlenc#aes128-cbc": self = .aesCBC(bits: 128)
            case "http://www.w3.org/2009/xmlenc11#aes256-gcm": self = .aes256GCM
            default: throw UnlockError.algorithmUnsupported(name ?? "")
            }
        }

        var manifestName: String {
            switch self {
            case .blowfishCFB: return "Blowfish CFB"
            case .aesCBC(let bits): return "http://www.w3.org/2001/04/xmlenc#aes\(bits)-cbc"
            case .aes256GCM: return "http://www.w3.org/2009/xmlenc11#aes256-gcm"
            }
        }

        var defaultKeySize: Int {
            switch self {
            case .blowfishCFB: return 16
            case .aesCBC(let bits): return bits / 8
            case .aes256GCM: return 32
            }
        }

        var hasW3CPadding: Bool { if case .aesCBC = self { return true }; return false }

        func decrypt(_ data: Data, key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
            switch self {
            case .blowfishCFB:
                return try ODFEncryption.blowfishCFB8(Array(data), key: key, iv: iv, encrypt: false)
            case .aesCBC:
                guard data.count % 16 == 0, !data.isEmpty else { throw OfficeTextExtractor.ExtractError.wrongPassword }
                guard iv.count == 16 else { throw UnlockError.malformed("AES-CBC initialisation vector of \(iv.count) bytes") }
                return try CryptoPrimitives.aesCBC(Array(data), key: key, iv: iv, encrypt: false)
            case .aes256GCM:
                guard data.count >= 16, iv.count >= 12 else { throw UnlockError.malformed("AES-GCM entry too short") }
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: data.dropLast(16), tag: data.suffix(16))
                do { return Array(try AES.GCM.open(box, using: SymmetricKey(data: key))) }
                catch { throw OfficeTextExtractor.ExtractError.wrongPassword }
            }
        }

        func encrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
            switch self {
            case .blowfishCFB:
                return try ODFEncryption.blowfishCFB8(data, key: key, iv: iv, encrypt: true)
            case .aesCBC:
                let pad = 16 - data.count % 16
                return try CryptoPrimitives.aesCBC(data + [UInt8](repeating: UInt8(pad), count: pad), key: key, iv: iv, encrypt: true)
            case .aes256GCM:
                let box = try AES.GCM.seal(data, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: iv))
                return Array(box.ciphertext) + Array(box.tag)
            }
        }
    }

    // MARK: - Primitives (CommonCrypto, one unsafe call each)

    /// PBKDF2-HMAC-SHA1 with a byte-string password (the ODF start key).
    static func pbkdf2SHA1(password: [UInt8], salt: [UInt8], rounds: UInt32, length: Int) -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: length)
        _ = derived.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pw in
                salt.withUnsafeBytes { s in
                    unsafe CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                                s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds,
                                                out.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        return derived
    }

    /// Blowfish in 8-bit cipher feedback mode — OpenOffice.org's `rtl_Cipher`
    /// stream mode, byte by byte — through CommonCrypto (`kCCModeCFB8`).
    static func blowfishCFB8(_ input: [UInt8], key: [UInt8], iv: [UInt8], encrypt: Bool) throws -> [UInt8] {
        guard (4...56).contains(key.count) else { throw UnlockError.malformed("Blowfish key of \(key.count) bytes") }
        guard iv.count == 8 else { throw UnlockError.malformed("Blowfish initialisation vector of \(iv.count) bytes") }
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                unsafe CCCryptorCreateWithMode(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCMode(kCCModeCFB8), CCAlgorithm(kCCAlgorithmBlowfish),
                                               CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, key.count, nil, 0, 0, 0, &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else { throw UnlockError.malformed("Blowfish CFB could not start (\(created))") }
        defer { unsafe CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: input.count + 8)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                unsafe CCCryptorUpdate(cryptor, inp.baseAddress, input.count, out.baseAddress, out.count, &moved)
            }
        }
        guard status == kCCSuccess else { throw UnlockError.malformed("Blowfish CFB failed (\(status))") }
        return Array(output.prefix(moved))
    }

    // MARK: - Building a protected package (fixtures and round-trip tests)

    struct Parameters: Sendable, Equatable {
        var algorithm: Algorithm = .aesCBC(bits: 256)
        var startKeySHA256 = true
        var checksumSHA256 = true
        var iterations = 100_000
        /// LibreOffice: PBKDF2; one of the Argon2id names derives with Argon2id
        /// (`argon2`: passes, memory in KiB, lanes — LibreOffice writes 3, 65,536, 4);
        /// any other name is written as is, for a file this build must report by name.
        var keyDerivationName = "PBKDF2"
        var argon2: (t: Int, m: Int, p: Int) = (3, 65_536, 4)

        static func == (a: Parameters, b: Parameters) -> Bool {
            a.algorithm == b.algorithm && a.startKeySHA256 == b.startKeySHA256 && a.checksumSHA256 == b.checksumSHA256
                && a.iterations == b.iterations && a.keyDerivationName == b.keyDerivationName && a.argon2 == b.argon2
        }

        /// LibreOffice 6/7 default (ODF 1.2): AES-256-CBC, SHA-256 start key, SHA256/1K, 100,000 rounds.
        static let libreOffice = Parameters()
        /// OpenOffice.org 2/3 (ODF 1.0/1.1): Blowfish CFB, SHA-1 start key, SHA1/1K, 1,024 rounds.
        static let openOfficeLegacy = Parameters(algorithm: .blowfishCFB, startKeySHA256: false, checksumSHA256: false, iterations: 1024)
    }

    /// A protected OpenDocument ZIP: `mimetype` first and stored in the clear,
    /// every other member deflated, encrypted and stored, the manifest
    /// describing each one. `members` are the plain parts (content.xml, …).
    static func encrypt(members: [(name: String, data: Data)], mimetype: String, password: String,
                        parameters: Parameters = .libreOffice) throws -> Data {
        var entries: [MiniZIPWriter.Entry] = [.init(name: "mimetype", data: Data(mimetype.utf8), deflate: false)]
        var manifest = """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2" xmlns:loext="urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0">
         <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="\(mimetype)"/>

        """
        let startKey: [UInt8] = parameters.startKeySHA256 ? Array(SHA256.hash(data: Data(password.utf8))) : Array(Insecure.SHA1.hash(data: Data(password.utf8)))
        let keySize = parameters.algorithm.defaultKeySize
        for member in members {
            let deflated = try RawDeflate.deflate(member.data)
            let salt = CryptoPrimitives.randomBytes(16)
            let iv = CryptoPrimitives.randomBytes(parameters.algorithm == .aes256GCM ? 12 : (parameters.algorithm == .blowfishCFB ? 8 : 16))
            let usesArgon2id = [argon2idName, argon2idNameLibreOffice].contains(parameters.keyDerivationName)
            let key = usesArgon2id
                ? try Argon2.hash(password: startKey, salt: salt, iterations: UInt32(parameters.argon2.t), memoryKiB: UInt32(parameters.argon2.m),
                                  lanes: UInt32(parameters.argon2.p), tagLength: keySize, variant: .id)
                : pbkdf2SHA1(password: startKey, salt: salt, rounds: UInt32(parameters.iterations), length: keySize)
            let cipherText = try parameters.algorithm.encrypt(Array(deflated), key: key, iv: iv)
            let covered = deflated.prefix(1024)
            let checksum = parameters.checksumSHA256 ? Data(SHA256.hash(data: covered)) : Data(Insecure.SHA1.hash(data: covered))
            entries.append(.init(name: member.name, data: Data(cipherText), deflate: false))
            let checksumType = parameters.checksumSHA256 ? "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0#sha256-1k" : "SHA1/1K"
            let startKeyName = parameters.startKeySHA256 ? "http://www.w3.org/2000/09/xmldsig#sha256" : "http://www.w3.org/2000/09/xmldsig#sha1"
            let keyDerivation = parameters.keyDerivationName == "PBKDF2"
                ? "<manifest:key-derivation manifest:key-derivation-name=\"PBKDF2\" manifest:key-size=\"\(keySize)\" manifest:iteration-count=\"\(parameters.iterations)\" manifest:salt=\"\(salt.base64)\"/>"
                : "<manifest:key-derivation manifest:key-derivation-name=\"\(parameters.keyDerivationName)\" manifest:key-size=\"\(keySize)\" manifest:salt=\"\(salt.base64)\" loext:argon2-iterations=\"\(parameters.argon2.t)\" loext:argon2-memory=\"\(parameters.argon2.m)\" loext:argon2-lanes=\"\(parameters.argon2.p)\"/>"
            manifest += """
             <manifest:file-entry manifest:full-path="\(member.name)" manifest:media-type="text/xml" manifest:size="\(member.data.count)">
              <manifest:encryption-data manifest:checksum-type="\(checksumType)" manifest:checksum="\(checksum.base64EncodedString())">
               <manifest:algorithm manifest:algorithm-name="\(parameters.algorithm.manifestName)" manifest:initialisation-vector="\(iv.base64)"/>
               \(keyDerivation)
               <manifest:start-key-generation manifest:start-key-generation-name="\(startKeyName)" manifest:key-size="\(startKey.count)"/>
              </manifest:encryption-data>
             </manifest:file-entry>

            """
        }
        manifest += "</manifest:manifest>\n"
        entries.append(.init(name: "META-INF/manifest.xml", data: Data(manifest.utf8), deflate: true))
        return try MiniZIPWriter.archive(entries)
    }
}

private extension Array where Element == UInt8 {
    var base64: String { Data(self).base64EncodedString() }
}

/// `META-INF/manifest.xml`: the file entries that carry encryption data.
final class ManifestCollector: NSObject, XMLParserDelegate {
    private(set) var entries: [String: ODFEncryption.EntryEncryption] = [:]
    private var current: ODFEncryption.EntryEncryption?
    private var encrypted = false
    private var failed = false

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        return parser.parse() && !failed
    }

    private func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        func attr(_ key: String) -> String? { attributes.first { local($0.key) == key }?.value }
        func int(_ key: String) -> Int? { attr(key).flatMap { Int($0) } }
        func b64(_ key: String) -> Data? { attr(key).flatMap { Data(base64Encoded: $0) } }
        switch local(elementName) {
        case "file-entry":
            current = ODFEncryption.EntryEncryption(fullPath: attr("full-path") ?? "", plainSize: int("size"))
            encrypted = false
        case "encryption-data":
            encrypted = true
            current?.checksumType = attr("checksum-type")
            current?.checksum = b64("checksum")
        case "algorithm":
            current?.algorithmName = attr("algorithm-name")
            current?.iv = b64("initialisation-vector")
        case "key-derivation":
            current?.keyDerivationName = attr("key-derivation-name")
            current?.keySize = int("key-size")
            current?.iterationCount = int("iteration-count")
            current?.salt = b64("salt")
            current?.argon2Iterations = int("argon2-iterations")
            current?.argon2Memory = int("argon2-memory")
            current?.argon2Lanes = int("argon2-lanes")
        case "start-key-generation":
            current?.startKeyGenerationName = attr("start-key-generation-name")
            current?.startKeySize = int("key-size")
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if local(elementName) == "file-entry", let entry = current {
            if encrypted { entries[entry.fullPath] = entry }
            current = nil
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { failed = true }
}

// MARK: - Raw DEFLATE in memory

/// RFC 1951 streams held in memory (an ODF entry after decryption is small
/// by the part guard). §3-P2: the Compression framework is a C API; the two
/// buffer calls are the only pointer code here. SAFETY: destination buffers
/// are sized before the call and the call writes at most that many bytes.
enum RawDeflate {
    enum Failure: Error, Equatable { case corrupt, overLimit(Int) }

    static func inflate(_ data: Data, limit: Int) throws -> Data {
        guard !data.isEmpty else { return Data() }
        // Grow the destination until the stream fits; the last attempt is one
        // byte over the limit, so "exactly the limit" and "over it" are told apart.
        var capacity = max(1024, min(limit + 1, data.count * 4))
        while true {
            var out = [UInt8](repeating: 0, count: capacity)
            let produced = out.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    unsafe compression_decode_buffer(dst.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                                                     src.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard produced > 0 else { throw Failure.corrupt }
            if produced < capacity {
                guard produced <= limit else { throw Failure.overLimit(limit) }
                return Data(out.prefix(produced))
            }
            guard capacity <= limit else { throw Failure.overLimit(limit) }
            capacity = min(limit + 1, capacity * 4)
        }
    }

    static func deflate(_ data: Data) throws -> Data {
        let capacity = data.count + data.count / 8 + 64
        var out = [UInt8](repeating: 0, count: capacity)
        let produced = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                unsafe compression_encode_buffer(dst.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                                                 src.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard produced > 0 else { throw Failure.corrupt }
        return Data(out.prefix(produced))
    }
}

// MARK: - A small ZIP writer (stored / deflated members, no ZIP64)

/// Enough of PKWARE APPNOTE 4.3 to build fixtures: local headers, data,
/// central directory, end record. Members over 4 GiB are out of scope.
enum MiniZIPWriter {
    struct Entry {
        var name: String
        var data: Data
        var deflate: Bool
        /// Pre-compressed bytes to store under method 8 with the given plain size (optional).
        var precompressed: (data: Data, plainSize: Int, crc32: UInt32)?
        /// A non-standard method number, for files that only a specific program reads.
        var methodOverride: UInt16?
        init(name: String, data: Data, deflate: Bool, precompressed: (data: Data, plainSize: Int, crc32: UInt32)? = nil, methodOverride: UInt16? = nil) {
            self.name = name; self.data = data; self.deflate = deflate; self.precompressed = precompressed; self.methodOverride = methodOverride
        }
    }

    static func archive(_ entries: [Entry]) throws -> Data {
        var out = Data()
        var central = Data()
        func le16(_ d: inout Data, _ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
        func le32(_ d: inout Data, _ v: UInt32) { for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let plain: Data, stored: Data, method: UInt16, crc: UInt32
            if let pre = entry.precompressed {
                stored = pre.data; plain = Data(count: pre.plainSize); method = entry.methodOverride ?? 8; crc = pre.crc32
            } else if entry.deflate {
                plain = entry.data; stored = try RawDeflate.deflate(entry.data); method = entry.methodOverride ?? 8; crc = ZIPArchiveReader.CRC32.checksum(entry.data)
            } else {
                plain = entry.data; stored = entry.data; method = entry.methodOverride ?? 0; crc = ZIPArchiveReader.CRC32.checksum(entry.data)
            }
            let offset = UInt32(out.count)
            var local = Data([0x50, 0x4B, 0x03, 0x04])
            le16(&local, 20); le16(&local, 0x0800); le16(&local, method); le16(&local, 0); le16(&local, 0x21)
            le32(&local, crc); le32(&local, UInt32(stored.count)); le32(&local, UInt32(plain.count))
            le16(&local, UInt16(nameBytes.count)); le16(&local, 0)
            out.append(local); out.append(nameBytes); out.append(stored)
            var c = Data([0x50, 0x4B, 0x01, 0x02])
            le16(&c, 0x031E); le16(&c, 20); le16(&c, 0x0800); le16(&c, method); le16(&c, 0); le16(&c, 0x21)
            le32(&c, crc); le32(&c, UInt32(stored.count)); le32(&c, UInt32(plain.count))
            le16(&c, UInt16(nameBytes.count)); le16(&c, 0); le16(&c, 0); le16(&c, 0); le16(&c, 0)
            le32(&c, 0); le32(&c, offset)
            c.append(nameBytes)
            central.append(c)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        var eocd = Data([0x50, 0x4B, 0x05, 0x06])
        le16(&eocd, 0); le16(&eocd, 0); le16(&eocd, UInt16(entries.count)); le16(&eocd, UInt16(entries.count))
        le32(&eocd, UInt32(central.count)); le32(&eocd, cdOffset); le16(&eocd, 0)
        out.append(eocd)
        return out
    }
}
