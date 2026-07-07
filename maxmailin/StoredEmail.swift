//
//  StoredEmail.swift
//  maxmailin
//
//  SwiftData persistence model. Mirrors MBOXParser.RawEmail closely so the
//  EmailStore adapter can convert between them transparently. Bodies and raw
//  source are externalStorage attributes — SwiftData stores them as separate
//  files on disk, keeping the SQLite database compact and enabling lazy load.
//
//  This is the foundation for the 1 TB archive scale: every query returns
//  only StoredEmail metadata initially; body data is fetched on demand.
//

import Foundation
import SwiftData

@Model
final class StoredEmail {
    // MARK: - Identity
    @Attribute(.unique) var id: UUID
    var messageID: String?
    var parserVersion: Int

    // MARK: - Searchable headers (indexed columns)
    var subject: String
    var fromAddress: String
    var fromName: String?
    var toAddresses: String       // comma-joined for full-text indexing
    var ccAddresses: String?
    var bccAddresses: String?
    var date: Date

    // MARK: - Derived indexable fields (for fast filters / grouping)
    var yearMonth: String          // "2024-03" — speeds up date-bucketed queries
    var hasAttachments: Bool
    var sizeBytes: Int

    // MARK: - Threading
    var inReplyToID: String?
    var referencesIDs: String?     // newline-separated

    // MARK: - Body (off-loaded to external storage)
    @Attribute(.externalStorage) var plainBody: Data?
    @Attribute(.externalStorage) var htmlBody: Data?
    @Attribute(.externalStorage) var rawSource: Data?

    // MARK: - Lightweight preview (always in main store)
    var bodyPreview: String?

    // MARK: - Headers blob (off-loaded — rarely queried)
    @Attribute(.externalStorage) var headersJSON: Data?

    // MARK: - Forensic integrity
    /// SHA-256 of the source file this email was imported from. Chain-of-custody anchor.
    var sourceFileHash: String?
    /// Per-email HMAC computed at import time; used for tamper detection.
    var integrityHMAC: String?

    // MARK: - Account association (reserved)
    /// Reserved field. Always nil in mailin (offline-only); no concept of
    /// "received under account X" because mailin never receives mail.
    /// Kept on the model so the v1 → v2 SwiftData migration is lightweight
    /// and so the row layout is stable across future schema migrations.
    var accountID: String?

    // MARK: - Review / tagging
    var tags: [String]
    var isPinned: Bool
    var reviewStatus: String?      // "relevant" / "privileged" / "irrelevant" / nil
    var importedAt: Date

    // MARK: - Relationships
    @Relationship(deleteRule: .cascade, inverse: \StoredAttachment.email)
    var attachments: [StoredAttachment]

    init(
        id: UUID = UUID(),
        messageID: String? = nil,
        parserVersion: Int = 1,
        subject: String,
        fromAddress: String,
        fromName: String? = nil,
        toAddresses: String,
        ccAddresses: String? = nil,
        bccAddresses: String? = nil,
        date: Date,
        bodyPreview: String? = nil,
        sourceFileHash: String? = nil,
        tags: [String] = [],
        isPinned: Bool = false
    ) {
        self.id = id
        self.messageID = messageID
        self.parserVersion = parserVersion
        self.subject = subject
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses
        self.bccAddresses = bccAddresses
        self.date = date
        self.bodyPreview = bodyPreview
        self.sourceFileHash = sourceFileHash
        self.tags = tags
        self.isPinned = isPinned
        self.reviewStatus = nil
        self.importedAt = Date()
        self.hasAttachments = false
        self.sizeBytes = 0
        self.attachments = []

        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month], from: date)
        let year = comps.year ?? 1970
        let month = comps.month ?? 1
        self.yearMonth = String(format: "%04d-%02d", year, month)
    }
}
