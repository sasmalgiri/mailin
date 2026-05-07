import Foundation
import Security

struct SMIMEHandler {

    enum SignatureStatus: String, Codable {
        case valid = "Valid"
        case invalid = "Invalid"
        case unknownSigner = "Unknown Signer"
        case notSigned = "Not Signed"
        case error = "Error"
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
            return VerificationResult(status: .error, signerName: nil, signerEmail: nil, certificateInfo: nil)
        }

        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let cmsDecoder = decoder else {
            return VerificationResult(status: .error, signerName: nil, signerEmail: nil, certificateInfo: nil)
        }

        guard CMSDecoderUpdateMessage(cmsDecoder, (signedData as NSData).bytes, signedData.count) == errSecSuccess,
              CMSDecoderFinalizeMessage(cmsDecoder) == errSecSuccess else {
            return VerificationResult(status: .error, signerName: nil, signerEmail: nil, certificateInfo: nil)
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
            return VerificationResult(status: .error, signerName: nil, signerEmail: nil, certificateInfo: nil)
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

        var resultStatus: SignatureStatus
        switch signerStatus {
        case .valid:
            resultStatus = .valid
        case .needsDetachedContent:
            resultStatus = .invalid
        default:
            resultStatus = .unknownSigner
        }

        if let info = certInfo, info.isExpired {
            resultStatus = .invalid
        }

        return VerificationResult(status: resultStatus, signerName: signerName, signerEmail: signerEmail, certificateInfo: certInfo)
        #else
        return VerificationResult(status: .error, signerName: nil, signerEmail: nil, certificateInfo: nil)
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

        for i in 0..<(bytes.count - 13) {
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
