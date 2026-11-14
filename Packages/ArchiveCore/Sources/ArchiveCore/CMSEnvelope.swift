//
//  CMSEnvelope.swift
//  ArchiveCore
//
//  R6 (S/MIME on iPhone and iPad): a portable reader for CMS EnvelopedData
//  (RFC 5652 §6) and AuthEnvelopedData (RFC 5083), the containers of
//  S/MIME-encrypted mail. Apple's CMSDecoder exists only on macOS; this
//  reader runs on every platform the package supports.
//
//  The private key never enters this code. Each recipient the message names
//  is handed to a caller-supplied operation together with what must be done
//  with the key — RSA PKCS#1 v1.5 or RSA-OAEP decryption of the wrapped
//  content key, or an ECDH key agreement with the sender's ephemeral key —
//  and the app performs it with `SecKeyCreateDecryptedData` /
//  `SecKeyCopyKeyExchangeResult` on a keychain identity, so the key stays in
//  the keychain (or Secure Enclave) and is never exported.
//
//  Read:  KeyTransRecipientInfo (RSA PKCS#1 v1.5, RSA-OAEP with SHA-1/256/
//         384/512 and MGF1 of the same hash), KeyAgreeRecipientInfo (ECDH
//         P-256/P-384/P-521, standard and cofactor single-pass schemes, X9.63
//         KDF with SHA-1/256/384/512, AES key wrap); content encrypted with
//         AES-128/192/256-CBC, AES-128/192/256-GCM (authenticated) or
//         3DES-CBC. BER indefinite lengths and segmented OCTET STRINGs read.
//  Named, not read: KEK and password recipients, RC2 and single DES, GCM
//         tags shorter than 16 bytes, SHA-224 KDFs.
//

import Foundation
import CryptoKit
import CommonCrypto

/// Why a CMS part was not opened. The cases are what the app turns into the
/// reason a locked attachment states.
public enum CMSError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The bytes are not a well-formed CMS structure.
    case malformed(String)
    /// CMS, but not the kind asked for (e.g. signed data handed to the decryptor).
    case unexpectedContentType(String)
    /// An algorithm or structure this reader does not implement, named.
    case unsupported(String)
    /// None of the recipients the message names has a key here.
    case noMatchingKey(recipients: [CMSRecipientIdentifier])
    /// A key was found, but the key operation or the content decryption failed
    /// (the wrong key, or a damaged part), with what failed.
    case decryptionFailed(String)
    /// Authenticated content whose tag did not match: altered or the wrong key.
    case authenticationFailed

    public var description: String {
        switch self {
        case .malformed(let why): return "not a well-formed CMS part: \(why)"
        case .unexpectedContentType(let oid): return "CMS content type \(oid) is not the one expected"
        case .unsupported(let what): return "not supported: \(what)"
        case .noMatchingKey(let recipients):
            return "no private key for the \(recipients.count) recipient(s): " + recipients.map(\.description).joined(separator: "; ")
        case .decryptionFailed(let why): return "decryption failed: \(why)"
        case .authenticationFailed: return "the authentication tag did not match (altered, or the wrong key)"
        }
    }
}

/// How a recipient's certificate is named in a CMS message.
public enum CMSRecipientIdentifier: Hashable, Sendable, CustomStringConvertible {
    /// The certificate's issuer Name (DER, exactly as in the certificate) and serial number (big-endian magnitude).
    case issuerAndSerial(issuer: [UInt8], serial: [UInt8])
    /// The certificate's subject key identifier extension value.
    case subjectKeyIdentifier([UInt8])

    public var description: String {
        switch self {
        case .issuerAndSerial(let issuer, let serial):
            let cn = X509Name.commonName(der: issuer).map { "issuer \($0)" } ?? "issuer (unnamed)"
            return "\(cn), serial \(serial.map { String(format: "%02X", $0) }.joined())"
        case .subjectKeyIdentifier(let ski):
            return "subject key \(ski.map { String(format: "%02X", $0) }.joined())"
        }
    }

    /// Serial numbers compare as magnitudes (a leading zero octet is sign padding).
    static func normalizedSerial(_ s: some Collection<UInt8>) -> [UInt8] {
        let m = Array(s.drop { $0 == 0 })
        return m.isEmpty ? [0] : m
    }

