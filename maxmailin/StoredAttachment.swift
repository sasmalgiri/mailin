//
//  StoredAttachment.swift
//  maxmailin
//
//  SwiftData persistence model for email attachments. Companion to StoredEmail.
//  Attachment data is externalStorage — never bloats the SQLite metadata file.
//

import Foundation
import SwiftData

@Model
final class StoredAttachment {
    @Attribute(.unique) var id: UUID

    var filename: String
    var mimeType: String?
    var sizeBytes: Int

    /// Optional SHA-256 of the attachment bytes. Forensic integrity.
    var contentHash: String?

    /// Attachment bytes. Off-loaded by SwiftData to disk; only loaded on demand.
    @Attribute(.externalStorage) var data: Data?

    /// Backlink to owning email. Cascading delete cleans up attachments
    /// when the parent StoredEmail is removed.
    var email: StoredEmail?

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String? = nil,
        sizeBytes: Int = 0,
        contentHash: String? = nil,
        data: Data? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.contentHash = contentHash
        self.data = data
    }
}
