//
//  CMSSignedData.swift
//  ArchiveCore
//
//  R6 (S/MIME on iPhone and iPad): portable verification of CMS SignedData
//  (RFC 5652 §5) — the signature of S/MIME signed mail, opaque
//  (application/pkcs7-mime; smime-type=signed-data) or detached
//  (multipart/signed). The digest of the content is compared with the
//  message-digest attribute, and the signature over the signed attributes is
//  checked with the signer certificate's public key (Security framework, on
//  every platform). Trust in the certificate is a separate question the app
//  answers with SecTrust; this file says only whether the signature holds.
//
//  Read: RSA PKCS#1 v1.5 and RSA-PSS, ECDSA (P-256/384/521), with SHA-1/256/
//  384/512; signer named by issuer and serial or by subject key identifier;
//  the signer certificate taken from the message. Not read: DSA, SHA-224,
//  signatures whose signer certificate is not in the message.
//

import Foundation
import Security

/// The parts of an X.509 certificate the CMS reader needs.
public struct X509Certificate: Sendable, Equatable {
    public let der: [UInt8]
    public let serial: [UInt8]
    public let issuerDER: [UInt8]
    public let subjectDER: [UInt8]
    public let subjectPublicKeyInfo: [UInt8]
    public let subjectKeyIdentifier: [UInt8]?
    public let notBefore: Date?
    public let notAfter: Date?
    public let emailAddresses: [String]

    public var commonName: String? { X509Name.commonName(der: subjectDER) }
    public var issuerCommonName: String? { X509Name.commonName(der: issuerDER) }

    public init(der: [UInt8]) throws {
        let cert = try ASN1Node.parse(der)
        guard cert.tag == 0x30, let tbs = try cert.children().first, tbs.tag == 0x30 else { throw CMSError.malformed("certificate expected") }
        var fields = try tbs.children()[...]
        if fields.first?.contextNumber == 0 { fields.removeFirst() }   // version
        guard let serialNode = fields.popFirst(), serialNode.tag == 0x02 else { throw CMSError.malformed("certificate serial") }
        _ = fields.popFirst()   // signature algorithm
        guard let issuer = fields.popFirst(), let validity = fields.popFirst(), let subject = fields.popFirst(),
              let spki = fields.popFirst() else { throw CMSError.malformed("certificate fields") }
        self.der = der
        serial = CMSRecipientIdentifier.normalizedSerial(serialNode.content)
        issuerDER = Array(issuer.raw)
        subjectDER = Array(subject.raw)
        subjectPublicKeyInfo = Array(spki.raw)
        let times = (try? validity.children()) ?? []
        notBefore = times.first.flatMap(ASN1.time)
        notAfter = times.count > 1 ? ASN1.time(times[1]) : nil
        var ski: [UInt8]?
        var emails = X509Name.emails(der: subjectDER)
        for field in fields where field.contextNumber == 3 {
            guard let exts = try field.children().first else { continue }
            for ext in try exts.children() {
                let parts = try ext.children()
                guard let id = try parts.first?.oid(), let value = parts.last, value.tag == 0x04 else { continue }
                if id == CMSOID.subjectKeyIdentifierExt, let inner = try? ASN1Node.parse(Array(value.content)), inner.tag == 0x04 {
                    ski = Array(inner.content)
                } else if id == CMSOID.subjectAltName, let names = try? ASN1Node.parse(Array(value.content)) {
                    for name in (try? names.children()) ?? [] where name.tag == 0x81 {   // rfc822Name
                        if let s = String(bytes: name.content, encoding: .utf8), !emails.contains(s) { emails.append(s) }
                    }
                }
            }
        }
        subjectKeyIdentifier = ski
        emailAddresses = emails
    }

    /// The public key, via the Security framework.
    public func publicKey() -> SecKey? {
        guard let cert = SecCertificateCreateWithData(nil, Data(der) as CFData) else { return nil }
        return SecCertificateCopyKey(cert)
    }