    /// True when this identifier names the certificate.
    public func matches(_ certificate: X509Certificate) -> Bool {
        switch self {
        case .issuerAndSerial(let issuer, let serial):
            return issuer == certificate.issuerDER && Self.normalizedSerial(serial) == Self.normalizedSerial(certificate.serial)
        case .subjectKeyIdentifier(let ski):
            return certificate.subjectKeyIdentifier == ski
        }
    }
}

/// Elliptic curves an ECDH recipient may use.
public enum CMSCurve: String, Sendable, CaseIterable {
    case p256, p384, p521

    init?(oid: String) {
        switch oid {
        case CMSOID.p256: self = .p256
        case CMSOID.p384: self = .p384
        case CMSOID.p521: self = .p521
        default: return nil
        }
    }
    var oid: String {
        switch self {
        case .p256: return CMSOID.p256
        case .p384: return CMSOID.p384
        case .p521: return CMSOID.p521
        }
    }
    /// Key size in bits (what `kSecAttrKeySizeInBits` says).
    public var bits: Int { switch self { case .p256: 256; case .p384: 384; case .p521: 521 } }
}

/// What the holder of a recipient's private key is asked to do.
public enum CMSKeyRequest: Sendable, Equatable {
    /// Decrypt `encryptedKey` with RSA PKCS#1 v1.5 (`.rsaEncryptionPKCS1`); return the content key.
    case rsaPKCS1v15(encryptedKey: Data)
    /// Decrypt with RSA-OAEP, MGF1 with the same hash, empty label (`.rsaEncryptionOAEPSHA*`); return the content key.
    case rsaOAEP(hash: CMSHash, encryptedKey: Data)
    /// ECDH with the sender's ephemeral public key (X9.63 uncompressed point);
    /// return the raw shared secret Z (`.ecdhKeyExchangeStandard`). The KDF
    /// and key unwrap are done by the reader.
    case ecdh(curve: CMSCurve, ephemeralPublicKey: Data)
}

/// The private-key holder: returns the result for a recipient it has a key
/// for, nil when it has none, and throws when it has the key but the
/// operation failed.
public typealias CMSPrivateKeyOperation = (CMSRecipientIdentifier, CMSKeyRequest) throws -> Data?

/// A decrypted envelope.
public struct CMSDecryptedContent: Sendable {
    /// The plaintext (for S/MIME, a MIME entity).
    public let content: Data
    /// The inner content type (normally id-data).
    public let contentType: String
    /// The recipient whose key opened it.
    public let recipient: CMSRecipientIdentifier
    /// The content encryption algorithm, e.g. "AES-256-GCM".
    public let contentAlgorithm: String
    /// True for AuthEnvelopedData (integrity checked by the tag).
    public let authenticated: Bool
}

/// What the envelope contains, read without any key.
public struct CMSEnvelopeSummary: Sendable {
    public let recipients: [CMSRecipientIdentifier]
    public let contentAlgorithm: String
    public let authenticated: Bool
}

public enum CMSEnvelope {

    /// The outer content type of a CMS part (ContentInfo.contentType), or nil
    /// when the bytes are not CMS.
    public static func contentType(of data: Data) -> String? {
        guard let info = try? ASN1Node.parse([UInt8](data)), info.tag == 0x30,
              let first = try? info.children().first else { return nil }
        return try? first.oid()
    }

    /// Recipients and algorithm, without decrypting.
    public static func summary(_ data: Data) throws -> CMSEnvelopeSummary {
        let env = try Parsed(data)
        return CMSEnvelopeSummary(recipients: env.recipients.map(\.identifier),
                                  contentAlgorithm: (try? ContentCipher(env.contentAlgorithm).name) ?? CMSOID.name(env.contentAlgorithm.oid),
                                  authenticated: env.mac != nil)
    }

