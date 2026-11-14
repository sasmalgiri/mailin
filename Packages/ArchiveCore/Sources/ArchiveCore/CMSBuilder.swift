//
//  CMSBuilder.swift
//  ArchiveCore
//
//  R6: the writing half of the portable CMS code — self-signed certificates,
//  EnvelopedData / AuthEnvelopedData and SignedData — so the reader is
//  verified by round trip and against OpenSSL without fixtures that hold a
//  private key. Not used by the import path; nothing here touches a keychain.
//  Signing is delegated, like decryption, so a caller can sign with a key it
//  cannot export.
//

import Foundation
import CryptoKit
import Security

public enum CMSBuilder {

    public enum Cipher: Sendable {
        case aesCBC(bits: Int)
        case aesGCM(bits: Int)
        case des3CBC
    }

    public enum Recipient {
        /// RSA key transport; `oaep` nil means PKCS#1 v1.5.
        case rsa(CMSRecipientIdentifier, publicKey: SecKey, oaep: CMSHash?)
        /// ECDH (single-pass, ephemeral-static) with the recipient's public key
        /// as an X9.63 uncompressed point; `kdf` picks the scheme.
        case ecdh(CMSRecipientIdentifier, publicKey: Data, kdf: CMSHash)
    }

    public enum BuildError: Error, Equatable { case key(String), unsupported(String) }

    // MARK: Keys and certificates

    /// SubjectPublicKeyInfo for a Security-framework public key (RSA or EC P-256/384/521).
    public static func subjectPublicKeyInfo(_ key: SecKey) throws -> [UInt8] {
        guard let attrs = SecKeyCopyAttributes(key) as? [CFString: Any],
              let type = attrs[kSecAttrKeyType] as? String,
              let external = SecKeyCopyExternalRepresentation(key, nil) as Data? else { throw BuildError.key("public key not readable") }
        if type == (kSecAttrKeyTypeRSA as String) {
            return ASN1.sequence([ASN1.algorithm(CMSOID.rsaEncryption, ASN1.null), ASN1.bitString([UInt8](external))])
        }
        return try ecSubjectPublicKeyInfo(point: [UInt8](external))
    }

    public static func ecSubjectPublicKeyInfo(point: [UInt8]) throws -> [UInt8] {
        let curve: CMSCurve
        switch point.count {
        case 65: curve = .p256
        case 97: curve = .p384
        case 133: curve = .p521
        default: throw BuildError.unsupported("EC point of \(point.count) bytes")
        }
        return ASN1.sequence([ASN1.algorithm(CMSOID.ecPublicKey, ASN1.oid(curve.oid)), ASN1.bitString(point)])
    }

    public static func name(commonName: String) -> [UInt8] {
        ASN1.sequence([ASN1.set([ASN1.sequence([ASN1.oid(CMSOID.commonName), ASN1.utf8String(commonName)])])])
    }

    /// A self-signed X.509 v3 certificate. `sign` receives the DER of the
    /// TBSCertificate and returns the signature (RSA PKCS#1 v1.5 SHA-256 when
    /// `ec` is false, ECDSA SHA-256 when true).
    public static func selfSignedCertificate(commonName: String, email: String?, subjectPublicKeyInfo spki: [UInt8],
                                             serial: [UInt8], subjectKeyIdentifier: [UInt8]?, ec: Bool,
                                             notBefore: Date = Date(timeIntervalSinceNow: -3600),
                                             notAfter: Date = Date(timeIntervalSinceNow: 86_400),
                                             sign: ([UInt8]) throws -> [UInt8]) throws -> [UInt8] {
        let sigAlg = ec ? ASN1.algorithm(CMSOID.ecdsaSHA256) : ASN1.algorithm(CMSOID.sha256WithRSA, ASN1.null)
        let subject = name(commonName: commonName)
        var extensions: [[UInt8]] = []
        if let ski = subjectKeyIdentifier {
            extensions.append(ASN1.sequence([ASN1.oid(CMSOID.subjectKeyIdentifierExt), ASN1.octetString(ASN1.octetString(ski))]))
        }
        if let email {
            extensions.append(ASN1.sequence([ASN1.oid(CMSOID.subjectAltName),
                                             ASN1.octetString(ASN1.sequence([ASN1.implicitPrimitive(1, Array(email.utf8))]))]))
        }
        var tbsItems: [[UInt8]] = [ASN1.explicit(0, ASN1.integer(2)), ASN1.integer(serial), sigAlg, subject,
                                   ASN1.sequence([ASN1.utcTime(notBefore), ASN1.utcTime(notAfter)]), subject, spki]
        if !extensions.isEmpty { tbsItems.append(ASN1.explicit(3, ASN1.sequence(extensions))) }
        let tbs = ASN1.sequence(tbsItems)
        let signature = try sign(tbs)
        return ASN1.sequence([tbs, sigAlg, ASN1.bitString(signature)])
    }

    // MARK: Envelopes

