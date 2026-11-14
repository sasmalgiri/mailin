//
//  CMSSecKeyOperation.swift
//  ArchiveCore
//
//  R6: the key operations of the portable CMS reader performed by the
//  Security framework on a private key reference — a keychain identity's key
//  on iPhone, iPad or Mac. The key is used, never exported: RSA decryption by
//  SecKeyCreateDecryptedData, ECDH by SecKeyCopyKeyExchangeResult.
//

import Foundation
import Security

public enum CMSSecKeyOperation {

    /// One private key with the certificate that names it. Answers only for
    /// recipients the certificate matches (issuer and serial, or subject key
    /// identifier); nil for every other recipient.
    public static func operation(privateKey: SecKey, certificate: X509Certificate) -> CMSPrivateKeyOperation {
        operation(keys: [(privateKey, certificate)])
    }

    /// Several identities: each recipient is answered by the identity whose
    /// certificate it names.
    public static func operation(keys: [(privateKey: SecKey, certificate: X509Certificate)]) -> CMSPrivateKeyOperation {
        return { recipient, request in
            guard let key = keys.first(where: { recipient.matches($0.certificate) })?.privateKey else { return nil }
            return try perform(request, with: key)
        }
    }

    /// Performs one request with the key, throwing `CMSError.decryptionFailed` with the Security framework's reason.
    public static func perform(_ request: CMSKeyRequest, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        func failure(_ what: String) -> CMSError {
            let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "no reason given"
            return .decryptionFailed("\(what): \(reason)")
        }
        switch request {
        case .rsaPKCS1v15(let wrapped):
            guard let out = SecKeyCreateDecryptedData(key, .rsaEncryptionPKCS1, wrapped as CFData, &error) as Data? else {
                throw failure("RSA decryption of the content key")
            }
            return out
        case .rsaOAEP(let hash, let wrapped):
            let algorithm: SecKeyAlgorithm
            switch hash {
            case .sha1: algorithm = .rsaEncryptionOAEPSHA1
            case .sha256: algorithm = .rsaEncryptionOAEPSHA256
            case .sha384: algorithm = .rsaEncryptionOAEPSHA384
            case .sha512: algorithm = .rsaEncryptionOAEPSHA512
            }
            guard let out = SecKeyCreateDecryptedData(key, algorithm, wrapped as CFData, &error) as Data? else {
                throw failure("RSA-OAEP decryption of the content key")
            }
            return out
        case .ecdh(let curve, let ephemeral):
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                               kSecAttrKeyClass: kSecAttrKeyClassPublic,
                                               kSecAttrKeySizeInBits: curve.bits]
            guard let peer = SecKeyCreateWithData(ephemeral as CFData, attributes as CFDictionary, &error) else {
                throw failure("the sender's ephemeral key")
            }
            guard let z = SecKeyCopyKeyExchangeResult(key, .ecdhKeyExchangeStandard, peer, [:] as CFDictionary, &error) as Data? else {
                throw failure("ECDH key agreement")
            }
            return z
        }
    }
}
