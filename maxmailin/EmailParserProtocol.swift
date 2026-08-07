import Foundation

struct ParserFactory {
    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [MBOXParser.RawEmail] {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "mbox", "eml":
            return try MBOXParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        case "emlx":
            return try EMLXParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        case "msg":
            return try MSGParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        case "pst", "ost":
            return try PSTParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        case "nsf":
            return try NSFParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        default:
            return try MBOXParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
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
        case "mbox", "eml":
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
            return ("mbox", MBOXParser.parserVersion)
        }
    }

    /// Streaming-capable formats: parser can drain messages in batches
    /// without holding the entire file in memory. Used by the bulk import
    /// coordinator to decide between callback-based (bounded memory) and
    /// array-based ingest.
    static let streamableExtensions: Set<String> = ["mbox", "eml"]

    /// Streaming parse for formats that support it. Calls `onBatch` for each
    /// chunk of `batchSize` parsed messages and immediately drops them, so
    /// peak memory is bounded by `batchSize` rather than file size. For
    /// formats that cannot stream (PST, NSF, MSG) the caller should fall
    /// back to `parse(fileURL:senderEmail:onProgress:)`.
    ///
    /// Returns the total number of messages successfully parsed.
    @discardableResult
    static func parseStreamingCallback(
        fileURL: URL,
        senderEmail: String,
        batchSize: Int = 200,
        onProgress: ((Double) -> Void)? = nil,
        onBatch: ([MBOXParser.RawEmail]) async throws -> Void
    ) async throws -> Int {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "mbox", "eml":
            return try await MBOXParser.parseStreamingCallback(
                fileURL: fileURL,
                senderEmail: senderEmail,
                batchSize: batchSize,
                onProgress: onProgress,
                onBatch: onBatch
            )
        default:
            // Non-streamable format: defer to the array-based parser and
            // hand the entire result to onBatch as a single batch.
            let parsed = try parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
            for chunk in parsed.chunked(into: batchSize) {
                try await onBatch(chunk)
            }
            return parsed.count
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
