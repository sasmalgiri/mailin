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
import os.log

private let attachmentLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin",
                                   category: "AttachmentHydrator")

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

    // MARK: - S5: source-backed reads (behind `Capability.locatorReads`)
    //
    // The re-extraction below needs `email.rawSource`, i.e. the whole message
    // as a String. For a message imported header-only by the offset parser
    // there IS no `rawSource` — the bytes are in the original file — and for a
    // very large message, materialising it just to pull one attachment is the
    // memory cost S4 exists to avoid.
    //
    // So when a locator is available, the message is read from its byte range
    // in the source. Fidelity is better, not merely cheaper: those are the
    // ORIGINAL bytes rather than a round-trip through our parse.
    //
    // Set by the app shell to `{ store.locator(forEmailID:) }` while
    // `Capability.locatorReads` is on, and left nil otherwise — so switching
    // the capability off returns this type to exactly its previous behaviour
    // with no other code path changing.
    nonisolated(unsafe) static var locatorProvider: (@Sendable (UUID) -> MessageLocator?)?

    /// The raw MIME for a message, preferring the stored copy and falling back
    /// to the original source bytes via its locator.
    ///
    /// A locator whose range no longer resolves returns nil rather than
    /// substituting something else: a reviewer must be able to tell "the
    /// source moved" from "the attachment is empty".
    static func rawSource(for email: MBOXParser.RawEmail) -> String? {
        if !email.rawSource.isEmpty { return email.rawSource }
        guard let provider = locatorProvider, let locator = provider(email.id) else { return nil }
        do {
            let data = try LocatorReader().read(locator.messageRange,
                                                from: locator.sourcePath,
                                                expectedDigest: locator.sourceDigest)
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        } catch {
            attachmentLog.error("""
                locator read failed for \(email.id.uuidString, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return nil
        }
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
        // 3. Re-extract from the raw MIME — the stored copy, or the original
        //    source bytes when a locator points at them.
        guard rawSource(for: email) != nil else { return nil }
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
        if !email.rawSource.isEmpty { return true }
        // A locator counts as readable only if the source is still there. The
        // UI would otherwise offer Open on a message whose file has been
        // unmounted, and do nothing.
        guard let provider = locatorProvider, let locator = provider(email.id) else { return false }
        return FileManager.default.fileExists(atPath: locator.sourcePath)
    }

    private static func hydratedAttachments(for email: MBOXParser.RawEmail,
                                            cache: Cache?) -> [AttachmentMetadata] {
        if let cache, cache.attemptedFor == email.id {
            return cache.hydrated ?? []
        }
        guard let raw = rawSource(for: email) else {
            if let cache { cache.hydrated = []; cache.attemptedFor = email.id }
            return []
        }
        let list = (try? EmailBodyExtractor.extractContents(from: raw))?.attachments ?? []
        if let cache {
            cache.hydrated = list
            cache.attemptedFor = email.id
        }
        return list
    }
}
