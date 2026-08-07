import Foundation

struct ParserFactory {
    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [MBOXParser.RawEmail] {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "mbox", "eml", "":
            // Extensionless files are treated as MBOX (Google Takeout ships
            // extensionless mbox payloads) — a deliberate, documented mapping
            // (V2_FORMAT_MATRIX.md), not a silent fallthrough.
            return try MBOXParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        case "emlx":
            return try EMLXParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        case "msg":
            return try MSGParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        case "pst", "ost":
            return try PSTParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        case "nsf":
            return try NSFParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        case "zip":
            // §7.6: no bounded ZIP extraction ships in v2.0 — an explicit,
            // honest limitation instead of silently mis-parsing the archive
            // as MBOX. (ZIP contents can be imported after manual extraction.)
            throw ExtractionError.unsupportedFormat(
                reason: "ZIP archives are not imported directly in this version. Unzip the archive and import the contained mailbox files (.mbox, .eml, …).")
        default:
            // §7.4: an unknown extension is an explicit error — never a
            // silent MBOX fallthrough that mis-parses binary data.
            throw ExtractionError.unsupportedFormat(
                reason: "Unsupported file type '.\(ext)'. Supported formats: \(allSupportedExtensions.map { ".\($0)" }.joined(separator: ", ")).")
        }
    }

    static let allSupportedExtensions: [String] = [
        "mbox", "eml", "emlx", "msg", "pst", "ost", "nsf"
    ]

    /// Stable parser identity (type + version) for a file extension. Used to
    /// bind resume checkpoints and import receipts to the exact parser that
    /// produced them (Part B5/C): a parser upgrade invalidates mid-file
    /// checkpoints instead of silently resuming against a different message
    /// ordering.
    static func parserIdentity(forExtension ext: String) -> (name: String, version: Int) {
        switch ext.lowercased() {
        case "mbox", "eml", "":
            return ("mbox", MBOXParser.parserVersion)
        case "emlx":
            return ("emlx", EMLXParser.parserVersion)
        case "msg":
            return ("msg", MSGParser.parserVersion)
        case "pst", "ost":
            return ("pst", PSTParser.parserVersion)
        case "nsf":
            return ("nsf", NSFParser.parserVersion)
        default:
            return ("unsupported", 0)
        }
    }

    /// Streaming-capable formats: parser can drain messages in batches
    /// without holding the entire file in memory. Used by the bulk import
    /// coordinator to decide between callback-based (bounded memory) and
    /// array-based ingest.
    static let streamableExtensions: Set<String> = ["mbox", "eml", ""]

    /// Streaming parse for formats that support it. Calls `onBatch` for each
    /// chunk of `batchSize` parsed messages and immediately drops them, so
    /// peak memory is bounded by `batchSize` rather than file size. For
    /// formats that cannot stream (PST, NSF, MSG) the array parser runs and
    /// the result is drained through `onBatch` in bounded chunks.
    ///
    /// Returns the SOURCE-SCOPED recovery report (§7.7 — no global mutable
    /// report; concurrent imports cannot race).
    @discardableResult
    static func parseStreamingCallback(
        fileURL: URL,
        senderEmail: String,
        batchSize: Int = 200,
        onProgress: ((Double) -> Void)? = nil,
        onBatch: ([MBOXParser.RawEmail]) async throws -> Void
    ) async throws -> MBOXParser.ParseRecoveryReport {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "mbox", "eml", "":
            return try await MBOXParser.parseStreamingCallback(
                fileURL: fileURL,
                senderEmail: senderEmail,
                batchSize: batchSize,
                onProgress: onProgress,
                onBatch: onBatch
            )
        default:
            // Non-streamable format: the array parser runs (rejecting
            // unsupported extensions) and the result drains in bounded
            // chunks. These parsers throw on damage rather than recover,
            // so a successful parse reports zero failures.
            let parsed = try parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
            for chunk in parsed.chunked(into: batchSize) {
                try await onBatch(chunk)
            }
            return MBOXParser.ParseRecoveryReport(
                totalMessages: parsed.count, successfullyParsed: parsed.count,
                failed: 0, errorCategories: [:])
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