    /// Decrypts an EnvelopedData or AuthEnvelopedData part. Each recipient is
    /// offered to `keyOperation` in the order the message lists them; the
    /// first whose key opens the content wins.
    public static func decrypt(_ data: Data, keyOperation: CMSPrivateKeyOperation) throws -> CMSDecryptedContent {
        let env = try Parsed(data)
        let cipher = try ContentCipher(env.contentAlgorithm)
        var lastFailure: CMSError?
        var unsupported: [String] = []
        for recipient in env.recipients {
            let cek: [UInt8]
            do {
                guard let key = try recipient.contentKey(keyOperation) else { continue }
                cek = key
            } catch let e as CMSError {
                if case .unsupported(let what) = e { unsupported.append(what) } else { lastFailure = e }
                continue
            } catch {
                lastFailure = .decryptionFailed(error.localizedDescription)
                continue
            }
            guard cek.count == cipher.keyLength else {
                lastFailure = .decryptionFailed("the content key is \(cek.count) bytes, \(cipher.name) needs \(cipher.keyLength)")
                continue
            }
            do {
                let plain = try cipher.decrypt(env.encryptedContent, key: cek, mac: env.mac, aad: env.authAttributes ?? [])
                return CMSDecryptedContent(content: Data(plain), contentType: env.innerContentType, recipient: recipient.identifier,
                                           contentAlgorithm: cipher.name, authenticated: env.mac != nil)
            } catch let e as CMSError {
                lastFailure = e
            }
        }
        if let lastFailure { throw lastFailure }
        if env.recipients.isEmpty, let first = unsupported.first { throw CMSError.unsupported(first) }
        throw CMSError.noMatchingKey(recipients: env.recipients.map(\.identifier))
    }

    // MARK: - Structure

    struct Parsed {
        let recipients: [Recipient]
        let innerContentType: String
        let contentAlgorithm: ASN1Algorithm
        let encryptedContent: [UInt8]
        let mac: [UInt8]?
        let authAttributes: [UInt8]?

        init(_ data: Data) throws {
            let info = try ASN1Node.parse([UInt8](data))
            let top = try info.children()
            guard info.tag == 0x30, top.count >= 2 else { throw CMSError.malformed("ContentInfo expected") }
            let type = try top[0].oid()
            guard type == CMSOID.envelopedData || type == CMSOID.authEnvelopedData else { throw CMSError.unexpectedContentType(type) }
            let authenticated = type == CMSOID.authEnvelopedData
            guard top[1].contextNumber == 0, let body = try top[1].children().first, body.tag == 0x30 else {
                throw CMSError.malformed("[0] content expected")
            }
            var fields = try body.children()[...]
            guard let version = fields.popFirst(), version.tag == 0x02 else { throw CMSError.malformed("version expected") }
            if fields.first?.contextNumber == 0 { fields.removeFirst() }   // originatorInfo
            guard let infos = fields.popFirst(), infos.tag == 0x31 else { throw CMSError.malformed("recipientInfos expected") }
            var recipients: [Recipient] = []
            var skipped: [String] = []
            for info in try infos.children() {
                do { recipients += try Recipient.parse(info) } catch CMSError.unsupported(let what) { skipped.append(what) }
            }
            guard let eci = fields.popFirst(), eci.tag == 0x30 else { throw CMSError.malformed("encryptedContentInfo expected") }
            let eciParts = try eci.children()
            guard eciParts.count >= 2 else { throw CMSError.malformed("encryptedContentInfo is short") }
            innerContentType = try eciParts[0].oid()
            contentAlgorithm = try ASN1Algorithm(eciParts[1])
            guard eciParts.count >= 3, eciParts[2].contextNumber == 0 else {
                throw CMSError.unsupported("encrypted content carried outside the message (detached)")
            }
            encryptedContent = try eciParts[2].octets()
            if authenticated {
                var attrs: [UInt8]?
                if fields.first?.contextNumber == 1, let a = fields.popFirst() { attrs = a.asUniversalSet() }
                guard let macNode = fields.popFirst(), macNode.tag == 0x04 || macNode.tag == 0x24 else { throw CMSError.malformed("mac expected") }
                mac = try macNode.octets()
                authAttributes = attrs
            } else {
                mac = nil
                authAttributes = nil
            }
            if recipients.isEmpty, let first = skipped.first { throw CMSError.unsupported(first) }
            self.recipients = recipients
        }
    }

    /// One recipient: an identifier and how its key yields the content key.
    struct Recipient {
        enum Method {
            case rsa(oaep: CMSHash?, encryptedKey: [UInt8])
            case ecdh(curve: CMSCurve, ephemeral: [UInt8], kdf: CMSHash, wrap: ASN1Algorithm, ukm: [UInt8]?, encryptedKey: [UInt8])
        }
        let identifier: CMSRecipientIdentifier
        let method: Method

        static func identifier(_ node: ASN1Node) throws -> CMSRecipientIdentifier {
            if node.tag == 0x30 {
                let parts = try node.children()
                guard parts.count == 2, parts[1].tag == 0x02 else { throw CMSError.malformed("issuerAndSerialNumber expected") }
                return .issuerAndSerial(issuer: Array(parts[0].raw), serial: CMSRecipientIdentifier.normalizedSerial(parts[1].content))
            }
            if node.tag == 0x80 || node.tag == 0xA0 { return .subjectKeyIdentifier(try node.octets()) }   // [0] SubjectKeyIdentifier
            throw CMSError.malformed("recipient identifier expected")
        }

