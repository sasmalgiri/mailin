@testable import ArchiveCore
//
//  EvidenceAttachmentOpener.swift
//  maxmailin
//
//  Five jobs FIND-05 (plan v3 closure list): an evidence chip that names an
//  attachment opens THAT attachment — the one at the ordinal the index
//  recorded, not the first file with the same name — in one click.
//
//  The bytes come from the same hydrator the detail view uses (temp file,
//  inline payload, the part's own byte range, or a re-extraction from the
//  stored raw message), are written once to a private temporary folder under
//  the attachment's own name, and handed to the system to preview or open.
//  Nothing is written into the archive; the file lives in the temporary
//  directory and the system reclaims it.
//

import Foundation

enum EvidenceAttachmentOpener {

    enum Failure: Error, Equatable {
        case messageUnreadable
        case noAttachment(ordinal: Int, count: Int)
        case bytesUnavailable(filename: String)
        case writeFailed(String)

        /// What the alert says. Plain statements; nothing is invented.
        var message: String {
            switch self {
            case .messageUnreadable:
                return String(localized: "The message could not be read from the archive.")
            case .noAttachment(let ordinal, let count):
                return String(localized: "The message has no attachment at position \(ordinal + 1) (it has \(count)). Re-run indexing from Settings ▸ Health if the message changed.")
            case .bytesUnavailable(let filename):
                return String(localized: "The bytes of “\(filename)” could not be produced from the stored message.")
            case .writeFailed(let reason):
                return String(localized: "The attachment could not be written to a temporary file: \(reason)")
            }
        }
    }

    /// Writes attachment `ordinal` of `email` to a fresh temporary folder
    /// under its own (file-system-safe) name and returns the file's URL.
    static func temporaryFile(for email: MBOXParser.RawEmail, ordinal: Int,
                              cache: AttachmentHydrator.Cache? = nil) -> Result<URL, Failure> {
        guard ordinal >= 0, ordinal < email.attachments.count else {
            return .failure(.noAttachment(ordinal: ordinal, count: email.attachments.count))
        }
        let attachment = email.attachments[ordinal]
        guard let data = AttachmentHydrator.data(for: attachment, index: ordinal, email: email, cache: cache) else {
            return .failure(.bytesUnavailable(filename: attachment.filename))
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-open-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent(safeFilename(attachment.filename, mimeType: attachment.mimeType))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
        return .success(url)
    }

    /// Loads the full message by id, writes the attachment and opens it with
    /// the system. Returns nil on success, otherwise the failure to show.
    @MainActor
    static func open(emailID: EmailID, ordinal: Int, archive: ArchiveDataService) async -> Failure? {
        guard let email = try? await archive.fullEmails(ids: [emailID]).first else { return .messageUnreadable }
        switch temporaryFile(for: email, ordinal: ordinal) {
        case .success(let url):
            PlatformURLOpener.open(url)
            return nil
        case .failure(let failure):
            return failure
        }
    }

    /// The attachment's own name, made safe for one path component; an
    /// extension from the MIME type when the name has none, so the system
    /// can pick an app.
    static func safeFilename(_ filename: String, mimeType: String) -> String {
        var name = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "attachment" }
        if (name as NSString).pathExtension.isEmpty, let ext = extensionFor(mimeType) {
            name += "." + ext
        }
        return name
    }

    private static func extensionFor(_ mimeType: String) -> String? {
        let lower = mimeType.lowercased().split(separator: ";").first.map(String.init) ?? ""
        let table: [String: String] = [
            "application/pdf": "pdf", "text/plain": "txt", "text/html": "html", "text/csv": "csv",
            "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/tiff": "tiff", "image/heic": "heic",
            "application/msword": "doc", "application/vnd.ms-excel": "xls", "application/vnd.ms-powerpoint": "ppt",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
            "application/zip": "zip", "message/rfc822": "eml", "audio/mpeg": "mp3", "audio/mp4": "m4a",
            "audio/x-m4a": "m4a", "video/mp4": "mp4", "video/quicktime": "mov", "application/rtf": "rtf",
        ]
        return table[lower]
    }
}
