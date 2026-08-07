import Foundation
import Security

struct SMIMEHandler {

    /// Four-state forensic verdict (Part V). Each state is a DISTINCT forensic
    /// conclusion — none may be collapsed into another:
    ///  • validTrusted       — signature cryptographically valid AND the signer
    ///                         chains to a trusted anchor.
    ///  • validUntrustedCert — signature cryptographically valid, but the
    ///                         certificate chain is NOT trusted (self-signed,
    ///                         unknown CA, expired, or trust unavailable).
    ///  • invalid            — the cryptographic check FAILED: content was
    ///                         tampered with after signing, or the signature
    ///                         bytes are wrong. The strongest negative claim.
    ///  • unverifiable       — no conclusion possible: malformed CMS, missing
    ///                         certificates, detached content we cannot
    ///                         reconstruct, or an unsupported structure.
    ///                         MUST NOT be presented as valid OR invalid.
    ///  • notSigned          — passthrough: the message carries no signature.
    enum SignatureStatus: String, Codable, CaseIterable {
        case validTrusted = "Valid — Trusted Signer"
        case validUntrustedCert = "Valid Signature — Untrusted Certificate"
        case invalid = "Invalid — Failed Cryptographic Check"
        case unverifiable = "Unverifiable"
        case notSigned = "Not Signed"
    }

    /// Platform-independent mirror of `CMSSignerStatus`, so the status→verdict
    /// mapping is a pure function testable without CMSDecoder fixtures.
    enum DecoderStatus: CaseIterable, Sendable {
        case unsigned
        case valid
        case needsDetachedContent
        case invalidSignature   // tampered content OR bad signature bytes
        case invalidCert
        case invalidIndex
    }

    /// Outcome of the SecTrust / cert-chain evaluation accompanying the
    /// decoder status.
    enum TrustOutcome: CaseIterable, Sendable {
        case trusted        // certVerifyResult == errSecSuccess
        case untrusted      // chain evaluated and rejected
        case unavailable    // no trust evaluation was possible
    }

    /// PURE status→verdict mapping (Part V.3a). Every CMSDecoder status +
    /// trust-evaluation combination is mapped EXPLICITLY — exhaustive switch,
    /// no `default:` that could swallow a distinct outcome. In particular:
    /// `invalidSignature` (tampered content / bad signature bytes) maps to
    /// `.invalid`, NEVER to an "unknown signer" style downgrade.
    static func mapVerdict(parseError: Bool,
                           decoderStatus: DecoderStatus?,
                           trustResult: TrustOutcome,
                           certsPresent: Bool,
                           certExpired: Bool) -> SignatureStatus {
        // Malformed CMS: the decoder never produced a status — nothing can be
        // concluded about the content either way.
        if parseError { return .unverifiable }
        // Decoder ran but no signer status was obtainable (e.g.
        // CMSDecoderCopySignerStatus failed): unverifiable, not invalid.
        guard let decoderStatus else { return .unverifiable }

        switch decoderStatus {
        case .unsigned:
            return .notSigned
        case .valid:
            // Crypto check passed. Without the signer certificate we cannot
            // attribute the signature to anyone — unverifiable.
            guard certsPresent else { return .unverifiable }
            switch trustResult {
            case .trusted:
                // An expired certificate can never support a "trusted" claim
                // (no signing-time proof) — downgrade to untrusted-cert.
                return certExpired ? .validUntrustedCert : .validTrusted
            case .untrusted, .unavailable:
                return .validUntrustedCert
            }
        case .needsDetachedContent:
            // multipart/signed (detached): we don't reconstruct the
            // canonicalized signed bytes, so the crypto check never ran.
            // Not "invalid" (that would falsely imply tampering).
            return .unverifiable
        case .invalidSignature:
            // THE forensic-grade case: content hash mismatch (tampering) or
            // corrupt signature bytes. Always .invalid.
            return .invalid
        case .invalidCert:
            // CMS verified the signature but could not verify the signer
            // certificate. With certs present that is a trust problem, not
            // tampering; with no certs at all nothing is attributable.
            return certsPresent ? .validUntrustedCert : .unverifiable
        case .invalidIndex:
            // API-level failure (signer index out of range) — no conclusion.
            return .unverifiable
        }
    }

    struct CertificateInfo {
        let commonName: String?
        let email: String?
        let issuer: String?
        let serialNumber: String?
        let notValidBefore: Date?
        let notValidAfter: Date?
        let isExpired: Bool
        let chainLength: Int
        let isSelfSigned: Bool
    }

    struct VerificationResult {
        let status: SignatureStatus
        let signerName: String?
        let signerEmail: String?
        let certificateInfo: CertificateInfo?
    }