        static func parse(_ info: ASN1Node) throws -> [Recipient] {
            switch info.tag {
            case 0x30: return [try keyTransport(info)]
            case 0xA1: return try keyAgreement(info)
            case 0xA2: throw CMSError.unsupported("a KEK (pre-shared key) recipient")
            case 0xA3: throw CMSError.unsupported("a password recipient")
            default: throw CMSError.unsupported("recipient type [\(info.tag & 0x1F)]")
            }
        }

        static func keyTransport(_ info: ASN1Node) throws -> Recipient {
            let parts = try info.children()
            guard parts.count == 4 else { throw CMSError.malformed("KeyTransRecipientInfo has \(parts.count) fields") }
            let id = try identifier(parts[1])
            let alg = try ASN1Algorithm(parts[2])
            let encryptedKey = try parts[3].octets()
            switch alg.oid {
            case CMSOID.rsaEncryption:
                return Recipient(identifier: id, method: .rsa(oaep: nil, encryptedKey: encryptedKey))
            case CMSOID.rsaOAEP:
                return Recipient(identifier: id, method: .rsa(oaep: try oaepHash(alg.parameters), encryptedKey: encryptedKey))
            default:
                throw CMSError.unsupported("key transport \(CMSOID.name(alg.oid))")
            }
        }

        /// RSAES-OAEP-params: hash [0] (default SHA-1), MGF [1] (default MGF1-SHA-1), pSource [2] (default empty label).
        static func oaepHash(_ params: ASN1Node?) throws -> CMSHash {
            var hash = CMSHash.sha1, mgfHash = CMSHash.sha1
            if let params, params.tag == 0x30 {
                for field in try params.children() {
                    guard let inner = try field.children().first else { continue }
                    switch field.contextNumber {
                    case 0:
                        let a = try ASN1Algorithm(inner)
                        guard let h = CMSHash(oid: a.oid) else { throw CMSError.unsupported("RSA-OAEP with hash \(a.oid)") }
                        hash = h
                    case 1:
                        let a = try ASN1Algorithm(inner)
                        guard a.oid == CMSOID.mgf1, let p = a.parameters, let h = CMSHash(oid: try ASN1Algorithm(p).oid) else {
                            throw CMSError.unsupported("RSA-OAEP mask generation \(a.oid)")
                        }
                        mgfHash = h
                    case 2:
                        throw CMSError.unsupported("RSA-OAEP with a label")
                    default: continue
                    }
                }
            }
            guard hash == mgfHash else { throw CMSError.unsupported("RSA-OAEP with different hash and MGF1 hash") }
            return hash
        }

