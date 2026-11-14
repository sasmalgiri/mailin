@testable import ArchiveCore
//
//  SMIMEPortable.swift
//  maxmailin
//
//  R6 (S/MIME on iPhone and iPad): the app's seam onto the package's portable
//  CMS reader (`CMSEnvelope`, `CMSSignedData`). On iPhone and iPad it is the
//  only S/MIME path; on the Mac the CMSDecoder path runs first, untouched, and
//  this one is the fallback for what CMSDecoder cannot open (AuthEnvelopedData
//  / AES-GCM, identities in the data-protection keychain). Behind the
//  `.protectedMessageDecrypt` module switch (preview, off by default).
//

import Foundation
import Security

extension SMIMEHandler {

    // MARK: Decryption

    /// The content of a CMS part — a decrypted envelope or the content of
    /// signed data — opened with `keyOperation` (by default the identities in
    /// this device's keychain), or why it stays locked.
    static func decodePortable(_ data: Data, keyOperation: CMSPrivateKeyOperation? = nil) -> Result<Data, CMSError> {
        do {
            let plain = try CMSPortable.content(of: data, keyOperation: keyOperation ?? SMIMEKeychainIdentities.keyOperation())
            return plain.isEmpty ? .failure(.malformed("empty content")) : .success(plain)
        } catch let error as CMSError {
            return .failure(error)
        } catch {
            return .failure(.decryptionFailed(error.localizedDescription))
        }
    }

    /// The reason a locked S/MIME row states.
    static func lockedReason(_ error: CMSError) -> String {
        switch error {
        case .noMatchingKey(let recipients):
            let names = recipients.map(\.description).joined(separator: "; ")
            return String(localized: "encrypted for \(names); no matching private key in this device's keychain — import the recipient's S/MIME identity (.p12) in Settings ▸ Health")
        case .decryptionFailed(let why):
            return String(localized: "the private key in the keychain did not open the envelope (\(why))")
        case .authenticationFailed:
            return String(localized: "the envelope's integrity check failed — the part was altered, or the key is not the recipient's")
        case .unsupported(let what):
            return String(localized: "S/MIME envelope not opened: \(what) is not supported")
        case .malformed(let why):
            return String(localized: "not a readable S/MIME envelope (\(why))")
        case .unexpectedContentType(let oid):
            return String(localized: "not a readable S/MIME envelope (\(oid))")
        }
    }

    // MARK: Signatures

    /// Verifies a SignedData blob with the portable reader and maps the result
    /// through the same verdict function as the CMSDecoder path. Trust is
    /// judged by the system with network fetching turned off (offline-first).
    static func verifyPortable(signedData: Data, detachedContent: Data?) -> VerificationResult {
        let results: [CMSSignatureVerification]
        do {
            results = try CMSSignedData.verify(signedData, detachedContent: detachedContent)
        } catch {
            return VerificationResult(status: mapVerdict(parseError: true, decoderStatus: nil, trustResult: .unavailable, certsPresent: false, certExpired: false),
                                      signerName: nil, signerEmail: nil, certificateInfo: nil)
        }
        guard let first = results.first else {
            return VerificationResult(status: .notSigned, signerName: nil, signerEmail: nil, certificateInfo: nil)
        }
        let decoderStatus: DecoderStatus?
        switch first.outcome {
        case .valid: decoderStatus = .valid
        case .contentAltered, .badSignature: decoderStatus = .invalidSignature
        case .contentMissing: decoderStatus = .needsDetachedContent
        case .signerCertificateMissing, .unsupported: decoderStatus = nil
        }
        var trustOutcome = TrustOutcome.unavailable
        var chain: [SecCertificate] = []
        if let signer = first.signer, let leaf = SecCertificateCreateWithData(nil, Data(signer.der) as CFData) {
            let others = first.certificates.filter { $0 != signer }.compactMap { SecCertificateCreateWithData(nil, Data($0.der) as CFData) }
            var trust: SecTrust?
            if SecTrustCreateWithCertificates([leaf] + others as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust {
                SecTrustSetNetworkFetchAllowed(trust, false)
                trustOutcome = SecTrustEvaluateWithError(trust, nil) ? .trusted : .untrusted
                chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? [leaf]
            }
        }
        let info = first.signer.map { certificateInfo($0, chainLength: max(chain.count, 1)) }
        let status = mapVerdict(parseError: false, decoderStatus: decoderStatus, trustResult: trustOutcome,
                                certsPresent: info != nil, certExpired: info?.isExpired ?? false)
        return VerificationResult(status: status, signerName: first.signer?.commonName, signerEmail: first.signer?.emailAddresses.first,
                                  certificateInfo: info)
    }

    static func certificateInfo(_ cert: X509Certificate, chainLength: Int) -> CertificateInfo {
        CertificateInfo(commonName: cert.commonName, email: cert.emailAddresses.first, issuer: cert.issuerCommonName,
                        serialNumber: cert.serial.map { String(format: "%02X", $0) }.joined(separator: ":"),
                        notValidBefore: cert.notBefore, notValidAfter: cert.notAfter,
                        isExpired: cert.notAfter.map { Date() > $0 } ?? false,
                        chainLength: chainLength, isSelfSigned: cert.issuerDER == cert.subjectDER)
    }

    /// The portable counterpart of `verifySignature(of:)`'s CMSDecoder branch:
    /// the signature blob and, for multipart/signed, the signed entity.
    static func verifySignaturePortable(of email: MBOXParser.RawEmail) -> VerificationResult {
        let contentType = email.headers["Content-Type"] ?? ""
        guard let blob = findSignedData(in: email) else {
            return VerificationResult(status: .unverifiable, signerName: nil, signerEmail: nil, certificateInfo: nil)
        }
        let detached = contentType.lowercased().contains("multipart/signed")
            ? detachedSignedEntity(rawSource: email.rawSource, contentType: contentType) : nil
        return verifyPortable(signedData: blob, detachedContent: detached)
    }
}
