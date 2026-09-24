//
//  AttachmentHydrator.swift
//  mailin
//
//  Page 1 (Archive) must be able to READ an attachment out of an imported
//  message, not merely list its name.
//
//  Why this exists: at parse time `EmailBodyExtractor` decodes each attachment
//  to a temp file and returns `fileURL` (with `base64` nil). Temp files do not
//  survive — the OS reclaims them, and they are certainly gone after a
//  relaunch. The store persists the complete raw MIME in `email_bodies.raw`,
//  so the bytes are never lost; they simply have to be re-extracted on demand.
//
//  That re-extraction already existed, but privately inside `PSTWriter`, so
//  only PST export benefited. Every other reader (detail view, save-attachment,
//  export, attachment-content indexing) checked `fileURL`/`base64`, got nil for
//  a stored email, and silently failed. This type is that logic, shared.
//

import Foundation

/// Re-extracts attachment payloads from a message's raw MIME on demand.
///
/// Re-extraction parses the whole message, so callers handling several
/// attachments of one email should pass the same `Cache` to do it once.
enum AttachmentHydrator {

    /// Per-email memo of the re-extracted attachment list.
    final class Cache {
        fileprivate var hydrated: [AttachmentMetadata]?
        fileprivate var attemptedFor: UUID?
        init() {}
    }

    /// The bytes of `attachment`, or nil when they genuinely cannot be
    /// recovered (no live temp file, no inline payload, and no raw MIME).
    ///
    /// - Parameters:
    ///   - index: position in `email.attachments`, used as the fallback match
    ///     when filenames are absent or duplicated.
    ///   - cache: optional memo, so N attachments of one email cost one parse.
    static func data(for attachment: AttachmentMetadata,
                     index: Int,
                     email: MBOXParser.RawEmail,
                     cache: Cache? = nil) -> Data? {
        // 1. Still-live temp file from this session's parse.
        if let url = attachment.fileURL, let data = try? Data(contentsOf: url) {
            return data
        }
        // 2. Inline payload, when a parser kept one.
        if let base64 = attachment.base64,
           let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
            return data
        }
        // 3. Re-extract from the raw MIME the store persisted.
        guard !email.rawSource.isEmpty else { return nil }
        let list = hydratedAttachments(for: email, cache: cache)
        guard !list.isEmpty else { return nil }

        let match = list.first { !$0.filename.isEmpty && $0.filename == attachment.filename }
            ?? (index < list.count ? list[index] : nil)
        guard let match else { return nil }

        if let url = match.fileURL, let data = try? Data(contentsOf: url) { return data }
        if let base64 = match.base64,
           let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
            return data
        }
        return nil
    }

    /// True when this attachment's bytes are obtainable. Used by UI that must
    /// decide whether to offer Open/Save rather than offering an action that
    /// then does nothing.
    static func canRead(_ attachment: AttachmentMetadata,
                        index: Int,
                        email: MBOXParser.RawEmail,
                        cache: Cache? = nil) -> Bool {
        if let url = attachment.fileURL,
           FileManager.default.fileExists(atPath: url.path) { return true }
        if attachment.base64 != nil { return true }
        return !email.rawSource.isEmpty
    }

    private static func hydratedAttachments(for email: MBOXParser.RawEmail,
                                            cache: Cache?) -> [AttachmentMetadata] {
        if let cache, cache.attemptedFor == email.id {
            return cache.hydrated ?? []
        }
        let list = (try? EmailBodyExtractor.extractContents(from: email.rawSource))?.attachments ?? []
        if let cache {
            cache.hydrated = list
            cache.attemptedFor = email.id
        }
        return list
    }
}
