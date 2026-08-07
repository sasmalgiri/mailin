//
//  EncryptedStorageManager.swift
//  mailin
//
//  Encrypted at-rest storage for sensitive email archive data using AES-GCM.
//

import Foundation
import CryptoKit
import Security

class EncryptedStorageManager {
    static let shared = EncryptedStorageManager()

    // MARK: - Constants

    private let keychainTag = "com.ecosanskriti.mailin.encryptionKey"
    private let archiveExtension = "mailinarchive"
    private let metadataExtension = "mailinmeta"

    // MARK: - Serializable Email

    /// Lightweight Codable wrapper for RawEmail to enable JSON serialization.
    struct SerializableEmail: Codable {
        let id: UUID
        let headers: [String: String]
        let plainBody: String
        let htmlBody: String
        let rawSourceSnippet: String
        let messageType: String
        let attachments: [AttachmentMetadata]
        let timestamp: String
        let tags: [String]
        let anomalies: [String]

        init(from email: MBOXParser.RawEmail) {
            self.id = email.id
            self.headers = email.headers
            self.plainBody = email.plainBody
            self.htmlBody = email.htmlBody
            let maxSnippetLength = 2000
            if email.rawSource.count > maxSnippetLength {
                self.rawSourceSnippet = String(email.rawSource.prefix(maxSnippetLength))
            } else {
                self.rawSourceSnippet = email.rawSource
            }
            self.messageType = email.messageType
            self.attachments = email.attachments
            self.timestamp = email.timestamp
            self.tags = email.tags
            self.anomalies = email.anomalies
        }

        func toRawEmail() -> MBOXParser.RawEmail {
            MBOXParser.RawEmail(
                id: id,
                headers: headers,
                rawSource: rawSourceSnippet,
                messageType: messageType,
                attachments: attachments,
                timestamp: timestamp,
                domains: extractDomains(),
                plainBody: plainBody,
                htmlBody: htmlBody,
                mimeRoot: nil,
                mimeSummary: nil,
                mimeDiagnostics: [],
                threadID: headers["Message-ID"],
                inReplyTo: headers["In-Reply-To"],
                references: headers["References"]?.components(separatedBy: " ").filter { !$0.isEmpty },
                tags: tags,
                anomalies: anomalies
            )
        }