    /// The identifier a sender would use for this certificate.
    public var issuerAndSerial: CMSRecipientIdentifier { .issuerAndSerial(issuer: issuerDER, serial: serial) }
}

enum X509Name {
    /// Attribute values of the given type in a Name.
    static func values(der: [UInt8], type: String) -> [String] {
        guard let name = try? ASN1Node.parse(der), let rdns = try? name.children() else { return [] }
        var out: [String] = []
        for rdn in rdns {
            for atv in (try? rdn.children()) ?? [] {
                guard let parts = try? atv.children(), parts.count == 2, (try? parts[0].oid()) == type else { continue }
                let v = parts[1]
                let s: String?
                switch v.tag {
                case 0x1E:   // BMPString
                    let units = stride(from: v.content.startIndex, to: v.content.endIndex - 1, by: 2).map { UInt16(v.content[$0]) << 8 | UInt16(v.content[$0 + 1]) }
                    s = String(decoding: units, as: UTF16.self)
                default:
                    s = String(bytes: v.content, encoding: .utf8) ?? String(bytes: v.content, encoding: .isoLatin1)
                }
                if let s { out.append(s) }
            }
        }
        return out
    }
    static func commonName(der: [UInt8]) -> String? { values(der: der, type: CMSOID.commonName).first }
    static func emails(der: [UInt8]) -> [String] { values(der: der, type: CMSOID.emailAddress) }
}

/// The verdict on one signer of a SignedData part.
public struct CMSSignatureVerification: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// The content digest matches and the signature holds for the signer certificate's key.
        case valid
        /// The content was changed after signing (digest mismatch).
        case contentAltered
        /// The signature bytes do not verify with the signer's key.
        case badSignature
        /// The signer's certificate is not in the message; nothing can be attributed.
        case signerCertificateMissing
        /// Detached signature without the content it covers.
        case contentMissing
        /// An algorithm this reader does not verify, named.
        case unsupported(String)
    }
    public let outcome: Outcome
    public let signer: X509Certificate?
    /// Every certificate the message carries (for chain building).
    public let certificates: [X509Certificate]
    public let signingTime: Date?
    public let digestAlgorithm: String?
}

public enum CMSSignedData {

    /// The encapsulated content of a SignedData part (nil when detached).
    public static func content(_ data: Data) throws -> Data? {
        let parsed = try Parsed(data)
        return parsed.content.map { Data($0) }
    }

    /// Verifies every signer; the first verdict is the message's. `detachedContent`
    /// is the signed entity for a detached signature (multipart/signed).
    /// Throws only when the bytes are not a SignedData structure; returns an
    /// empty list when it has no signers.
    public static func verify(_ data: Data, detachedContent: Data? = nil) throws -> [CMSSignatureVerification] {
        let parsed = try Parsed(data)
        let content = parsed.content ?? detachedContent.map { [UInt8]($0) }
        return parsed.signers.map { verify($0, content: content, contentType: parsed.contentType, certificates: parsed.certificates) }
    }

    struct Signer {
        let identifier: CMSRecipientIdentifier
        let digestAlgorithm: ASN1Algorithm
        let signedAttributes: ASN1Node?
        let signatureAlgorithm: ASN1Algorithm
        let signature: [UInt8]
    }

    struct Parsed {
        let contentType: String
        let content: [UInt8]?
        let certificates: [X509Certificate]
        let signers: [Signer]

