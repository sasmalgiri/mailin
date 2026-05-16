import Foundation
import CryptoKit
import SwiftUI
import os.log

private let forensicLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "Forensic")

@MainActor
class ForensicManager: ObservableObject {
    static let shared = ForensicManager()

    @AppStorage("forensicModeEnabled") var isEnabled = false
    @AppStorage("forensicCaseNumber") var caseNumber = ""
    @AppStorage("forensicExaminerName") var examinerName = ""
    @AppStorage("forensicOrganization") var organization = ""

    @Published var sourceFileHashes: [SourceFileHash] = []
    @Published private(set) var auditLog: [AuditEntry] = []
    @Published var evidenceTags: [UUID: EvidenceTag] = [:]
    @Published var tagTimestamps: [UUID: Date] = [:]
    @Published var annotations: [UUID: Annotation] = [:]
    @Published var perEmailHashes: [UUID: EmailHash] = [:]
    @Published var integrityStatus: IntegrityStatus = .unknown

    private static let hmacKeychainKey = "forensicHMACKey"

    private lazy var hmacKey: SymmetricKey = {
        let existing = KeychainHelper.load(key: Self.hmacKeychainKey)
        if !existing.isEmpty, let data = Data(base64Encoded: existing) {
            return SymmetricKey(data: data)
        }
        var keyBytes = [UInt8](repeating: 0, count: 32)
        var status = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
        if status != errSecSuccess {
            status = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
            if status != errSecSuccess {
                keyBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
            }
        }
        let keyData = Data(keyBytes)
        KeychainHelper.save(key: Self.hmacKeychainKey, value: keyData.base64EncodedString())
        return SymmetricKey(data: keyData)
    }()

    private var installID: String {
        if let existing = UserDefaults.standard.string(forKey: "forensicInstallID") {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: "forensicInstallID")
        return newID
    }

    // MARK: - Data Types

    private static let currentDataVersion = 1

    struct SourceFileHash: Identifiable, Codable, Sendable {
        let id: UUID
        let filename: String
        let fileSize: Int64
        let md5: String
        let sha1: String
        let sha256: String
        let importDate: Date
        let version: Int

        init(id: UUID, filename: String, fileSize: Int64, md5: String, sha1: String, sha256: String, importDate: Date) {
            self.id = id; self.filename = filename; self.fileSize = fileSize
            self.md5 = md5; self.sha1 = sha1; self.sha256 = sha256; self.importDate = importDate; self.version = 1
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            filename = try c.decode(String.self, forKey: .filename)
            fileSize = try c.decode(Int64.self, forKey: .fileSize)
            md5 = try c.decode(String.self, forKey: .md5)
            sha1 = try c.decode(String.self, forKey: .sha1)
            sha256 = try c.decode(String.self, forKey: .sha256)
            importDate = try c.decode(Date.self, forKey: .importDate)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        }
    }

    struct AuditEntry: Identifiable, Codable, Sendable {
        let id: UUID
        let sequence: Int
        let timestamp: Date
        let action: String
        let detail: String
        let examiner: String
        let previousHash: String
        let entryHash: String
        let version: Int

        init(id: UUID, sequence: Int, timestamp: Date, action: String, detail: String, examiner: String, previousHash: String, entryHash: String) {
            self.id = id; self.sequence = sequence; self.timestamp = timestamp
            self.action = action; self.detail = detail; self.examiner = examiner
            self.previousHash = previousHash; self.entryHash = entryHash; self.version = 1
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            sequence = try c.decode(Int.self, forKey: .sequence)
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            action = try c.decode(String.self, forKey: .action)
            detail = try c.decode(String.self, forKey: .detail)
            examiner = try c.decode(String.self, forKey: .examiner)
            previousHash = try c.decode(String.self, forKey: .previousHash)
            entryHash = try c.decode(String.self, forKey: .entryHash)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        }
    }

    struct EmailHash: Codable, Sendable {
        let md5: String
        let sha1: String
        let sha256: String
        let byteCount: Int
        let version: Int

        init(md5: String, sha1: String, sha256: String, byteCount: Int) {
            self.md5 = md5; self.sha1 = sha1; self.sha256 = sha256; self.byteCount = byteCount; self.version = 1
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            md5 = try c.decode(String.self, forKey: .md5)
            sha1 = try c.decode(String.self, forKey: .sha1)
            sha256 = try c.decode(String.self, forKey: .sha256)
            byteCount = try c.decode(Int.self, forKey: .byteCount)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        }
    }

    struct Annotation: Codable, Sendable {
        let text: String
        let examiner: String
        let timestamp: Date
        let version: Int

        init(text: String, examiner: String, timestamp: Date) {
            self.text = text; self.examiner = examiner; self.timestamp = timestamp; self.version = 1
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            examiner = try c.decode(String.self, forKey: .examiner)
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        }
    }

    enum IntegrityStatus: Equatable {
        case unknown
        case verified
        case tampered(details: String)
        case noData
    }

    enum EvidenceTag: String, CaseIterable, Codable {
        case none = "None"
        case relevant = "Relevant"
        case privileged = "Privileged"
        case irrelevant = "Irrelevant"
        case flagged = "Flagged"
        case suspicious = "Suspicious"

        var color: Color {
            switch self {
            case .none: return .secondary
            case .relevant: return .green
            case .privileged: return .orange
            case .irrelevant: return .gray
            case .flagged: return .red
            case .suspicious: return .purple
            }
        }