    static func verifySignature(of email: MBOXParser.RawEmail) -> VerificationResult {
        let contentType = email.headers["Content-Type"] ?? ""
        guard contentType.contains("pkcs7-signature") || contentType.contains("pkcs7-mime") ||
              contentType.contains("x-pkcs7-signature") || contentType.contains("x-pkcs7-mime") ||
              contentType.contains("signed-data") else {
            return VerificationResult(status: .notSigned, signerName: nil, signerEmail: nil, certificateInfo: nil)
        }

        #if os(macOS)
        guard let signedData = findSignedData(in: email) else {
            // Signed content type but no extractable signature blob —
            // structurally unverifiable, not "invalid".
            return VerificationResult(status: .unverifiable, signerName: nil, signerEmail: nil, certificateInfo: nil)
        }

        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let cmsDecoder = decoder else {
            return VerificationResult(status: mapVerdict(parseError: true, decoderStatus: nil, trustResult: .unavailable, certsPresent: false, certExpired: false),
                                      signerName: nil, signerEmail: nil, certificateInfo: nil)
        }

        guard CMSDecoderUpdateMessage(cmsDecoder, (signedData as NSData).bytes, signedData.count) == errSecSuccess,
              CMSDecoderFinalizeMessage(cmsDecoder) == errSecSuccess else {
            // Malformed CMS structure — parse failure.
            return VerificationResult(status: mapVerdict(parseError: true, decoderStatus: nil, trustResult: .unavailable, certsPresent: false, certExpired: false),
                                      signerName: nil, signerEmail: nil, certificateInfo: nil)
        }

        var numSigners: Int = 0
        guard CMSDecoderGetNumSigners(cmsDecoder, &numSigners) == errSecSuccess, numSigners > 0 else {
            return VerificationResult(status: .notSigned, signerName: nil, signerEmail: nil, certificateInfo: nil)
        }

        var signerStatus: CMSSignerStatus = .unsigned
        var trust: SecTrust?
        var certVerifyResult: OSStatus = errSecSuccess
        let policy = SecPolicyCreateBasicX509()

        let status = CMSDecoderCopySignerStatus(cmsDecoder, 0, policy, true, &signerStatus, &trust, &certVerifyResult)
        guard status == errSecSuccess else {
            // Decoder ran but the signer status is unobtainable.
            return VerificationResult(status: mapVerdict(parseError: false, decoderStatus: nil, trustResult: .unavailable, certsPresent: false, certExpired: false),
                                      signerName: nil, signerEmail: nil, certificateInfo: nil)
        }

        var signerName: String?
        var signerEmail: String?
        var certInfo: CertificateInfo?

        if let trust = trust,
           let certChain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
           let certRef = certChain.first {
            var commonName: CFString?
            if SecCertificateCopyCommonName(certRef, &commonName) == errSecSuccess {
                signerName = commonName as String?
            }
            var emailAddresses: CFArray?
            if SecCertificateCopyEmailAddresses(certRef, &emailAddresses) == errSecSuccess,
               let emails = emailAddresses as? [String] {
                signerEmail = emails.first
            }
            certInfo = extractCertificateInfo(from: certRef, chain: certChain)
        }

        // EXHAUSTIVE CMSSignerStatus → DecoderStatus translation. No `default:`
        // — an OS-added case falls to `@unknown default` and is surfaced as
        // "no status" (→ unverifiable), never silently classified.
        let decoderStatus: DecoderStatus?
        switch signerStatus {
        case .unsigned:             decoderStatus = .unsigned
        case .valid:                decoderStatus = .valid
        case .needsDetachedContent: decoderStatus = .needsDetachedContent
        case .invalidSignature:     decoderStatus = .invalidSignature
        case .invalidCert:          decoderStatus = .invalidCert
        case .invalidIndex:         decoderStatus = .invalidIndex
        @unknown default:           decoderStatus = nil
        }

        let trustOutcome: TrustOutcome = (trust == nil)
            ? .unavailable
            : (certVerifyResult == errSecSuccess ? .trusted : .untrusted)

        let resultStatus = mapVerdict(parseError: false,
                                      decoderStatus: decoderStatus,
                                      trustResult: trustOutcome,
                                      certsPresent: certInfo != nil,
                                      certExpired: certInfo?.isExpired ?? false)

        return VerificationResult(status: resultStatus, signerName: signerName, signerEmail: signerEmail, certificateInfo: certInfo)
        #else
        // No CMSDecoder off macOS — verification is not supported, which is
        // an "unverifiable" conclusion, not an invalid signature.
        return VerificationResult(status: .unverifiable, signerName: nil, signerEmail: nil, certificateInfo: nil)
        #endif
    }

    static func isEncrypted(_ email: MBOXParser.RawEmail) -> Bool {
        let contentType = email.headers["Content-Type"] ?? ""
        return contentType.contains("pkcs7-mime") && contentType.contains("enveloped-data")
    }