    static func identifier(_ id: CMSRecipientIdentifier, kari: Bool = false) -> [UInt8] {
        switch id {
        case .issuerAndSerial(let issuer, let serial): return ASN1.sequence([issuer, ASN1.integer(serial)])
        case .subjectKeyIdentifier(let ski):
            return kari ? ASN1.implicitConstructed(0, ASN1.octetString(ski)) : ASN1.implicitPrimitive(0, ski)
        }
    }

    static func hashAlgorithm(_ h: CMSHash) -> [UInt8] { ASN1.algorithm(h.oid, ASN1.null) }

    /// An EnvelopedData (CBC ciphers) or AuthEnvelopedData (GCM) ContentInfo.
    public static func envelope(_ content: Data, to recipients: [Recipient], cipher: Cipher = .aesCBC(bits: 256)) throws -> Data {
        let contentAlg: [UInt8]
        let encrypted: [UInt8]
        var mac: [UInt8]?
        let cek: [UInt8]
        switch cipher {
        case .aesCBC(let bits):
            cek = random(bits / 8)
            let iv = random(16)
            let oid = bits == 128 ? CMSOID.aes128CBC : bits == 192 ? CMSOID.aes192CBC : CMSOID.aes256CBC
            contentAlg = ASN1.algorithm(oid, ASN1.octetString(iv))
            encrypted = try CMSSymmetric.cbc([UInt8](content), key: cek, iv: iv, des3: false, encrypt: true)
        case .des3CBC:
            cek = random(24)
            let iv = random(8)
            contentAlg = ASN1.algorithm(CMSOID.desEDE3CBC, ASN1.octetString(iv))
            encrypted = try CMSSymmetric.cbc([UInt8](content), key: cek, iv: iv, des3: true, encrypt: true)
        case .aesGCM(let bits):
            cek = random(bits / 8)
            let nonce = random(12)
            let oid = bits == 128 ? CMSOID.aes128GCM : bits == 192 ? CMSOID.aes192GCM : CMSOID.aes256GCM
            contentAlg = ASN1.algorithm(oid, ASN1.sequence([ASN1.octetString(nonce), ASN1.integer(16)]))
            let box = try AES.GCM.seal(content, using: SymmetricKey(data: cek), nonce: AES.GCM.Nonce(data: nonce))
            encrypted = Array(box.ciphertext)
            mac = Array(box.tag)
        }
        var infos: [[UInt8]] = []
        for r in recipients { infos.append(try recipientInfo(r, cek: cek)) }
        let eci = ASN1.sequence([ASN1.oid(CMSOID.data), contentAlg, ASN1.implicitPrimitive(0, encrypted)])
        let body: [UInt8]
        let type: String
        if let mac {
            body = ASN1.sequence([ASN1.integer(0), ASN1.set(infos), eci, ASN1.octetString(mac)])
            type = CMSOID.authEnvelopedData
        } else {
            body = ASN1.sequence([ASN1.integer(2), ASN1.set(infos), eci])
            type = CMSOID.envelopedData
        }
        return Data(ASN1.sequence([ASN1.oid(type), ASN1.explicit(0, body)]))
    }

    static func recipientInfo(_ r: Recipient, cek: [UInt8]) throws -> [UInt8] {
        switch r {
        case .rsa(let id, let key, let oaep):
            let algorithm: SecKeyAlgorithm
            let alg: [UInt8]
            switch oaep {
            case nil: algorithm = .rsaEncryptionPKCS1; alg = ASN1.algorithm(CMSOID.rsaEncryption, ASN1.null)
            case .some(let h):
                switch h {
                case .sha1: algorithm = .rsaEncryptionOAEPSHA1
                case .sha256: algorithm = .rsaEncryptionOAEPSHA256
                case .sha384: algorithm = .rsaEncryptionOAEPSHA384
                case .sha512: algorithm = .rsaEncryptionOAEPSHA512
                }
                let params = h == .sha1 ? ASN1.sequence([]) : ASN1.sequence([
                    ASN1.explicit(0, hashAlgorithm(h)),
                    ASN1.explicit(1, ASN1.algorithm(CMSOID.mgf1, hashAlgorithm(h))),
                ])
                alg = ASN1.algorithm(CMSOID.rsaOAEP, params)
            }
            var error: Unmanaged<CFError>?
            guard let wrapped = SecKeyCreateEncryptedData(key, algorithm, Data(cek) as CFData, &error) as Data? else {
                throw BuildError.key("RSA encryption failed: \(String(describing: error?.takeRetainedValue()))")
            }
            if case .subjectKeyIdentifier = id {
                return ASN1.sequence([ASN1.integer(2), identifier(id), alg, ASN1.octetString([UInt8](wrapped))])
            }
            return ASN1.sequence([ASN1.integer(0), identifier(id), alg, ASN1.octetString([UInt8](wrapped))])
        case .ecdh(let id, let publicKey, let kdf):
            let (ephemeral, z) = try ephemeralAgreement(publicKey: publicKey)
            let scheme: String
            switch kdf {   // dhSinglePass-stdDH-sha*kdf-scheme
            case .sha1: scheme = "1.3.133.16.840.63.0.2"
            case .sha256: scheme = "1.3.132.1.11.1"
            case .sha384: scheme = "1.3.132.1.11.2"
            case .sha512: scheme = "1.3.132.1.11.3"
            }
            let wrapOID = cek.count == 16 ? CMSOID.aes128Wrap : cek.count == 24 ? CMSOID.aes192Wrap : CMSOID.aes256Wrap
            let wrapLength = cek.count == 16 ? 16 : cek.count == 24 ? 24 : 32
            let wrapAlg = ASN1.algorithm(wrapOID)
            let kek = CMSKDF.x963(hash: kdf, z: z, sharedInfo: CMSKDF.eccSharedInfo(wrap: wrapAlg, ukm: nil, keyBytes: wrapLength), length: wrapLength)
            let wrapped = try AES.KeyWrap.wrap(SymmetricKey(data: cek), using: SymmetricKey(data: kek))
            let originator = ASN1.explicit(0, ASN1.implicitConstructed(1, ASN1.algorithm(CMSOID.ecPublicKey) + ASN1.bitString(ephemeral)))
            let rek = ASN1.sequence([ASN1.sequence([identifier(id, kari: true), ASN1.octetString([UInt8](wrapped))])])
            return ASN1.implicitConstructed(1, ASN1.integer(3) + originator + ASN1.algorithm(scheme, wrapAlg) + rek)
        }
    }

