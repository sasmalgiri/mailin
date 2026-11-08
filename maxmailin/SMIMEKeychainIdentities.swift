@testable import ArchiveCore
//
//  SMIMEKeychainIdentities.swift
//  maxmailin
//
//  R6 (S/MIME on iPhone and iPad): the S/MIME identities the portable CMS
//  reader may use — the certificate-and-private-key pairs in this device's
//  keychain. The private key is only ever referenced: decryption and key
//  agreement run inside the Security framework (`CMSSecKeyOperation`), and
//  nothing copies the key out.
//
//  On iPhone and iPad an app sees only its own keychain items; identities a
//  configuration profile installed stay in the system keychain. So the
//  person imports the .p12 here (`importPKCS12`): the password is typed once,
//  used to open the file and dropped — it is never stored.
//

import Foundation
import Security

enum SMIMEKeychainIdentities {

    struct Identity: Identifiable {
        let certificate: X509Certificate
        let privateKey: SecKey
        let reference: SecIdentity
        var id: String { certificate.der.prefix(64).map { String(format: "%02x", $0) }.joined() + "-\(certificate.der.count)" }
        var commonName: String { certificate.commonName ?? certificate.emailAddresses.first ?? "—" }
    }

    enum ImportError: Error, Equatable {
        case wrongPassword
        case notPKCS12
        case noIdentity
        case keychain(OSStatus)
    }

    /// For tests: in-memory keys used instead of the keychain (nil = the keychain).
    nonisolated(unsafe) static var testKeys: [(privateKey: SecKey, certificate: X509Certificate)]?

    // MARK: Reading

    /// Every identity in the keychains this app can use. On the Mac the
    /// login keychain and the data-protection keychain are both searched.
    static func all() -> [Identity] {
        var queries: [[CFString: Any]] = [[kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll]]
        #if os(macOS)
        queries.append([kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll, kSecUseDataProtectionKeychain: true])
        #endif
        var out: [Identity] = []
        var seen = Set<[UInt8]>()
        for query in queries {
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let refs = result as? [SecIdentity] else { continue }
            for ref in refs {
                guard let identity = identity(ref), seen.insert(identity.certificate.der).inserted else { continue }
                out.append(identity)
            }
        }
        return out
    }

    static func identity(_ ref: SecIdentity) -> Identity? {
        var cert: SecCertificate?
        var key: SecKey?
        guard SecIdentityCopyCertificate(ref, &cert) == errSecSuccess, let cert,
              SecIdentityCopyPrivateKey(ref, &key) == errSecSuccess, let key,
              let parsed = try? X509Certificate(der: [UInt8](SecCertificateCopyData(cert) as Data)) else { return nil }
        return Identity(certificate: parsed, privateKey: key, reference: ref)
    }

    /// The identities that look like S/MIME ones (the certificate names an email address) — what Settings lists.
    static func mailIdentities() -> [Identity] { all().filter { !$0.certificate.emailAddresses.isEmpty } }

    /// The key operation the portable CMS reader is given. The keychain is
    /// searched once, on the first recipient asked about.
    static func keyOperation() -> CMSPrivateKeyOperation {
        var cached: CMSPrivateKeyOperation?
        return { recipient, request in
            if cached == nil { cached = CMSSecKeyOperation.operation(keys: testKeys ?? all().map { ($0.privateKey, $0.certificate) }) }
            return try cached?(recipient, request)
        }
    }

    // MARK: Importing

    /// Opens a PKCS#12 file with the password and adds its identity to this
    /// device's keychain. The password is not kept anywhere. Returns the
    /// imported identity's certificate.
    @discardableResult
    static func importPKCS12(_ data: Data, password: String) throws -> X509Certificate {
        var items: CFArray?
        let options: [CFString: Any] = [kSecImportExportPassphrase: password]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        switch status {
        case errSecSuccess: break
        case errSecAuthFailed, errSecPkcs12VerifyFailure: throw ImportError.wrongPassword
        case errSecDecode, errSecUnknownFormat: throw ImportError.notPKCS12
        default: throw ImportError.keychain(status)
        }
        guard let entries = items as? [[CFString: Any]],
              let first = entries.first(where: { $0[kSecImportItemIdentity] != nil }),
              let anyIdentity = first[kSecImportItemIdentity] else { throw ImportError.noIdentity }
        let ref = anyIdentity as! SecIdentity   // CF type: the bridge cannot fail once present
        guard let parsed = identity(ref) else { throw ImportError.noIdentity }
        var add: [CFString: Any] = [kSecValueRef: ref, kSecAttrLabel: "mailin S/MIME — \(parsed.commonName)"]
        #if os(iOS)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess || added == errSecDuplicateItem else { throw ImportError.keychain(added) }
        return parsed.certificate
    }

    /// Removes an identity this app imported (iPhone and iPad: the app's own keychain).
    static func remove(_ identity: Identity) -> Bool {
        let status = SecItemDelete([kSecClass: kSecClassIdentity, kSecValueRef: identity.reference] as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// What an import failure says.
    static func describe(_ error: Error) -> String {
        switch error as? ImportError {
        case .wrongPassword: return String(localized: "The password did not open the file.")
        case .notPKCS12: return String(localized: "The file is not a .p12 / .pfx identity.")
        case .noIdentity: return String(localized: "The file holds no certificate with its private key.")
        case .keychain(let status): return String(localized: "The keychain refused the identity (\(Int(status))).")
        case nil: return error.localizedDescription
        }
    }
}
