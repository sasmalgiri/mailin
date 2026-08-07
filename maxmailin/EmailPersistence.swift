import Foundation
import Compression
import os.log

private let persistLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "Persistence")

struct EmailPersistence {
    private static let saveQueue = DispatchQueue(label: "com.ecosanskriti.mailin.persistence", qos: .utility)
    private static let currentVersion = 1

    #if DEBUG
    /// Test-only override for the base directory, so unit tests isolate the v1
    /// store to a temp dir instead of the real Application Support location.
    nonisolated(unsafe) static var testBaseDirectoryOverride: URL?
    #endif

    private static var baseDirectory: URL {
        #if DEBUG
        if let override = testBaseDirectoryOverride {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        #endif
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("mailin")
        let appDir = appSupport.appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir
    }

    private static var storeURL: URL {
        baseDirectory.appendingPathComponent("saved_emails.json")
    }

    private static var compressedStoreURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("saved_emails.json.lz")
    }

    /// True if a v1 archive file exists on disk (compressed or plain), regardless
    /// of whether it currently decodes. Lets migration distinguish "no previous
    /// data" from "previous data present but unreadable" — the latter must never
    /// be treated as a completed migration.
    static var legacyStoreExists: Bool {
        FileManager.default.fileExists(atPath: compressedStoreURL.path)
            || FileManager.default.fileExists(atPath: storeURL.path)
    }

