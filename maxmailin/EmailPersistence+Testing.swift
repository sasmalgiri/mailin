//
//  EmailPersistence+Testing.swift
//  maxmailin
//
//  I-11: author and read a v1-shaped JSON library at an arbitrary location,
//  so the migration timing rows can run against a synthetic library derived
//  from the owner's real mailbox instead of waiting for a customer's files.
//  DEBUG only; production never writes the v1 store.
//

import Foundation

#if DEBUG
extension EmailPersistence {

    /// Writes `saved_emails.json` (the v1 array shape, lightweight: no raw
    /// source, no attachment bytes) and `session_meta.json` beside it.
    static func writeLegacyStoreForTesting(emails: [MBOXParser.RawEmail], senderEmail: String, to storeURL: URL) throws {
        let lightweight = emails.map { email -> MBOXParser.RawEmail in
            var e = email
            e.rawSource = ""
            e.attachments = e.attachments.map {
                AttachmentMetadata(filename: $0.filename, mimeType: $0.mimeType, size: $0.size,
                                   isInline: $0.isInline, contentID: $0.contentID, base64: nil, fileURL: nil)
            }
            e.mimeRoot = nil
            e.mimeSummary = nil
            e.mimeDiagnostics = []
            return e
        }
        let encoder = JSONEncoder()
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(lightweight).write(to: storeURL, options: .atomic)
        let meta = SessionMeta(senderEmail: senderEmail, emailCount: emails.count, savedAt: Date())
        try encoder.encode(meta).write(to: storeURL.deletingLastPathComponent().appendingPathComponent("session_meta.json"), options: .atomic)
    }

    static func legacyStoreExists(at storeURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: storeURL.path)
    }

    /// Reads a v1 store at `storeURL` the way `load()` reads the production one.
    static func load(from storeURL: URL) -> (emails: [MBOXParser.RawEmail], senderEmail: String) {
        guard let data = try? Data(contentsOf: storeURL),
              let emails = try? JSONDecoder().decode([MBOXParser.RawEmail].self, from: data) else { return ([], "") }
        let metaURL = storeURL.deletingLastPathComponent().appendingPathComponent("session_meta.json")
        let sender = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(SessionMeta.self, from: $0) }?.senderEmail ?? ""
        return (emails, sender)
    }
}
#endif