        var icon: String {
            switch self {
            case .none: return "tag"
            case .relevant: return "checkmark.seal.fill"
            case .privileged: return "lock.shield.fill"
            case .irrelevant: return "xmark.circle"
            case .flagged: return "flag.fill"
            case .suspicious: return "exclamationmark.triangle.fill"
            }
        }
    }

    // MARK: - File URLs

    private static let appSupportDir: URL = {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let auditLogURL = appSupportDir.appendingPathComponent("forensic_audit_log.json")
    private let hashesURL = appSupportDir.appendingPathComponent("forensic_hashes.json")
    private let tagsURL = appSupportDir.appendingPathComponent("forensic_tags.json")
    private let annotationsURL = appSupportDir.appendingPathComponent("forensic_annotations.json")
    private let emailHashesURL = appSupportDir.appendingPathComponent("forensic_email_hashes.json")
    private let chainRootURL = appSupportDir.appendingPathComponent("forensic_chain_root.txt")

    private init() {
        loadAuditLog()
        loadHashes()
        loadTags()
        loadAnnotations()
        loadEmailHashes()
    }

    // MARK: - HMAC-Chained Audit Log (Tamper-Evident)

    private func computeEntryHash(sequence: Int, timestamp: Date, action: String, detail: String, examiner: String, previousHash: String) -> String {
        let payload = "\(sequence)|\(timestamp.timeIntervalSince1970)|\(action)|\(detail)|\(examiner)|\(previousHash)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: hmacKey)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    func logAction(_ action: String, detail: String) {
        guard isEnabled else { return }
        let sequence = auditLog.count
        let previousHash = auditLog.last?.entryHash ?? "GENESIS"
        let examiner = examinerName.isEmpty ? "Unknown" : examinerName
        let timestamp = Date()

        let entryHash = computeEntryHash(
            sequence: sequence,
            timestamp: timestamp,
            action: action,
            detail: detail,
            examiner: examiner,
            previousHash: previousHash
        )

        let entry = AuditEntry(
            id: UUID(),
            sequence: sequence,
            timestamp: timestamp,
            action: action,
            detail: detail,
            examiner: examiner,
            previousHash: previousHash,
            entryHash: entryHash
        )
        auditLog.append(entry)
        saveAuditLog()
        saveChainRoot()
    }

    func verifyAuditLogIntegrity() -> IntegrityStatus {
        guard !auditLog.isEmpty else {
            integrityStatus = .noData
            return .noData
        }

        for (index, entry) in auditLog.enumerated() {
            let expectedPrevious = index == 0 ? "GENESIS" : auditLog[index - 1].entryHash
            if entry.previousHash != expectedPrevious {
                let msg = "Chain break at entry \(index): expected previous hash \(expectedPrevious.prefix(16))..., found \(entry.previousHash.prefix(16))..."
                integrityStatus = .tampered(details: msg)
                return integrityStatus
            }

            let recomputed = computeEntryHash(
                sequence: entry.sequence,
                timestamp: entry.timestamp,
                action: entry.action,
                detail: entry.detail,
                examiner: entry.examiner,
                previousHash: entry.previousHash
            )
            if recomputed != entry.entryHash {
                let msg = "Hash mismatch at entry \(index) (\(entry.action)): entry has been modified"
                integrityStatus = .tampered(details: msg)
                return integrityStatus
            }

            if entry.sequence != index {
                let msg = "Sequence gap at entry \(index): expected \(index), found \(entry.sequence)"
                integrityStatus = .tampered(details: msg)
                return integrityStatus
            }
        }

        if let storedRoot = try? String(contentsOf: chainRootURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let lastHash = auditLog.last?.entryHash,
           storedRoot != lastHash {
            integrityStatus = .tampered(details: "Chain root mismatch: log was modified outside the application")
            return integrityStatus
        }

        integrityStatus = .verified
        return .verified
    }

    private func saveChainRoot() {
        guard let lastHash = auditLog.last?.entryHash else { return }
        try? lastHash.write(to: chainRootURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Hash Computation (MD5 + SHA-1 + SHA-256)

    nonisolated static func computeHashes(for url: URL) -> SourceFileHash? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sha1 = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? Int64(data.count)
        return SourceFileHash(
            id: UUID(),
            filename: url.lastPathComponent,
            fileSize: size,
            md5: md5,
            sha1: sha1,
            sha256: sha256,
            importDate: Date()
        )
    }

    nonisolated static func computeEmailHash(rawSource: String) -> EmailHash {
        guard !rawSource.isEmpty else {
            return EmailHash(md5: "", sha1: "", sha256: "", byteCount: 0)
        }
        let data = rawSource.data(using: .utf8) ?? rawSource.data(using: .isoLatin1) ?? Data(rawSource.utf8)
        return EmailHash(
            md5: Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            sha1: Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: data.count
        )
    }

    func registerFileHash(_ hash: SourceFileHash) {
        sourceFileHashes.append(hash)
        saveHashes()
        logAction("File Imported", detail: "\(hash.filename) (\(hash.fileSize) bytes) — SHA-256: \(hash.sha256)")
    }

    func verifySourceFile(at url: URL) -> (passed: Bool, detail: String) {
        guard let stored = sourceFileHashes.first(where: { $0.filename == url.lastPathComponent }) else {
            return (false, "No stored hash for \(url.lastPathComponent)")
        }
        guard let current = Self.computeHashes(for: url) else {
            return (false, "Could not read file \(url.lastPathComponent)")
        }
        if current.sha256 != stored.sha256 {
            return (false, "SHA-256 MISMATCH for \(url.lastPathComponent). Original: \(stored.sha256.prefix(16))... Current: \(current.sha256.prefix(16))...")
        }
        if current.md5 != stored.md5 {
            return (false, "MD5 MISMATCH for \(url.lastPathComponent)")
        }
        return (true, "Integrity verified: \(url.lastPathComponent)")
    }

    func storeEmailHashes(_ emails: [MBOXParser.RawEmail]) {
        for email in emails {
            if perEmailHashes[email.id] == nil {
                perEmailHashes[email.id] = Self.computeEmailHash(rawSource: email.rawSource)
            }
        }
        saveEmailHashes()
    }

    func verifyEmailIntegrity(_ email: MBOXParser.RawEmail) -> (passed: Bool, detail: String) {
        guard let stored = perEmailHashes[email.id] else {
            return (false, "No stored hash for this email")
        }
        let current = Self.computeEmailHash(rawSource: email.rawSource)
        if current.sha256 != stored.sha256 {
            return (false, "Email content has been modified since import")
        }
        return (true, "Email integrity verified (SHA-256 match)")
    }

    func batchVerifyAllEmails(_ emails: [MBOXParser.RawEmail]) -> (passed: Int, failed: Int, unverified: Int, details: [String]) {
        var passed = 0, failed = 0, unverified = 0
        var details: [String] = []
        for email in emails {
            let result = verifyEmailIntegrity(email)
            if perEmailHashes[email.id] == nil {
                unverified += 1
            } else if result.passed {
                passed += 1
            } else {
                failed += 1
                details.append("FAILED: \(email.headers["Subject"] ?? "Unknown") — \(result.detail)")
            }
        }
        logAction("Batch Verification", detail: "\(passed) passed, \(failed) failed, \(unverified) unverified")
        return (passed, failed, unverified, details)
    }

    func exportHashManifest(_ emails: [MBOXParser.RawEmail]) -> String {
        var csv = "EmailID,Subject,From,Date,MD5,SHA1,SHA256,Integrity\n"
        for email in emails {
            let hash = perEmailHashes[email.id]
            let verification = verifyEmailIntegrity(email)
            let subject = (email.headers["Subject"] ?? "").replacingOccurrences(of: ",", with: ";")
            let from = (email.headers["From"] ?? "").replacingOccurrences(of: ",", with: ";")
            csv += "\(email.id),\"\(subject)\",\"\(from)\",\(email.timestamp),\(hash?.md5 ?? "N/A"),\(hash?.sha1 ?? "N/A"),\(hash?.sha256 ?? "N/A"),\(verification.passed ? "PASS" : "FAIL")\n"
        }
        return csv
    }

    // MARK: - Evidence Tagging

    func tag(_ emailID: UUID, as tag: EvidenceTag) {
        if tag == .none {
            evidenceTags.removeValue(forKey: emailID)
            tagTimestamps.removeValue(forKey: emailID)
        } else {
            evidenceTags[emailID] = tag
            tagTimestamps[emailID] = Date()
        }
        saveTags()
        logAction("Evidence Tagged", detail: "Email \(emailID.uuidString.prefix(8)) tagged as \(tag.rawValue)")
        CollaborationManager.shared.autoExportIfEnabled()
    }

    func bulkTag(_ emailIDs: Set<UUID>, as tag: EvidenceTag) {
        let now = Date()
        for id in emailIDs {
            if tag == .none {
                evidenceTags.removeValue(forKey: id)
                tagTimestamps.removeValue(forKey: id)
            } else {
                evidenceTags[id] = tag
                tagTimestamps[id] = now
            }
        }
        saveTags()
        logAction("Bulk Evidence Tag", detail: "\(emailIDs.count) emails tagged as \(tag.rawValue)")
        CollaborationManager.shared.autoExportIfEnabled()
    }

    func tagForEmail(_ emailID: UUID) -> EvidenceTag {
        evidenceTags[emailID] ?? .none
    }

    func taggedCount(for tag: EvidenceTag) -> Int {
        evidenceTags.values.filter { $0 == tag }.count
    }

    func emailIDs(withTag tag: EvidenceTag) -> Set<UUID> {
        Set(evidenceTags.filter { $0.value == tag }.keys)
    }

    // MARK: - Annotations

    func annotate(_ emailID: UUID, text: String) {
        annotations[emailID] = Annotation(
            text: text,
            examiner: examinerName.isEmpty ? "Unknown" : examinerName,
            timestamp: Date()
        )
        saveAnnotations()
        logAction("Annotation", detail: "Email \(emailID.uuidString.prefix(8)): \(text.prefix(80))")
        CollaborationManager.shared.autoExportIfEnabled()
    }

    func annotationFor(_ emailID: UUID) -> Annotation? {
        annotations[emailID]
    }

    // MARK: - Email Header Forensics

    struct ReceivedHop: Identifiable {
        let id = UUID()
        let from: String
        let by: String
        let with: String
        let date: String
        let ip: String?
        let ipv6: String?
        let authInfo: String?
        let raw: String
    }

    nonisolated static func parseReceivedChain(_ email: MBOXParser.RawEmail) -> [ReceivedHop] {
        let receivedHeaders = email.rawSource.components(separatedBy: "\n")
            .reduce(into: [String]()) { result, line in
                if line.lowercased().hasPrefix("received:") {
                    result.append(line)
                } else if !result.isEmpty, (line.hasPrefix(" ") || line.hasPrefix("\t")) {
                    result[result.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
                }
            }

        return receivedHeaders.map { raw in
            let cleaned = raw.replacingOccurrences(of: "Received:", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)

            let fromMatch = cleaned.range(of: #"from\s+(\S+)"#, options: .regularExpression).flatMap { String(cleaned[$0]) } ?? ""
            let byMatch = cleaned.range(of: #"by\s+(\S+)"#, options: .regularExpression).flatMap { String(cleaned[$0]) } ?? ""
            let withMatch = cleaned.range(of: #"with\s+(\S+)"#, options: .regularExpression).flatMap { String(cleaned[$0]) } ?? ""

            let ipv4Pattern = #"\[(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\]"#
            let ip: String?
            if let ipRange = cleaned.range(of: ipv4Pattern, options: .regularExpression) {
                ip = String(cleaned[ipRange]).replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            } else {
                ip = nil
            }

            let ipv6Pattern = #"\[IPv6:([a-fA-F0-9:]+)\]"#
            let ipv6: String?
            if let range = cleaned.range(of: ipv6Pattern, options: .regularExpression) {
                ipv6 = String(cleaned[range]).replacingOccurrences(of: "[IPv6:", with: "").replacingOccurrences(of: "]", with: "")
            } else {
                ipv6 = nil
            }

            let authPattern = #"auth=(\S+)"#
            let authInfo: String?
            if let range = cleaned.range(of: authPattern, options: .regularExpression) {
                authInfo = String(cleaned[range])
            } else {
                authInfo = nil
            }

            let datePattern = #";(.+)$"#
            let date: String
            if let dateRange = cleaned.range(of: datePattern, options: .regularExpression) {
                date = String(cleaned[dateRange]).replacingOccurrences(of: ";", with: "").trimmingCharacters(in: .whitespaces)
            } else {
                date = ""
            }

            return ReceivedHop(from: fromMatch, by: byMatch, with: withMatch, date: date, ip: ip, ipv6: ipv6, authInfo: authInfo, raw: raw)
        }
    }

    nonisolated static func extractAuthResults(_ email: MBOXParser.RawEmail) -> (spf: String, dkim: String, dmarc: String) {
        let authHeader = email.headers["Authentication-Results"] ?? email.headers["authentication-results"] ?? ""
        let spf = authHeader.range(of: #"spf=(\w+)"#, options: .regularExpression).map { String(authHeader[$0]).replacingOccurrences(of: "spf=", with: "") } ?? "N/A"
        let dkim = authHeader.range(of: #"dkim=(\w+)"#, options: .regularExpression).map { String(authHeader[$0]).replacingOccurrences(of: "dkim=", with: "") } ?? "N/A"
        let dmarc = authHeader.range(of: #"dmarc=(\w+)"#, options: .regularExpression).map { String(authHeader[$0]).replacingOccurrences(of: "dmarc=", with: "") } ?? "N/A"
        return (spf, dkim, dmarc)
    }

    // MARK: - Spoofing Detection

    struct SpoofIndicator: Identifiable {
        let id = UUID()
        let severity: SpoofSeverity
        let type: String
        let detail: String
    }

    enum SpoofSeverity: String {
        case high = "High"
        case medium = "Medium"
        case low = "Low"

        var color: Color {
            switch self {
            case .high: return .red
            case .medium: return .orange
            case .low: return .yellow
            }
        }
    }

    nonisolated static func detectSpoofingIndicators(_ email: MBOXParser.RawEmail) -> [SpoofIndicator] {
        var indicators: [SpoofIndicator] = []

        let from = email.headers["From"] ?? ""
        let returnPath = email.headers["Return-Path"] ?? email.headers["return-path"] ?? ""
        let replyTo = email.headers["Reply-To"] ?? ""

        let extractDomain: (String) -> String? = { addr in
            guard let atIndex = addr.lastIndex(of: "@") else { return nil }
            let afterAt = addr[addr.index(after: atIndex)...]
            return afterAt.trimmingCharacters(in: CharacterSet(charactersIn: "> \t\r\n")).lowercased()
        }

        let fromDomain = extractDomain(from)
        let returnPathDomain = extractDomain(returnPath)
        let replyToDomain = extractDomain(replyTo)

        if let fd = fromDomain, let rpd = returnPathDomain, !returnPath.isEmpty, fd != rpd {
            indicators.append(SpoofIndicator(severity: .high, type: "Return-Path Mismatch", detail: "From domain: \(fd), Return-Path domain: \(rpd)"))
        }

        if let fd = fromDomain, let rtd = replyToDomain, !replyTo.isEmpty, fd != rtd {
            indicators.append(SpoofIndicator(severity: .medium, type: "Reply-To Mismatch", detail: "From domain: \(fd), Reply-To domain: \(rtd)"))
        }

        let auth = extractAuthResults(email)
        if auth.spf == "fail" {
            indicators.append(SpoofIndicator(severity: .high, type: "SPF Fail", detail: "Sender not authorized by domain's SPF record"))
        }
        if auth.dkim == "fail" {
            indicators.append(SpoofIndicator(severity: .high, type: "DKIM Fail", detail: "Email signature verification failed"))
        }
        if auth.dmarc == "fail" {
            indicators.append(SpoofIndicator(severity: .high, type: "DMARC Fail", detail: "Domain-based message authentication failed"))
        }

        if let fd = fromDomain {
            let homoglyphs: [(String, String)] = [
                ("rn", "m"), ("cl", "d"), ("vv", "w"),
                ("0", "O"), ("1", "l"), ("nn", "m")
            ]
            let knownSafeDomains: Set<String> = ["gmail.com", "yahoo.com", "outlook.com", "hotmail.com", "icloud.com", "aol.com", "protonmail.com"]
            if !knownSafeDomains.contains(fd) {
                let domainName = fd.components(separatedBy: ".").first ?? fd
                for (fake, real) in homoglyphs {
                    if domainName.contains(fake) {
                        let replaced = domainName.replacingOccurrences(of: fake, with: real)
                        if replaced != domainName && replaced.count >= 3 {
                            indicators.append(SpoofIndicator(severity: .high, type: "Homoglyph Domain", detail: "Domain '\(fd)' may be impersonating '\(replaced)' (look-alike characters)"))
                        }
                    }
                }
            }

            let knownDomains = ["gmail.com", "yahoo.com", "outlook.com", "hotmail.com", "icloud.com", "aol.com", "protonmail.com"]
            for known in knownDomains {
                if fd != known && fd.contains(known.replacingOccurrences(of: ".com", with: "")) && !fd.hasSuffix(".\(known)") {
                    indicators.append(SpoofIndicator(severity: .medium, type: "Subdomain Spoof", detail: "Domain '\(fd)' contains '\(known)' as substring — possible impersonation"))
                }
            }
        }

        let xOrigIP = email.headers["X-Originating-IP"] ?? ""
        if !xOrigIP.isEmpty {
            let cleaned = xOrigIP.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            if cleaned.hasPrefix("10.") || cleaned.hasPrefix("192.168.") || cleaned.hasPrefix("172.") {
                indicators.append(SpoofIndicator(severity: .low, type: "Private IP Origin", detail: "X-Originating-IP is a private address: \(cleaned)"))
            }
        }

        let receivedCount = parseReceivedChain(email).count
        if receivedCount == 0 {
            indicators.append(SpoofIndicator(severity: .medium, type: "No Received Headers", detail: "Missing Received chain — email may have been injected directly"))
        }

        return indicators
    }

    // MARK: - Email Risk Score (0–100)

    struct RiskAssessment {
        let score: Int
        let level: RiskLevel
        let factors: [String]

        enum RiskLevel: String {
            case safe = "Safe"
            case low = "Low Risk"
            case medium = "Medium Risk"
            case high = "High Risk"
            case critical = "Critical"

            var color: Color {
                switch self {
                case .safe: return .green
                case .low: return .blue
                case .medium: return .yellow
                case .high: return .orange
                case .critical: return .red
                }
            }

            var icon: String {
                switch self {
                case .safe: return "checkmark.shield.fill"
                case .low: return "shield.fill"
                case .medium: return "exclamationmark.shield.fill"
                case .high: return "exclamationmark.triangle.fill"
                case .critical: return "xmark.shield.fill"
                }
            }
        }
    }

    nonisolated static func assessRisk(for email: MBOXParser.RawEmail) -> RiskAssessment {
        var score = 0
        var factors: [String] = []

        let indicators = detectSpoofingIndicators(email)
        let highCount = indicators.filter { $0.severity == .high }.count
        let medCount = indicators.filter { $0.severity == .medium }.count
        let lowCount = indicators.filter { $0.severity == .low }.count

        score += highCount * 25
        score += medCount * 10
        score += lowCount * 3

        if highCount > 0 {
            factors.append("\(highCount) high-severity spoofing indicator(s)")
        }
        if medCount > 0 {
            factors.append("\(medCount) medium-severity indicator(s)")
        }

        let auth = extractAuthResults(email)
        if auth.spf == "fail" { score += 15; factors.append("SPF authentication failed") }
        if auth.dkim == "fail" { score += 15; factors.append("DKIM verification failed") }
        if auth.dmarc == "fail" { score += 15; factors.append("DMARC policy failed") }

        let piiFindings = EmailNLPEngine.detectPII(in: [email])
        let ssnCount = piiFindings.filter { $0.type == .ssnPattern }.count
        let ccCount = piiFindings.filter { $0.type == .creditCard }.count
        if ssnCount > 0 { score += 10; factors.append("\(ssnCount) SSN pattern(s) found") }
        if ccCount > 0 { score += 10; factors.append("\(ccCount) credit card pattern(s) found") }

        if !email.anomalies.isEmpty {
            score += email.anomalies.count * 5
            factors.append("\(email.anomalies.count) anomaly/anomalies detected")
        }

        let hops = parseReceivedChain(email)
        if hops.count > 8 {
            score += 5
            factors.append("Unusually long routing chain (\(hops.count) hops)")
        }

        let body = email.plainBody.lowercased()
        let urgencyPhrases = ["urgent action required", "verify your account", "suspended",
                              "click here immediately", "act now or", "your account will be"]
        let matchedPhrases = urgencyPhrases.filter { body.contains($0) }
        if !matchedPhrases.isEmpty {
            score += matchedPhrases.count * 8
            factors.append("Suspicious urgency language detected")
        }

        score = min(score, 100)

        let level: RiskAssessment.RiskLevel
        switch score {
        case 0..<10: level = .safe
        case 10..<30: level = .low
        case 30..<55: level = .medium
        case 55..<80: level = .high
        default: level = .critical
        }

        if factors.isEmpty { factors.append("No risk indicators detected") }
        return RiskAssessment(score: score, level: level, factors: factors)
    }

    // MARK: - MIME Tree

    static func buildMIMETree(_ email: MBOXParser.RawEmail) -> [MIMETreeNode] {
        guard let root = email.mimeRoot else {
            return [MIMETreeNode(contentType: email.headers["Content-Type"] ?? "text/plain", filename: nil, size: email.plainBody.utf8.count, children: [])]
        }
        return [buildNode(from: root)]
    }

    struct MIMETreeNode: Identifiable {
        let id = UUID()
        let contentType: String
        let filename: String?
        let size: Int
        let children: [MIMETreeNode]
    }

    private static func buildNode(from part: MIMEPart) -> MIMETreeNode {
        let children = part.subparts.map { buildNode(from: $0) }
        return MIMETreeNode(
            contentType: part.mimeType,
            filename: part.filename,
            size: part.rawData?.count ?? part.body.utf8.count,
            children: children
        )
    }

    // MARK: - Forensic Export Helpers

    static func batesNumber(prefix: String, index: Int, padding: Int = 6) -> String {
        "\(prefix)\(String(format: "%0\(padding)d", index))"
    }

    func exportAuditLog() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        var report = "FORENSIC AUDIT LOG (TAMPER-EVIDENT)\n"
        report += String(repeating: "=", count: 76) + "\n"
        report += "Case Number: \(caseNumber.isEmpty ? "N/A" : caseNumber)\n"
        report += "Examiner: \(examinerName.isEmpty ? "N/A" : examinerName)\n"
        report += "Organization: \(organization.isEmpty ? "N/A" : organization)\n"
        report += "Export Date: \(displayFormatter.string(from: Date()))\n"
        report += "Total Entries: \(auditLog.count)\n"

        let integrity = verifyAuditLogIntegrity()
        switch integrity {
        case .verified:
            report += "Chain Integrity: VERIFIED (all \(auditLog.count) entries pass HMAC-SHA256 verification)\n"
        case .tampered(let details):
            report += "Chain Integrity: FAILED — \(details)\n"
        case .noData:
            report += "Chain Integrity: N/A (empty log)\n"
        case .unknown:
            report += "Chain Integrity: NOT CHECKED\n"
        }
        report += String(repeating: "=", count: 76) + "\n\n"

        if !sourceFileHashes.isEmpty {
            report += "SOURCE FILE INTEGRITY\n"
            report += String(repeating: "-", count: 76) + "\n"
            for hash in sourceFileHashes {
                report += "File: \(hash.filename)\n"
                report += "  Size: \(hash.fileSize) bytes\n"
                report += "  MD5:    \(hash.md5)\n"
                report += "  SHA-1:  \(hash.sha1)\n"
                report += "  SHA-256: \(hash.sha256)\n"
                report += "  Import Date: \(displayFormatter.string(from: hash.importDate))\n\n"
            }
        }

        report += "HMAC-CHAINED ACTION LOG\n"
        report += String(repeating: "-", count: 76) + "\n"
        for entry in auditLog {
            report += "#\(entry.sequence) [\(displayFormatter.string(from: entry.timestamp))] \(entry.action)\n"
            report += "  Detail: \(entry.detail)\n"
            report += "  Examiner: \(entry.examiner)\n"
            report += "  HMAC: \(entry.entryHash)\n"
            report += "  Prev: \(entry.previousHash.prefix(32))...\n\n"
        }

        report += String(repeating: "=", count: 76) + "\n"
        report += "END OF AUDIT LOG\n"
        report += "Final chain hash: \(auditLog.last?.entryHash ?? "N/A")\n\n"
        report += String(repeating: "-", count: 76) + "\n"
        report += "DISCLAIMER: " + LegalComplianceManager.forensicDisclaimer + "\n"
        return report
    }

    func exportBulkForensicCSV(emails: [MBOXParser.RawEmail], batesPrefix: String = "MAIL") -> String {
        var csv = "Bates Number,Message-ID,Date,From,To,CC,Subject,MD5,SHA-1,SHA-256,Byte Count,Has Attachments,Attachment Count,Evidence Tag,Annotation,Thread-ID,Spoof Risk,Risk Score,Risk Level\n"

        func csvEscape(_ s: String) -> String {
            var v = s
            if let first = v.first, "=+@-\t\r".contains(first) { v = "'" + v }
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"").replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") + "\""
        }

        for (i, email) in emails.enumerated() {
            let bates = Self.batesNumber(prefix: batesPrefix, index: i + 1)
            let hash = perEmailHashes[email.id] ?? Self.computeEmailHash(rawSource: email.rawSource)
            let tag = tagForEmail(email.id).rawValue
            let note = annotations[email.id]?.text ?? ""
            let spoofCount = Self.detectSpoofingIndicators(email).count
            let cc = email.headers["Cc"] ?? email.headers["CC"] ?? ""

            csv += "\(bates),"
            csv += "\(csvEscape(email.headers["Message-ID"] ?? email.headers["Message-Id"] ?? "")),"
            csv += "\(csvEscape(email.headers["Date"] ?? "")),"
            csv += "\(csvEscape(email.headers["From"] ?? "")),"
            csv += "\(csvEscape(email.headers["To"] ?? "")),"
            csv += "\(csvEscape(cc)),"
            csv += "\(csvEscape(email.headers["Subject"] ?? "")),"
            csv += "\(hash.md5),"
            csv += "\(hash.sha1),"
            csv += "\(hash.sha256),"
            csv += "\(hash.byteCount),"
            csv += "\(!email.attachments.isEmpty),"
            csv += "\(email.attachments.count),"
            csv += "\(csvEscape(tag)),"
            csv += "\(csvEscape(note)),"
            csv += "\(csvEscape(email.threadID ?? "")),"
            csv += "\(spoofCount),"
            let risk = Self.assessRisk(for: email)
            csv += "\(risk.score),"
            csv += "\(csvEscape(risk.level.rawValue))\n"
        }
        return csv
    }

    func exportConcordanceDAT(emails: [MBOXParser.RawEmail], batesPrefix: String = "MAIL") -> String {
        let sep = "\u{14}"
        let quote = "\u{FE}"
        var dat = "\(quote)DOCID\(quote)\(sep)\(quote)BEGBATES\(quote)\(sep)\(quote)ENDBATES\(quote)\(sep)\(quote)FROM\(quote)\(sep)\(quote)TO\(quote)\(sep)\(quote)CC\(quote)\(sep)\(quote)BCC\(quote)\(sep)\(quote)SUBJECT\(quote)\(sep)\(quote)DATESENT\(quote)\(sep)\(quote)MSGID\(quote)\(sep)\(quote)HASHSHA256\(quote)\(sep)\(quote)CUSTODIAN\(quote)\(sep)\(quote)TAG\(quote)\n"

        for (i, email) in emails.enumerated() {
            let bates = Self.batesNumber(prefix: batesPrefix, index: i + 1)
            let hash = perEmailHashes[email.id] ?? Self.computeEmailHash(rawSource: email.rawSource)
            let tag = tagForEmail(email.id).rawValue
            let cc = email.headers["Cc"] ?? email.headers["CC"] ?? ""
            let bcc = email.headers["Bcc"] ?? email.headers["BCC"] ?? ""

            func datEscape(_ s: String) -> String {
                s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "")
            }

            dat += "\(quote)\(bates)\(quote)\(sep)"
            dat += "\(quote)\(bates)\(quote)\(sep)"
            dat += "\(quote)\(bates)\(quote)\(sep)"
            dat += "\(quote)\(datEscape(email.headers["From"] ?? ""))\(quote)\(sep)"
            dat += "\(quote)\(datEscape(email.headers["To"] ?? ""))\(quote)\(sep)"
            dat += "\(quote)\(datEscape(cc))\(quote)\(sep)"
            dat += "\(quote)\(datEscape(bcc))\(quote)\(sep)"
            dat += "\(quote)\(datEscape(email.headers["Subject"] ?? ""))\(quote)\(sep)"
            dat += "\(quote)\(datEscape(email.headers["Date"] ?? ""))\(quote)\(sep)"
            dat += "\(quote)\(datEscape(email.headers["Message-ID"] ?? ""))\(quote)\(sep)"
            dat += "\(quote)\(hash.sha256)\(quote)\(sep)"
            dat += "\(quote)\(datEscape(examinerName))\(quote)\(sep)"
            dat += "\(quote)\(tag)\(quote)\n"
        }
        return dat
    }

    func exportPrivilegeLog(emails: [MBOXParser.RawEmail]) -> String {
        let privileged = emails.filter { evidenceTags[$0.id] == .privileged }
        guard !privileged.isEmpty else { return "" }

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var log = "PRIVILEGE LOG\n"
        log += String(repeating: "=", count: 76) + "\n"
        log += "Case Number: \(caseNumber.isEmpty ? "N/A" : caseNumber)\n"
        log += "Prepared by: \(examinerName.isEmpty ? "N/A" : examinerName)\n"
        log += "Date: \(displayFormatter.string(from: Date()))\n"
        log += "Total Privileged Documents: \(privileged.count)\n\n"

        log += String(format: "%-8s %-12s %-30s %-30s %s\n", "No.", "Date", "From", "To", "Subject")
        log += String(repeating: "-", count: 120) + "\n"

        for (i, email) in privileged.enumerated() {
            let date = email.headers["Date"] ?? "N/A"
            let from = String((email.headers["From"] ?? "N/A").prefix(28))
            let to = String((email.headers["To"] ?? "N/A").prefix(28))
            let subject = String((email.headers["Subject"] ?? "N/A").prefix(50))

            log += String(format: "%-8d %-12s %-30s %-30s %s\n",
                          i + 1,
                          String(date),
                          from,
                          to,
                          subject)

            if let annotation = annotations[email.id] {
                log += "         Basis: \(annotation.text)\n"
            }
        }

        log += "\n" + String(repeating: "=", count: 76) + "\n"
        log += "END OF PRIVILEGE LOG\n\n"
        log += "DISCLAIMER: " + LegalComplianceManager.forensicDisclaimer + "\n"
        return log
    }

    // MARK: - Persistence

    private func saveAuditLog() {
        do {
            let data = try JSONEncoder().encode(auditLog)
            try data.write(to: auditLogURL, options: .atomic)
        } catch {
            forensicLog.error("Failed to save audit log: \(error.localizedDescription)")
        }
    }

    private func loadAuditLog() {
        guard FileManager.default.fileExists(atPath: auditLogURL.path) else { return }
        do {
            let data = try Data(contentsOf: auditLogURL)
            auditLog = try JSONDecoder().decode([AuditEntry].self, from: data)
            if !auditLog.isEmpty {
                _ = verifyAuditLogIntegrity()
            }
        } catch {
            forensicLog.error("Failed to decode audit log: \(error.localizedDescription)")
        }
    }

    private func saveHashes() {
        do {
            let data = try JSONEncoder().encode(sourceFileHashes)
            try data.write(to: hashesURL, options: .atomic)
        } catch {
            forensicLog.error("Failed to save hashes: \(error.localizedDescription)")
        }
    }

    private func loadHashes() {
        guard FileManager.default.fileExists(atPath: hashesURL.path) else { return }
        do {
            let data = try Data(contentsOf: hashesURL)
            sourceFileHashes = try JSONDecoder().decode([SourceFileHash].self, from: data)
        } catch {
            forensicLog.error("Failed to decode hashes: \(error.localizedDescription)")
        }
    }

    private func saveTags() {
        do {
            let dict = evidenceTags.map { (key: $0.key.uuidString, value: $0.value.rawValue) }
            let data = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: dict))
            try data.write(to: tagsURL, options: .atomic)
        } catch {
            forensicLog.error("Failed to save tags: \(error.localizedDescription)")
        }

        do {
            let tsDict = tagTimestamps.reduce(into: [String: Double]()) { $0[$1.key.uuidString] = $1.value.timeIntervalSince1970 }
            let tsData = try JSONEncoder().encode(tsDict)
            try tsData.write(to: tagsURL.deletingLastPathComponent().appendingPathComponent("forensic_tag_timestamps.json"), options: .atomic)
        } catch {
            forensicLog.error("Failed to save tag timestamps: \(error.localizedDescription)")
        }
    }

    private func loadTags() {
        if FileManager.default.fileExists(atPath: tagsURL.path) {
            do {
                let data = try Data(contentsOf: tagsURL)
                let dict = try JSONDecoder().decode([String: String].self, from: data)
                for (key, value) in dict {
                    if let uuid = UUID(uuidString: key), let tag = EvidenceTag(rawValue: value) {
                        evidenceTags[uuid] = tag
                    }
                }
            } catch {
                forensicLog.error("Failed to decode tags: \(error.localizedDescription)")
            }
        }

        let tsURL = tagsURL.deletingLastPathComponent().appendingPathComponent("forensic_tag_timestamps.json")
        if FileManager.default.fileExists(atPath: tsURL.path) {
            do {
                let tsData = try Data(contentsOf: tsURL)
                let tsDict = try JSONDecoder().decode([String: Double].self, from: tsData)
                for (key, ts) in tsDict {
                    if let uuid = UUID(uuidString: key) {
                        tagTimestamps[uuid] = Date(timeIntervalSince1970: ts)
                    }
                }
            } catch {
                forensicLog.error("Failed to decode tag timestamps: \(error.localizedDescription)")
            }
        }
    }

    private func saveAnnotations() {
        do {
            let dict = annotations.reduce(into: [String: Annotation]()) { $0[$1.key.uuidString] = $1.value }
            let data = try JSONEncoder().encode(dict)
            try data.write(to: annotationsURL, options: .atomic)
        } catch {
            forensicLog.error("Failed to save annotations: \(error.localizedDescription)")
        }
    }

    private func loadAnnotations() {
        guard FileManager.default.fileExists(atPath: annotationsURL.path) else { return }
        do {
            let data = try Data(contentsOf: annotationsURL)
            let dict = try JSONDecoder().decode([String: Annotation].self, from: data)
            for (key, value) in dict {
                if let uuid = UUID(uuidString: key) {
                    annotations[uuid] = value
                }
            }
        } catch {
            forensicLog.error("Failed to decode annotations: \(error.localizedDescription)")
        }
    }

    private func saveEmailHashes() {
        do {
            let dict = perEmailHashes.reduce(into: [String: EmailHash]()) { $0[$1.key.uuidString] = $1.value }
            let data = try JSONEncoder().encode(dict)
            try data.write(to: emailHashesURL, options: .atomic)
        } catch {
            forensicLog.error("Failed to save email hashes: \(error.localizedDescription)")
        }
    }

    private func loadEmailHashes() {
        guard FileManager.default.fileExists(atPath: emailHashesURL.path) else { return }
        do {
            let data = try Data(contentsOf: emailHashesURL)
            let dict = try JSONDecoder().decode([String: EmailHash].self, from: data)
            for (key, value) in dict {
                if let uuid = UUID(uuidString: key) {
                    perEmailHashes[uuid] = value
                }
            }
        } catch {
            forensicLog.error("Failed to decode email hashes: \(error.localizedDescription)")
        }
    }

    func clearForensicData() {
        let tsURL = tagsURL.deletingLastPathComponent().appendingPathComponent("forensic_tag_timestamps.json")
        for url in [auditLogURL, hashesURL, tagsURL, annotationsURL, emailHashesURL, chainRootURL, tsURL] {
            try? FileManager.default.removeItem(at: url)
        }
        auditLog = []
        sourceFileHashes = []
        evidenceTags = [:]
        tagTimestamps = [:]
        annotations = [:]
        perEmailHashes = [:]
        integrityStatus = .unknown
    }

    func clearAllForensicData() {
        clearForensicData()
        isEnabled = false
        caseNumber = ""
        examinerName = ""
        organization = ""
    }
}