    static var metaURLForRetentionCheck: URL { metaURL }
    private static var metaURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("session_meta.json")
    }

    enum PersistenceError: LocalizedError {
        case decompressionFailed

        var errorDescription: String? {
            switch self {
            case .decompressionFailed:
                return "Saved email data could not be decompressed. The file may be corrupted."
            }
        }
    }

    struct SessionMeta: Codable {
        var version: Int = 1
        let senderEmail: String
        let emailCount: Int
        let savedAt: Date
    }

    // Part Q: the async `save(emails:senderEmail:)` production API is GONE —
    // the v1 JSON store is never written by the app anymore. `load()` stays
    // ONLY as MigrationService's one-time migration source (plus its internal
    // uncompressed→compressed rewrite below), and the retention/clear paths
    // keep `clear()`/`hasSavedData`.

    #if DEBUG
    /// Test-only v1-store writer: lets migration tests author a legacy store
    /// exactly the way v1 did. Never called from production code.
    static func saveSync(emails: [MBOXParser.RawEmail], senderEmail: String) {
        guard !emails.isEmpty else { return }
        saveQueue.sync {
            performSave(emails: emails, senderEmail: senderEmail)
        }
    }
    #endif

    private static func stripRedundantData(_ emails: [MBOXParser.RawEmail]) -> [MBOXParser.RawEmail] {
        emails.map { email in
            var e = email
            e.rawSource = ""
            e.attachments = e.attachments.map { att in
                AttachmentMetadata(filename: att.filename, mimeType: att.mimeType, size: att.size,
                                   isInline: att.isInline, contentID: att.contentID, base64: nil, fileURL: nil)
            }
            e.mimeRoot = nil
            e.mimeSummary = nil
            e.mimeDiagnostics = []
            return e
        }
    }

    private static func performSave(emails: [MBOXParser.RawEmail], senderEmail: String) {
        do {
            let encoder = JSONEncoder()
            let lightweight = stripRedundantData(emails)
            let jsonData = try encoder.encode(lightweight)
            let meta = SessionMeta(senderEmail: senderEmail, emailCount: emails.count, savedAt: Date())
            let metaData = try encoder.encode(meta)

            try metaData.write(to: metaURL, options: .atomic)

            let compressed = compress(jsonData)
            if let compressed {
                try compressed.write(to: compressedStoreURL, options: .atomic)
                try? FileManager.default.removeItem(at: storeURL)
                persistLog.info("Saved \(emails.count) emails (\(jsonData.count) → \(compressed.count) bytes compressed)")
            } else {
                try jsonData.write(to: storeURL, options: .atomic)
                persistLog.info("Saved \(emails.count) emails (\(jsonData.count) bytes uncompressed)")
            }
        } catch {
            persistLog.error("Failed to save emails: \(error.localizedDescription)")
        }
    }

    static func load() -> (emails: [MBOXParser.RawEmail], senderEmail: String) {
        let hasCompressed = FileManager.default.fileExists(atPath: compressedStoreURL.path)
        let hasUncompressed = FileManager.default.fileExists(atPath: storeURL.path)
        guard hasCompressed || hasUncompressed else {
            return ([], "")
        }
        do {
            let jsonData: Data
            if hasCompressed {
                let compressed = try Data(contentsOf: compressedStoreURL)
                if let decompressed = decompress(compressed) {
                    jsonData = decompressed
                } else if hasUncompressed {
                    persistLog.error("Decompression failed, trying uncompressed fallback")
                    jsonData = try Data(contentsOf: storeURL)
                } else {
                    persistLog.error("Decompression failed, no fallback available — data may be corrupted")
                    throw PersistenceError.decompressionFailed
                }
            } else {
                jsonData = try Data(contentsOf: storeURL)
            }

            let emails = try JSONDecoder().decode([MBOXParser.RawEmail].self, from: jsonData)

            var senderEmail = ""
            if FileManager.default.fileExists(atPath: metaURL.path) {
                let metaData = try Data(contentsOf: metaURL)
                let meta = try JSONDecoder().decode(SessionMeta.self, from: metaData)
                senderEmail = meta.senderEmail
            }
            persistLog.info("Loaded \(emails.count) emails")

            if hasUncompressed && !emails.isEmpty {
                let sender = senderEmail
                saveQueue.async {
                    performSave(emails: emails, senderEmail: sender)
                }
                persistLog.info("Migrating uncompressed store to compressed format")
            }

            return (emails, senderEmail)
        } catch {
            persistLog.error("Failed to load emails: \(error.localizedDescription). Attempting legacy load.")
            return loadLegacy()
        }
    }

    private static func loadLegacy() -> (emails: [MBOXParser.RawEmail], senderEmail: String) {
        let urls = [storeURL, compressedStoreURL].filter { FileManager.default.fileExists(atPath: $0.path) }
        for url in urls {
            do {
                var data = try Data(contentsOf: url)
                if url == compressedStoreURL, let decompressed = decompress(data) {
                    data = decompressed
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .deferredToDate
                let emails = try decoder.decode([MBOXParser.RawEmail].self, from: data)
                persistLog.info("Legacy load recovered \(emails.count) emails from \(url.lastPathComponent)")
                return (emails, "")
            } catch {
                persistLog.error("Legacy load failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return ([], "")
    }

    static func clear() {
        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: compressedStoreURL)
        try? FileManager.default.removeItem(at: metaURL)
        clearBodyStore()
    }

    // MARK: - Body Store (for compacted emails)

    private static var bodyStoreDir: URL {
        let appDir = storeURL.deletingLastPathComponent()
        let dir = appDir.appendingPathComponent("body_store", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func persistBodies(_ emails: [MBOXParser.RawEmail]) {
        saveQueue.async {
            for email in emails where !email.isBodyCompacted {
                let fileURL = bodyStoreDir.appendingPathComponent("\(email.id.uuidString).json")
                let body = BodyRecord(
                    plainBody: email.plainBody,
                    htmlBody: email.htmlBody,
                    rawSource: email.rawSource
                )
                if let data = try? JSONEncoder().encode(body) {
                    try? data.write(to: fileURL, options: .atomic)
                }
            }
        }
    }

    static func loadBody(for emailID: UUID) -> BodyRecord? {
        let fileURL = bodyStoreDir.appendingPathComponent("\(emailID.uuidString).json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(BodyRecord.self, from: data)
    }

    static func clearBodyStore() {
        try? FileManager.default.removeItem(at: bodyStoreDir)
    }

    struct BodyRecord: Codable {
        let plainBody: String
        let htmlBody: String
        let rawSource: String
    }

    static func flushPendingSaves() {
        saveQueue.sync {}
    }

    static var hasSavedData: Bool {
        FileManager.default.fileExists(atPath: storeURL.path) ||
        FileManager.default.fileExists(atPath: compressedStoreURL.path)
    }

    // MARK: - Compression

    private static func compress(_ data: Data) -> Data? {
        let destinationBufferSize = data.count
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationBufferSize)
        defer { destinationBuffer.deallocate() }

        let compressedSize = data.withUnsafeBytes { (sourceBuffer: UnsafeRawBufferPointer) -> Int in
            guard let sourcePtr = sourceBuffer.baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer, destinationBufferSize,
                sourcePtr.assumingMemoryBound(to: UInt8.self), data.count,
                nil,
                COMPRESSION_LZFSE
            )
        }

        guard compressedSize > 0 else {
            persistLog.error("Compression failed")
            return nil
        }

        var result = Data(count: MemoryLayout<Int>.size + compressedSize)
        var originalSize = data.count
        result.replaceSubrange(0..<MemoryLayout<Int>.size, with: &originalSize, count: MemoryLayout<Int>.size)
        result.replaceSubrange(MemoryLayout<Int>.size..<MemoryLayout<Int>.size + compressedSize,
                               with: destinationBuffer, count: compressedSize)
        return result
    }

    private static func decompress(_ data: Data) -> Data? {
        guard data.count > MemoryLayout<Int>.size else { return nil }

        var originalSize = 0
        withUnsafeMutableBytes(of: &originalSize) { destPtr in
            data.copyBytes(to: destPtr.assumingMemoryBound(to: UInt8.self), from: 0..<MemoryLayout<Int>.size)
        }

        guard originalSize > 0, originalSize < 500_000_000 else {
            persistLog.error("Invalid decompression size: \(originalSize)")
            return nil
        }

        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: originalSize)
        defer { destinationBuffer.deallocate() }

        let compressedData = data.dropFirst(MemoryLayout<Int>.size)
        let decompressedSize = compressedData.withUnsafeBytes { (sourceBuffer: UnsafeRawBufferPointer) -> Int in
            guard let sourcePtr = sourceBuffer.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer, originalSize,
                sourcePtr.assumingMemoryBound(to: UInt8.self), compressedData.count,
                nil,
                COMPRESSION_LZFSE
            )
        }

        guard decompressedSize == originalSize else {
            persistLog.error("Decompression size mismatch: expected \(originalSize), got \(decompressedSize)")
            return nil
        }

        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
}