    /// An ephemeral key on the recipient's curve and the shared secret Z.
    static func ephemeralAgreement(publicKey: Data) throws -> (ephemeral: [UInt8], z: [UInt8]) {
        func bytes(_ s: SharedSecret) -> [UInt8] { s.withUnsafeBytes { [UInt8]($0) } }
        switch publicKey.count {
        case 65:
            let e = P256.KeyAgreement.PrivateKey()
            return ([UInt8](e.publicKey.x963Representation), bytes(try e.sharedSecretFromKeyAgreement(with: .init(x963Representation: publicKey))))
        case 97:
            let e = P384.KeyAgreement.PrivateKey()
            return ([UInt8](e.publicKey.x963Representation), bytes(try e.sharedSecretFromKeyAgreement(with: .init(x963Representation: publicKey))))
        case 133:
            let e = P521.KeyAgreement.PrivateKey()
            return ([UInt8](e.publicKey.x963Representation), bytes(try e.sharedSecretFromKeyAgreement(with: .init(x963Representation: publicKey))))
        default:
            throw BuildError.unsupported("EC point of \(publicKey.count) bytes")
        }
    }

    // MARK: Signatures

    /// A SignedData ContentInfo with one signer and signed attributes
    /// (content type, message digest, signing time). `sign` receives the DER
    /// of the signed attributes and returns the signature made with
    /// `signatureAlgorithmOID` (e.g. sha256WithRSAEncryption, ecdsa-with-SHA256).
    public static func signed(_ content: Data, detached: Bool, certificate: X509Certificate, bySubjectKeyIdentifier: Bool = false,
                              hash: CMSHash = .sha256, signatureAlgorithmOID: String, signingTime: Date = Date(),
                              sign: ([UInt8]) throws -> [UInt8]) throws -> Data {
        let digest = CMSDigest.hash(hash, content)
        let attrs = ASN1.set([
            ASN1.sequence([ASN1.oid(CMSOID.contentTypeAttr), ASN1.set([ASN1.oid(CMSOID.data)])]),
            ASN1.sequence([ASN1.oid(CMSOID.messageDigestAttr), ASN1.set([ASN1.octetString(digest)])]),
            ASN1.sequence([ASN1.oid(CMSOID.signingTimeAttr), ASN1.set([ASN1.utcTime(signingTime)])]),
        ])
        let signature = try sign(attrs)
        let sid: CMSRecipientIdentifier
        if bySubjectKeyIdentifier, let ski = certificate.subjectKeyIdentifier { sid = .subjectKeyIdentifier(ski) } else { sid = certificate.issuerAndSerial }
        let version = bySubjectKeyIdentifier ? 3 : 1
        var signedAttrs = attrs
        signedAttrs[0] = 0xA0
        let sigAlg = signatureAlgorithmOID.hasPrefix("1.2.840.10045") ? ASN1.algorithm(signatureAlgorithmOID) : ASN1.algorithm(signatureAlgorithmOID, ASN1.null)
        let signerInfo = ASN1.sequence([ASN1.integer(version), identifier(sid), hashAlgorithm(hash), signedAttrs, sigAlg, ASN1.octetString(signature)])
        var encap = [ASN1.oid(CMSOID.data)]
        if !detached { encap.append(ASN1.explicit(0, ASN1.octetString([UInt8](content)))) }
        let body = ASN1.sequence([ASN1.integer(version), ASN1.set([hashAlgorithm(hash)]), ASN1.sequence(encap),
                                  ASN1.implicitConstructed(0, certificate.der), ASN1.set([signerInfo])])
        return Data(ASN1.sequence([ASN1.oid(CMSOID.signedData), ASN1.explicit(0, body)]))
    }

    static func random(_ n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        _ = out.withUnsafeMutableBytes { unsafe SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return out
    }
}
