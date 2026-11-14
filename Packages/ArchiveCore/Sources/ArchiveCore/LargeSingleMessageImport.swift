//
//  LargeSingleMessageImport.swift
//  ArchiveCore
//
//  CLOSE-01 (v4 plan §8.1): one Apple Mail .emlx or Outlook .msg file of any
//  size, imported in bounded memory by the offset engine.
//
//  Before, both were read whole into memory: an .emlx above 500,000,000 bytes
//  and a .msg above 2,000,000,000 bytes were refused, and every one below was
//  resident in full while it was parsed. A file above the engine's full-parse
//  ceiling now takes the same road as a large mbox message:
//
//   • .emlx — the byte-count line gives the RFC 822 message's range in the
//     file; the message is located there (header block read, body never
//     read), imported from its headers plus a locator into the .emlx itself,
//     and its flags come from the property list after it. Its text and
//     attachments are then streamed out of that range after import
//     (`StreamedBodyIndexer`, `StreamedPartDecoder`), exactly as for mbox.
//
//   • .msg — there is no RFC 5322 text to point at, so the message is first
//     rendered to one (`MSGStreamRenderer`, bodies and attachments streamed
//     out of the compound file in slices) inside the archive, next to the
//     source copies (`sources/<sha256>/`), and that rendering is imported by
//     range like a large .eml. A rendering already there (a repeated import)
//     is reused, so earlier locators keep pointing at the same bytes.
//
//  At or under the ceiling nothing changes: the file goes through
//  `ParserFactory` and is read in full (by range, through a file handle).
//

import Foundation

extension OffsetImportEngine {

    enum LargeSingleMessageKind: Sendable, Equatable {
        case emlx
        case msg
    }

    /// The single-message files this engine imports by range: an .emlx or a
    /// .msg/.oft file above `fullParseCeilingBytes`.
    func largeSingleMessageKind(fileURL: URL, format: SourceFormat) -> LargeSingleMessageKind? {
        let kind: LargeSingleMessageKind
        switch format {
        case .emlx: kind = .emlx
        case .msg: kind = .msg
        default: return nil
        }
        var isDirectory: ObjCBool = false
        guard unsafe FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value,
              size > fullParseCeilingBytes else { return nil }
        return kind
    }

    /// Where the rendering of a large .msg lives: `<renderDirectory>/<name>.rendered.eml`.
    static func renderedMessageURL(for fileURL: URL, in renderDirectory: URL) -> URL {
        renderDirectory.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".rendered.eml")
    }

    /// Imports one large .emlx or .msg file; the batch holds its one message.
    /// - Parameter renderDirectory: where a .msg is rendered (inside the archive).
    @discardableResult
    func importLargeSingleMessage(
        fileURL: URL,
        kind: LargeSingleMessageKind,
        renderDirectory: URL,
        senderEmail: String,
        retainAttachmentBytes: Bool = true,
        materializeAttachments: Bool = true,
        sourceDigest: String? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onBatch: ([Imported]) async throws -> Void
    ) async throws -> MBOXParser.ParseRecoveryReport {
        try Task.checkCancellation()
        switch kind {
        case .emlx:
            let layout = try EMLXParser.layout(of: fileURL)
            var (locator, headers, _) = try scanner.locate(fileURL: fileURL, messageRange: layout.message)
            locator.sourceDigest = sourceDigest
            var imported = try build(locator: locator, headers: headers, senderEmail: senderEmail,
                                     retainAttachmentBytes: retainAttachmentBytes,
                                     materializeAttachments: materializeAttachments, reader: LocatorReader())
            EMLXParser.applyMetadata(plist: EMLXParser.plist(of: fileURL, layout: layout), fileURL: fileURL, to: &imported.email)
            if !imported.bodyWasDecoded { Self.classifyDirection(&imported.email, senderEmail: senderEmail) }
            onProgress?(1.0)
            try await onBatch([imported])
            return MBOXParser.ParseRecoveryReport(totalMessages: 1, successfullyParsed: 1, failed: 0, errorCategories: [:])

        case .msg:
            try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
            let rendered = Self.renderedMessageURL(for: fileURL, in: renderDirectory)
            let digest: String
            if FileManager.default.fileExists(atPath: rendered.path) {
                digest = try Self.digest(of: rendered)
            } else {
                // Rendered under a temporary name and moved into place, so an
                // interrupted rendering is never taken for a finished one.
                let partial = renderDirectory.appendingPathComponent(".rendering-\(UUID().uuidString)")
                do {
                    digest = try MSGStreamRenderer.render(msgURL: fileURL, to: partial).sha256
                    try FileManager.default.moveItem(at: partial, to: rendered)
                } catch {
                    try? FileManager.default.removeItem(at: partial)
                    throw error
                }
            }
            onProgress?(0.5)
            return try await importMessages(
                fileURL: rendered, senderEmail: senderEmail, batchSize: 1,
                retainAttachmentBytes: retainAttachmentBytes, materializeAttachments: materializeAttachments,
                sourceDigest: digest, onProgress: { onProgress?(0.5 + $0 / 2) }
            ) { batch in
                try await onBatch(batch.map { item in
                    var item = item
                    // As the in-memory reader decides it: the sender, not the folder.
                    Self.classifyDirection(&item.email, senderEmail: senderEmail)
                    return item
                })
            }
        }
    }

    /// "sent" when the message is from `senderEmail`, else "received".
    static func classifyDirection(_ email: inout MBOXParser.RawEmail, senderEmail: String) {
        let from = email.headers["From"] ?? ""
        email.messageType = !senderEmail.isEmpty && from.lowercased().contains(senderEmail.lowercased()) ? "sent" : "received"
    }
}