        init(_ data: Data) throws {
            let info = try ASN1Node.parse([UInt8](data))
            let top = try info.children()
            guard info.tag == 0x30, top.count >= 2 else { throw CMSError.malformed("ContentInfo expected") }
            let type = try top[0].oid()
            guard type == CMSOID.signedData else { throw CMSError.unexpectedContentType(type) }
            guard top[1].contextNumber == 0, let body = try top[1].children().first, body.tag == 0x30 else { throw CMSError.malformed("[0] content expected") }
            var fields = try body.children()[...]
            guard fields.popFirst()?.tag == 0x02 else { throw CMSError.malformed("version expected") }
            guard fields.popFirst()?.tag == 0x31 else { throw CMSError.malformed("digestAlgorithms expected") }
            guard let encap = fields.popFirst(), encap.tag == 0x30 else { throw CMSError.malformed("encapContentInfo expected") }
            let encapParts = try encap.children()
            guard let typeNode = encapParts.first else { throw CMSError.malformed("eContentType expected") }
            contentType = try typeNode.oid()
            if encapParts.count > 1, encapParts[1].contextNumber == 0, let octets = try encapParts[1].children().first {
                content = try octets.octets()
            } else {
                content = nil
            }
            var certs: [X509Certificate] = []
            if fields.first?.contextNumber == 0, let set = fields.popFirst() {
                for choice in try set.children() where choice.tag == 0x30 {
                    if let c = try? X509Certificate(der: Array(choice.raw)) { certs.append(c) }
                }
            }
            if fields.first?.contextNumber == 1 { fields.removeFirst() }   // crls
            certificates = certs
            guard let infos = fields.popFirst(), infos.tag == 0x31 else { throw CMSError.malformed("signerInfos expected") }
            signers = try infos.children().map { info in
                var f = try info.children()[...]
                guard f.popFirst()?.tag == 0x02, let sid = f.popFirst(), let digest = f.popFirst() else { throw CMSError.malformed("SignerInfo") }
                var attrs: ASN1Node?
                if f.first?.contextNumber == 0 { attrs = f.popFirst() }
                guard let sigAlg = f.popFirst(), let sig = f.popFirst() else { throw CMSError.malformed("SignerInfo signature") }
                return Signer(identifier: try CMSEnvelope.Recipient.identifier(sid), digestAlgorithm: try ASN1Algorithm(digest),
                              signedAttributes: attrs, signatureAlgorithm: try ASN1Algorithm(sigAlg), signature: try sig.octets())
            }
        }
    }

    static func verify(_ signer: Signer, content: [UInt8]?, contentType: String, certificates: [X509Certificate]) -> CMSSignatureVerification {
        let cert = certificates.first { signer.identifier.matches($0) }
        func result(_ o: CMSSignatureVerification.Outcome, time: Date? = nil) -> CMSSignatureVerification {
            CMSSignatureVerification(outcome: o, signer: cert, certificates: certificates, signingTime: time, digestAlgorithm: CMSHash(oid: signer.digestAlgorithm.oid)?.rawValue)
        }
        guard let hash = CMSHash(oid: signer.digestAlgorithm.oid) else { return result(.unsupported("digest \(CMSOID.name(signer.digestAlgorithm.oid))")) }
        guard let content else { return result(.contentMissing) }
        let digest = CMSDigest.hash(hash, content)

        var signedBytes = content
        var signingTime: Date?
        if let attrs = signer.signedAttributes {
            var messageDigest: [UInt8]?
            var attrContentType: String?
            for attr in (try? attrs.children()) ?? [] {
                guard let parts = try? attr.children(), parts.count == 2, let type = try? parts[0].oid(),
                      let value = try? parts[1].children().first else { continue }
                switch type {
                case CMSOID.messageDigestAttr: messageDigest = try? value.octets()
                case CMSOID.contentTypeAttr: attrContentType = try? value.oid()
                case CMSOID.signingTimeAttr: signingTime = ASN1.time(value)
                default: break
                }
            }
            guard let messageDigest else { return result(.badSignature, time: signingTime) }
            guard messageDigest == digest, attrContentType == nil || attrContentType == contentType else { return result(.contentAltered, time: signingTime) }
            signedBytes = attrs.asUniversalSet()
        }
        guard let cert else { return result(.signerCertificateMissing, time: signingTime) }
        guard let key = cert.publicKey() else { return result(.unsupported("the signer certificate's public key"), time: signingTime) }
        guard let algorithm = secAlgorithm(signer.signatureAlgorithm, hash: hash) else {
            return result(.unsupported("signature \(CMSOID.name(signer.signatureAlgorithm.oid))"), time: signingTime)
        }
        let ok = SecKeyVerifySignature(key, algorithm, Data(signedBytes) as CFData, Data(signer.signature) as CFData, nil)
        return result(ok ? .valid : .badSignature, time: signingTime)
    }