    static func decrypt(_ email: MBOXParser.RawEmail) -> Data? {
        guard isEncrypted(email) else { return nil }

        #if os(macOS)
        guard let encryptedData = findEncryptedData(in: email) else { return nil }

        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let cmsDecoder = decoder else { return nil }

        guard CMSDecoderUpdateMessage(cmsDecoder, (encryptedData as NSData).bytes, encryptedData.count) == errSecSuccess,
              CMSDecoderFinalizeMessage(cmsDecoder) == errSecSuccess else { return nil }

        var content: CFData?
        guard CMSDecoderCopyContent(cmsDecoder, &content) == errSecSuccess,
              let decryptedData = content as Data? else { return nil }

        return decryptedData
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private static func extractCertificateInfo(from cert: SecCertificate, chain: [SecCertificate]) -> CertificateInfo {
        var commonName: CFString?
        SecCertificateCopyCommonName(cert, &commonName)

        var emailAddresses: CFArray?
        SecCertificateCopyEmailAddresses(cert, &emailAddresses)
        let email = (emailAddresses as? [String])?.first

        let issuerName: String?
        if chain.count > 1 {
            var issuerCN: CFString?
            SecCertificateCopyCommonName(chain[1], &issuerCN)
            issuerName = issuerCN as String?
        } else {
            issuerName = commonName as String?
        }

        let serialData = SecCertificateCopySerialNumberData(cert, nil)
        let serialNumber = (serialData as Data?)?.map { String(format: "%02X", $0) }.joined(separator: ":")

        var notBefore: Date?
        var notAfter: Date?
        if let certData = SecCertificateCopyData(cert) as Data? {
            (notBefore, notAfter) = parseCertificateDates(from: certData)
        }

        let isExpired: Bool
        if let expiry = notAfter {
            isExpired = Date() > expiry
        } else {
            isExpired = false
        }

        let isSelfSigned = chain.count == 1 || (commonName as String?) == issuerName

        return CertificateInfo(
            commonName: commonName as String?,
            email: email,
            issuer: issuerName,
            serialNumber: serialNumber,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            isExpired: isExpired,
            chainLength: chain.count,
            isSelfSigned: isSelfSigned
        )
    }

    private static func parseCertificateDates(from derData: Data) -> (notBefore: Date?, notAfter: Date?) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")

        let bytes = [UInt8](derData)
        var dates: [Date] = []

        guard bytes.count >= 15 else { return (nil, nil) }
        for i in 0..<(bytes.count - 1) {
            // UTCTime tag (0x17) with length 13
            if bytes[i] == 0x17 && bytes[i + 1] == 13 && i + 15 <= bytes.count {
                let timeBytes = Array(bytes[(i + 2)..<(i + 15)])
                if let str = String(bytes: timeBytes, encoding: .ascii) {
                    formatter.dateFormat = "yyMMddHHmmss'Z'"
                    if let date = formatter.date(from: str) {
                        dates.append(date)
                    }
                }
            }
            // GeneralizedTime tag (0x18) with length 15
            if bytes[i] == 0x18 && bytes[i + 1] == 15 && i + 17 <= bytes.count {
                let timeBytes = Array(bytes[(i + 2)..<(i + 17)])
                if let str = String(bytes: timeBytes, encoding: .ascii) {
                    formatter.dateFormat = "yyyyMMddHHmmss'Z'"
                    if let date = formatter.date(from: str) {
                        dates.append(date)
                    }
                }
            }
        }

        let notBefore = dates.count >= 1 ? dates[0] : nil
        let notAfter = dates.count >= 2 ? dates[1] : nil
        return (notBefore, notAfter)
    }
    #endif

    private static func findSignedData(in email: MBOXParser.RawEmail) -> Data? {
        for attachment in email.attachments {
            let mime = attachment.mimeType.lowercased()
            if mime.contains("pkcs7") || mime.contains("signature") {
                if let b64 = attachment.base64, let data = Data(base64Encoded: b64) {
                    return data
                }
            }
        }
        if let b64Part = extractBase64Part(from: email.rawSource) {
            return Data(base64Encoded: b64Part, options: .ignoreUnknownCharacters)
        }
        return nil
    }

    private static func findEncryptedData(in email: MBOXParser.RawEmail) -> Data? {
        let rawLines = email.rawSource.components(separatedBy: "\n")
        var inBody = false
        var base64Lines: [String] = []
        for line in rawLines {
            if inBody {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    base64Lines.append(trimmed)
                }
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inBody = true
            }
        }
        let b64 = base64Lines.joined()
        return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
    }

    private static func extractBase64Part(from raw: String) -> String? {
        let parts = raw.components(separatedBy: "\n\n")
        guard parts.count > 1 else { return nil }
        let bodyParts = parts.dropFirst()
        for part in bodyParts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 100 && !trimmed.contains(" ") {
                return trimmed.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            }
        }
        return nil
    }
}