        private func extractDomains() -> [String] {
            var domains: [String] = []
            for key in ["From", "To", "Cc"] {
                if let value = headers[key] {
                    let parts = value.components(separatedBy: "@")
                    for i in 1..<parts.count {
                        let domain = parts[i]
                            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).inverted)
                            .first ?? ""
                        if !domain.isEmpty {
                            domains.append(domain.lowercased())
                        }
                    }
                }
            }
            return Array(Set(domains))
        }
    }

    // MARK: - Encrypted Archive

    struct EncryptedArchive: Codable {
        let id: UUID
        let name: String
        let createdAt: Date
        let emailCount: Int
        let encryptedData: Data
        let nonce: Data
        let tag: Data
    }

    // MARK: - Archive Metadata

    struct ArchiveMetadata: Identifiable, Codable, Sendable {
        let id: UUID
        let name: String
        let createdAt: Date
        let emailCount: Int
        let sizeBytes: Int
    }

    // MARK: - Encryption Key Management

    enum KeychainError: Error {
        case accessFailed(OSStatus)
    }

    private func getOrCreateKey() throws -> SymmetricKey {
        switch loadKeyFromKeychain() {
        case .success(let key):
            return key
        case .notFound:
            let newKey = SymmetricKey(size: .bits256)
            try saveKeyToKeychain(newKey)
            return newKey
        case .error(let status):
            throw KeychainError.accessFailed(status)
        }
    }

    private enum KeychainResult {
        case success(SymmetricKey)
        case notFound
        case error(OSStatus)
    }

    private func loadKeyFromKeychain() -> KeychainResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainTag,
            kSecAttrAccount as String: "encryptionKey",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return .notFound
        }
        guard status == errSecSuccess, let keyData = result as? Data, keyData.count == 32 else {
            return .error(status)
        }
        return .success(SymmetricKey(data: keyData))
    }

    private func saveKeyToKeychain(_ key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data(Array($0)) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainTag,
            kSecAttrAccount as String: "encryptionKey"
        ]

        let updateAttrs: [String: Any] = [
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = keyData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw EncryptedStorageError.keychainError(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw EncryptedStorageError.keychainError(updateStatus)
        }
    }

    // MARK: - Encrypt / Decrypt

    func encrypt(emails: [MBOXParser.RawEmail], name: String) throws -> EncryptedArchive {
        let key = try getOrCreateKey()

        let serializableEmails = emails.map { SerializableEmail(from: $0) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(serializableEmails)

        let sealedBox = try AES.GCM.seal(jsonData, using: key)

        guard sealedBox.combined != nil else {
            throw EncryptedStorageError.encryptionFailed
        }

        let nonceData = Data(sealedBox.nonce)
        let tagData = Data(sealedBox.tag)
        let ciphertextData = sealedBox.ciphertext

        return EncryptedArchive(
            id: UUID(),
            name: name,
            createdAt: Date(),
            emailCount: emails.count,
            encryptedData: ciphertextData,
            nonce: nonceData,
            tag: tagData
        )
    }

    func decrypt(archive: EncryptedArchive) throws -> [MBOXParser.RawEmail] {
        let key = try getOrCreateKey()

        let nonce = try AES.GCM.Nonce(data: archive.nonce)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: archive.encryptedData,
            tag: archive.tag
        )

        let decryptedData = try AES.GCM.open(sealedBox, using: key)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let serializableEmails = try decoder.decode([SerializableEmail].self, from: decryptedData)

        return serializableEmails.map { $0.toRawEmail() }
    }

    // MARK: - File Storage

    private func archivesDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("mailin/EncryptedArchives", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // W3: encrypted archives are created/opened only from foreground,
        // user-driven flows — the strictest class (.complete) applies: the
        // files are unreadable whenever the device is locked. macOS: 700.
        ArtifactProtection.applyForegroundOnly(to: dir)
        return dir
    }

    func saveArchive(_ archive: EncryptedArchive) throws {
        let dir = try archivesDirectory()

        // Save the full encrypted archive
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archiveData = try encoder.encode(archive)
        let archiveURL = dir.appendingPathComponent("\(archive.id.uuidString).\(archiveExtension)")
        try archiveData.write(to: archiveURL, options: .atomic)
        ArtifactProtection.applyForegroundOnly(to: archiveURL)

        // Save a small metadata sidecar
        let metadata = ArchiveMetadata(
            id: archive.id,
            name: archive.name,
            createdAt: archive.createdAt,
            emailCount: archive.emailCount,
            sizeBytes: archiveData.count
        )
        let metaData = try encoder.encode(metadata)
        let metaURL = dir.appendingPathComponent("\(archive.id.uuidString).\(metadataExtension)")
        try metaData.write(to: metaURL, options: .atomic)
        ArtifactProtection.applyForegroundOnly(to: metaURL)
    }

    func loadArchive(id: UUID) throws -> EncryptedArchive {
        let dir = try archivesDirectory()
        let archiveURL = dir.appendingPathComponent("\(id.uuidString).\(archiveExtension)")

        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw EncryptedStorageError.archiveNotFound
        }

        let data = try Data(contentsOf: archiveURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EncryptedArchive.self, from: data)
    }

    func listArchives() -> [ArchiveMetadata] {
        guard let dir = try? archivesDirectory() else { return [] }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var archives: [ArchiveMetadata] = []
        for file in files where file.pathExtension == metadataExtension {
            if let data = try? Data(contentsOf: file),
               let meta = try? decoder.decode(ArchiveMetadata.self, from: data) {
                archives.append(meta)
            }
        }

        return archives.sorted { $0.createdAt > $1.createdAt }
    }

    func deleteArchive(id: UUID) throws {
        let dir = try archivesDirectory()
        let archiveURL = dir.appendingPathComponent("\(id.uuidString).\(archiveExtension)")
        let metaURL = dir.appendingPathComponent("\(id.uuidString).\(metadataExtension)")

        let fm = FileManager.default
        if fm.fileExists(atPath: archiveURL.path) {
            try fm.removeItem(at: archiveURL)
        }
        if fm.fileExists(atPath: metaURL.path) {
            try fm.removeItem(at: metaURL)
        }
    }

    // MARK: - Errors

    enum EncryptedStorageError: LocalizedError {
        case keychainError(OSStatus)
        case encryptionFailed
        case archiveNotFound

        var errorDescription: String? {
            switch self {
            case .keychainError(let status):
                return "Keychain error (status: \(status)). Could not access encryption key."
            case .encryptionFailed:
                return "Failed to encrypt archive data."
            case .archiveNotFound:
                return "The requested encrypted archive was not found."
            }
        }
    }
}