    static func secAlgorithm(_ alg: ASN1Algorithm, hash: CMSHash) -> SecKeyAlgorithm? {
        func rsa(_ h: CMSHash) -> SecKeyAlgorithm {
            switch h {
            case .sha1: return .rsaSignatureMessagePKCS1v15SHA1
            case .sha256: return .rsaSignatureMessagePKCS1v15SHA256
            case .sha384: return .rsaSignatureMessagePKCS1v15SHA384
            case .sha512: return .rsaSignatureMessagePKCS1v15SHA512
            }
        }
        func ecdsa(_ h: CMSHash) -> SecKeyAlgorithm {
            switch h {
            case .sha1: return .ecdsaSignatureMessageX962SHA1
            case .sha256: return .ecdsaSignatureMessageX962SHA256
            case .sha384: return .ecdsaSignatureMessageX962SHA384
            case .sha512: return .ecdsaSignatureMessageX962SHA512
            }
        }
        switch alg.oid {
        case CMSOID.rsaEncryption: return rsa(hash)
        case CMSOID.sha1WithRSA: return rsa(.sha1)
        case CMSOID.sha256WithRSA: return rsa(.sha256)
        case CMSOID.sha384WithRSA: return rsa(.sha384)
        case CMSOID.sha512WithRSA: return rsa(.sha512)
        case CMSOID.ecPublicKey: return ecdsa(hash)
        case CMSOID.ecdsaSHA1: return ecdsa(.sha1)
        case CMSOID.ecdsaSHA256: return ecdsa(.sha256)
        case CMSOID.ecdsaSHA384: return ecdsa(.sha384)
        case CMSOID.ecdsaSHA512: return ecdsa(.sha512)
        case CMSOID.rsaPSS:
            // RSASSA-PSS-params: hash [0]; Apple's PSS verifies with MGF1 of the same hash and salt = hash length.
            var h = CMSHash.sha1
            if let p = alg.parameters, let fields = try? p.children() {
                for f in fields where f.contextNumber == 0 {
                    if let inner = try? f.children().first, let a = try? ASN1Algorithm(inner), let hh = CMSHash(oid: a.oid) { h = hh } else { return nil }
                }
            }
            switch h {
            case .sha1: return .rsaSignatureMessagePSSSHA1
            case .sha256: return .rsaSignatureMessagePSSSHA256
            case .sha384: return .rsaSignatureMessagePSSSHA384
            case .sha512: return .rsaSignatureMessagePSSSHA512
            }
        default: return nil
        }
    }
}

/// One entry point for an S/MIME CMS part: decrypt an envelope, or take the
/// content of signed data — the portable counterpart of CMSDecoder's
/// `CMSDecoderCopyContent`.
public enum CMSPortable {
    public static func content(of data: Data, keyOperation: CMSPrivateKeyOperation) throws -> Data {
        switch CMSEnvelope.contentType(of: data) {
        case CMSOID.envelopedData, CMSOID.authEnvelopedData:
            return try CMSEnvelope.decrypt(data, keyOperation: keyOperation).content
        case CMSOID.signedData:
            guard let content = try CMSSignedData.content(data), !content.isEmpty else {
                throw CMSError.unsupported("a detached signature carries no content of its own")
            }
            return content
        case let other?:
            throw CMSError.unexpectedContentType(other)
        case nil:
            throw CMSError.malformed("the part is not CMS")
        }
    }
}