        static func keyAgreement(_ info: ASN1Node) throws -> [Recipient] {
            var fields = try info.children()[...]
            guard fields.popFirst()?.tag == 0x02 else { throw CMSError.malformed("KeyAgreeRecipientInfo version expected") }
            guard let originator = fields.popFirst(), originator.contextNumber == 0,
                  let choice = try originator.children().first else { throw CMSError.malformed("originator expected") }
            guard choice.tag == 0xA1 else { throw CMSError.unsupported("ECDH with a static originator key") }
            let originatorKey = try choice.children()
            guard originatorKey.count == 2 else { throw CMSError.malformed("originatorKey expected") }
            let keyAlg = try ASN1Algorithm(originatorKey[0])
            guard keyAlg.oid == CMSOID.ecPublicKey else { throw CMSError.unsupported("key agreement with \(CMSOID.name(keyAlg.oid)) keys") }
            let bits = try originatorKey[1].octets()
            guard bits.count > 1, bits[0] == 0 else { throw CMSError.malformed("originator public key") }
            let point = Array(bits.dropFirst())
            var ukm: [UInt8]?
            if fields.first?.contextNumber == 1, let u = fields.popFirst(), let o = try u.children().first { ukm = try o.octets() }
            guard let algNode = fields.popFirst() else { throw CMSError.malformed("keyEncryptionAlgorithm expected") }
            let alg = try ASN1Algorithm(algNode)
            guard let kdf = CMSOID.ecdhSchemes[alg.oid] else { throw CMSError.unsupported("key agreement \(CMSOID.name(alg.oid))") }
            guard let wrapNode = alg.parameters else { throw CMSError.malformed("key wrap algorithm missing") }
            let wrap = try ASN1Algorithm(wrapNode)
            guard [CMSOID.aes128Wrap, CMSOID.aes192Wrap, CMSOID.aes256Wrap].contains(wrap.oid) else {
                throw CMSError.unsupported(CMSOID.name(wrap.oid))
            }
            // The curve: RFC 5753 leaves the originator key's parameters absent
            // (the recipient's curve is meant); an uncompressed point's length
            // names it. A namedCurve, when present, must agree.
            let byLength: CMSCurve? = point.first == 0x04 ? [65: .p256, 97: .p384, 133: .p521][point.count] : nil
            let named = try keyAlg.parameters.map { try $0.oid() }
            guard let curve = byLength, named.map({ CMSCurve(oid: $0) == curve }) ?? true else {
                throw CMSError.unsupported("ECDH on a curve other than P-256, P-384 and P-521, or with a compressed key")
            }
            guard let keys = fields.popFirst(), keys.tag == 0x30 else { throw CMSError.malformed("recipientEncryptedKeys expected") }
            return try keys.children().map { rek in
                let parts = try rek.children()
                guard parts.count == 2 else { throw CMSError.malformed("RecipientEncryptedKey") }
                let id: CMSRecipientIdentifier
                if parts[0].tag == 0xA0 {   // rKeyId [0] IMPLICIT RecipientKeyIdentifier
                    guard let ski = try parts[0].children().first else { throw CMSError.malformed("rKeyId") }
                    id = .subjectKeyIdentifier(try ski.octets())
                } else {
                    id = try identifier(parts[0])
                }
                return Recipient(identifier: id, method: .ecdh(curve: curve, ephemeral: point, kdf: kdf, wrap: wrap, ukm: ukm,
                                                               encryptedKey: try parts[1].octets()))
            }
        }

        /// The content-encryption key, or nil when the key holder has no key for this recipient.
        func contentKey(_ operation: CMSPrivateKeyOperation) throws -> [UInt8]? {
            switch method {
            case .rsa(let oaep, let encryptedKey):
                let request: CMSKeyRequest = oaep.map { .rsaOAEP(hash: $0, encryptedKey: Data(encryptedKey)) } ?? .rsaPKCS1v15(encryptedKey: Data(encryptedKey))
                return try operation(identifier, request).map { [UInt8]($0) }
            case .ecdh(let curve, let ephemeral, let kdf, let wrap, let ukm, let encryptedKey):
                guard let z = try operation(identifier, .ecdh(curve: curve, ephemeralPublicKey: Data(ephemeral))) else { return nil }
                let kekLength = wrap.oid == CMSOID.aes128Wrap ? 16 : wrap.oid == CMSOID.aes192Wrap ? 24 : 32
                let kek = CMSKDF.x963(hash: kdf, z: [UInt8](z), sharedInfo: CMSKDF.eccSharedInfo(wrap: wrap.raw, ukm: ukm, keyBytes: kekLength), length: kekLength)
                do {
                    let unwrapped = try AES.KeyWrap.unwrap(encryptedKey, using: SymmetricKey(data: kek))
                    return unwrapped.withUnsafeBytes { [UInt8]($0) }
                } catch {
                    throw CMSError.decryptionFailed("the AES key wrap did not open (the wrong key)")
                }
            }
        }
    }
}

// MARK: - Key derivation

enum CMSKDF {
    /// ECC-CMS-SharedInfo (RFC 5753 §7.2).
    static func eccSharedInfo(wrap: [UInt8], ukm: [UInt8]?, keyBytes: Int) -> [UInt8] {
        let bits = keyBytes * 8
        let suppPub: [UInt8] = [UInt8((bits >> 24) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)]
        var items = [wrap]
        if let ukm { items.append(ASN1.explicit(0, ASN1.octetString(ukm))) }
        items.append(ASN1.explicit(2, ASN1.octetString(suppPub)))
        return ASN1.sequence(items)
    }

    /// ANSI X9.63 KDF: Hash(Z ‖ counter ‖ SharedInfo), counter from 1.
    static func x963(hash: CMSHash, z: [UInt8], sharedInfo: [UInt8], length: Int) -> [UInt8] {
        var out: [UInt8] = []
        var counter: UInt32 = 1
        while out.count < length {
            let block = z + [UInt8(counter >> 24), UInt8((counter >> 16) & 0xFF), UInt8((counter >> 8) & 0xFF), UInt8(counter & 0xFF)] + sharedInfo
            out += CMSDigest.hash(hash, block)
            counter += 1
        }
        return Array(out.prefix(length))
    }
}

enum CMSDigest {
    static func hash(_ h: CMSHash, _ data: some DataProtocol) -> [UInt8] {
        switch h {
        case .sha1: return Array(Insecure.SHA1.hash(data: data))
        case .sha256: return Array(SHA256.hash(data: data))
        case .sha384: return Array(SHA384.hash(data: data))
        case .sha512: return Array(SHA512.hash(data: data))
        }
    }
}

// MARK: - Content ciphers

struct ContentCipher {
    enum Kind { case aesCBC, aesGCM, des3CBC }
    let kind: Kind
    let keyLength: Int
    let iv: [UInt8]
    let tagLength: Int
    let name: String

    init(_ alg: ASN1Algorithm) throws {
        switch alg.oid {
        case CMSOID.aes128CBC, CMSOID.aes192CBC, CMSOID.aes256CBC:
            kind = .aesCBC
            keyLength = alg.oid == CMSOID.aes128CBC ? 16 : alg.oid == CMSOID.aes192CBC ? 24 : 32
            guard let p = alg.parameters, p.tag == 0x04, p.content.count == 16 else { throw CMSError.malformed("AES-CBC IV") }
            iv = Array(p.content); tagLength = 0
            name = "AES-\(keyLength * 8)-CBC"
        case CMSOID.aes128GCM, CMSOID.aes192GCM, CMSOID.aes256GCM:
            kind = .aesGCM
            keyLength = alg.oid == CMSOID.aes128GCM ? 16 : alg.oid == CMSOID.aes192GCM ? 24 : 32
            guard let p = alg.parameters, p.tag == 0x30 else { throw CMSError.malformed("GCM parameters") }
            let parts = try p.children()
            guard let nonce = parts.first, nonce.tag == 0x04, !nonce.content.isEmpty else { throw CMSError.malformed("GCM nonce") }
            iv = Array(nonce.content)
            tagLength = parts.count > 1 ? try parts[1].int() : 12
            name = "AES-\(keyLength * 8)-GCM"
        case CMSOID.desEDE3CBC:
            kind = .des3CBC
            keyLength = 24
            guard let p = alg.parameters, p.tag == 0x04, p.content.count == 8 else { throw CMSError.malformed("3DES IV") }
            iv = Array(p.content); tagLength = 0
            name = "3DES-CBC"
        default:
            throw CMSError.unsupported("content encrypted with \(CMSOID.name(alg.oid))")
        }
    }

    func decrypt(_ cipherText: [UInt8], key: [UInt8], mac: [UInt8]?, aad: [UInt8]) throws -> [UInt8] {
        switch kind {
        case .aesCBC, .des3CBC:
            return try CMSSymmetric.cbc(cipherText, key: key, iv: iv, des3: kind == .des3CBC, encrypt: false)
        case .aesGCM:
            guard let mac else { throw CMSError.malformed("GCM content outside AuthEnvelopedData has no tag") }
            guard tagLength == 16, mac.count == 16 else { throw CMSError.unsupported("GCM tags of \(mac.count) bytes") }
            do {
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: cipherText, tag: mac)
                return Array(try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad))
            } catch {
                throw CMSError.authenticationFailed
            }
        }
    }
}

enum CMSSymmetric {
    /// AES-CBC or 3DES-CBC with PKCS#7 padding.
    static func cbc(_ input: [UInt8], key: [UInt8], iv: [UInt8], des3: Bool, encrypt: Bool) throws -> [UInt8] {
        let block = des3 ? kCCBlockSize3DES : kCCBlockSizeAES128
        if !encrypt, input.isEmpty || input.count % block != 0 {
            throw CMSError.decryptionFailed("the cipher text is not a whole number of blocks")
        }
        var output = [UInt8](repeating: 0, count: input.count + block)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        unsafe CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                                       CCAlgorithm(des3 ? kCCAlgorithm3DES : kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                       k.baseAddress, key.count, v.baseAddress,
                                       inp.baseAddress, input.count, out.baseAddress, out.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw CMSError.decryptionFailed(status == kCCDecodeError ? "the padding did not check out (the wrong key)" : "the cipher reported \(status)")
        }
        return Array(output.prefix(moved))
    }
}
