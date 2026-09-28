import Foundation
import os

struct ParserFactory {
    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [MBOXParser.RawEmail] {
        let classification = SourceFormatClassifier.classify(url: fileURL)
        guard classification.isSupported else {
            throw ExtractionError.unsupportedFormat(
                reason: [classification.summary, classification.format.advice]
                    .compactMap { $0 }.joined(separator: " "))
        }

        // Apple Mail packages and Maildirs are directories: the messages live
        // in files inside them, so the parser must be pointed at those files.
        // Handing the directory itself to MBOXParser failed to open.
        if SourceFormatClassifier.isDirectoryForm(classification.format) {
            let members = SourceFormatClassifier.expand(fileURL, format: classification.format)
            guard !members.isEmpty else {
                throw ExtractionError.unsupportedFormat(
                    reason: "\(classification.summary). No message files were found inside it.")
            }
            var all: [MBOXParser.RawEmail] = []
            for (index, member) in members.enumerated() {
                all += try MBOXParser.parse(fileURL: member, senderEmail: senderEmail) { fraction in
                    onProgress?((Double(index) + fraction) / Double(members.count))
                }
            }
            return all
        }

        // Containers (ZIP / gzip): one member at a time to a scratch file,
        // classified on its own bytes, parsed, deleted. Members that are not
        // mail, are encrypted, or are themselves containers are skipped; the
        // array path has no report to count them in, so they are logged.
        if classification.format.isContainer {
            let steps = try containerSteps(fileURL, format: classification.format)
            let scratch = try containerScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            var all: [MBOXParser.RawEmail] = []
            var sawMail = false
            for (index, step) in steps.enumerated() {
                let dest = scratch.appendingPathComponent("\(index)-\(Self.safeMemberFileName(step.name))")
                defer { try? FileManager.default.removeItem(at: dest) }
                switch try containerMemberDisposition(step, extractingTo: dest) {
                case .refused, .notMail, .nestedContainer:
                    continue
                case .mail:
                    sawMail = true
                    all += try parse(fileURL: dest, senderEmail: senderEmail) { fraction in
                        onProgress?((Double(index) + fraction) / Double(steps.count))
                    }
                }
            }
            guard sawMail else {
                throw ExtractionError.unsupportedFormat(
                    reason: "\(classification.summary). No mailbox files were found inside it (\(steps.count) member\(steps.count == 1 ? "" : "s") examined).")
            }
            return all
        }

        let ext = classification.format.parserToken
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
        default:
            // §7.4: an unknown extension is an explicit error — never a
            // silent MBOX fallthrough that mis-parses binary data.
            throw ExtractionError.unsupportedFormat(
                reason: "Unsupported file type '.\(ext)'. Supported formats: \(allSupportedExtensions.map { ".\($0)" }.joined(separator: ", ")).")
        }
    }

    static let allSupportedExtensions: [String] = [
        "mbox", "eml", "emlx", "msg", "pst", "ost", "nsf", "zip", "gz"
    ]

    // MARK: - Containers (ZIP / gzip) — v2.1 backlog #1

    /// One extractable member of a container. `extract` streams it to the
    /// given scratch URL, verifying size and checksum, or throws.
    struct ContainerStep {
        let name: String
        let extract: (URL) throws -> Void
    }

    enum ContainerMemberDisposition {
        case mail
        case notMail
        case nestedContainer
        case refused
    }

    private static let containerLog = Logger(subsystem: "com.ecosanskriti.mailin", category: "ContainerImport")

    /// The members worth extracting, in archive order. Directory entries and
    /// OS junk (`__MACOSX/`, `.DS_Store`, …) are dropped here; everything else
    /// is extracted and judged on its bytes.
    static func containerSteps(_ url: URL, format: SourceFormat) throws -> [ContainerStep] {
        switch format {
        case .gzip:
            // gzip carries a single payload and no reliable member name; use
            // the archive's own name minus the ".gz".
            let name = url.pathExtension.lowercased() == "gz" || url.pathExtension.lowercased() == "gzip"
                ? url.deletingPathExtension().lastPathComponent
                : url.lastPathComponent
            return [ContainerStep(name: name) { dest in try ZIPArchiveReader.gunzip(url, to: dest) }]
        case .zip:
            return try ZIPArchiveReader.members(of: url)
                .filter { !$0.isDirectory && !$0.isJunk }
                .map { member in
                    ContainerStep(name: member.name) { dest in
                        try ZIPArchiveReader.extract(member, from: url, to: dest)
                    }
                }
        default:
            return []
        }
    }

    static func containerScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-container-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A member name flattened to one path component, so a crafted archive
    /// path can never escape the scratch directory (zip-slip).
    static func safeMemberFileName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "..", with: "_")
        return base.isEmpty ? "member" : base
    }

    /// Extracts one member and decides what it is. A refusal (encrypted,
    /// damaged, would not fit on disk) is logged and does not stop the other
    /// members; the scratch file is removed on anything but `.mail`.
    static func containerMemberDisposition(_ step: ContainerStep, extractingTo dest: URL) throws -> ContainerMemberDisposition {
        do {
            try step.extract(dest)
        } catch let error as ZIPArchiveReader.ReadError {
            containerLog.error("container member refused: \(error.description, privacy: .private)")
            return .refused
        }
        let inner = SourceFormatClassifier.classify(url: dest)
        if inner.format.isContainer {
            containerLog.notice("nested container skipped: \(step.name, privacy: .private)")
            try? FileManager.default.removeItem(at: dest)
            return .nestedContainer
        }
        guard inner.isSupported else {
            try? FileManager.default.removeItem(at: dest)
            return .notMail
        }
        return .mail
    }

    /// Stable parser identity (type + version) for a file extension. Used to
    /// bind resume checkpoints and import receipts to the exact parser that
    /// produced them (Part B5/C): a parser upgrade invalidates mid-file
    /// checkpoints instead of silently resuming against a different message
    /// ordering.
    /// Identity of the parser that will actually run for `url`, from its
    /// detected format. Prefer this over the extension-based overload: a
    /// receipt must name the parser that ran, not the one the filename implied.
    static func parserIdentity(for url: URL) -> (name: String, version: Int) {
        parserIdentity(forExtension: SourceFormatClassifier.classify(url: url).format.parserToken)
    }

    /// Identity of the OFFSET engine for a line-structured source.
    ///
    /// A distinct name, and that is load-bearing rather than cosmetic. Resume
    /// checkpoints match on `(sha256, size, parser, parserVersion)` precisely
    /// so a parser change cannot resume mid-file against a different message
    /// ordering. The offset engine and the streaming parser **do** disagree on
    /// ordering: the streaming parser DROPS a message over
    /// `MBOXParser.maxMessageBytes` (it never reaches a batch), while the
    /// offset engine IMPORTS it. One oversized message therefore shifts every
    /// subsequent ordinal between the two engines.
    ///
    /// With both reporting `("mbox", 1)`, a half-finished streaming import
    /// would resume under the offset engine and "skip the first N" would skip
    /// a DIFFERENT N messages — some imported twice, some never, in an
    /// evidence archive. Giving the engine its own name makes the checkpoint
    /// fail to match, so the file restarts from scratch, which is the correct
    /// and safe outcome.
    static func offsetParserIdentity() -> (name: String, version: Int) {
        ("mbox-offset", OffsetImportEngine.engineVersion)
    }

    /// The identity of the engine that will ACTUALLY run, given the caller's
    /// engine choice. Prefer this over the format-only overloads anywhere a
    /// checkpoint or a source record is written.
    static func parserIdentity(for url: URL,
                               useOffsetEngine: Bool) -> (name: String, version: Int) {
        let classification = SourceFormatClassifier.classify(url: url)
        let token = classification.format.parserToken
        let offsetEligible = useOffsetEngine
            && streamableExtensions.contains(token)
            && !SourceFormatClassifier.isDirectoryForm(classification.format)
        return offsetEligible ? offsetParserIdentity() : parserIdentity(forExtension: token)
    }

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
        case "zip", "gzip":
            // The container's own identity; each member is still parsed by
            // its own format's parser once extracted.
            return ("container", ZIPArchiveReader.version)
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
    /// - Parameter envelopeProvider: P3.1 adaptive batching. Honoured by the
    ///   streaming MBOX/EML path today. The non-streaming formats (PST/OST,
    ///   NSF, MSG, EMLX) still drain in fixed `batchSize` chunks - wiring them
    ///   is tracked as P3.2, and until then their memory profile is unchanged.
    static func parseStreamingCallback(
        fileURL: URL,
        senderEmail: String,
        batchSize: Int = 200,
        envelopeProvider: (@Sendable () async -> BatchEnvelope)? = nil,
        retainAttachmentBytes: Bool = true,
        materializeAttachments: Bool = true,
        onProgress: ((Double) -> Void)? = nil,
        onBatch: ([MBOXParser.RawEmail]) async throws -> Void
    ) async throws -> MBOXParser.ParseRecoveryReport {
        // Content decides which parser runs. Routing on the extension alone
        // sent a PST or ZIP named ".mbox" to the MBOX parser, which has no
        // signature check and would manufacture junk messages from binary —
        // and rejected a valid mbox named ".txt".
        let classification = SourceFormatClassifier.classify(url: fileURL)
        guard classification.isSupported else {
            throw ExtractionError.unsupportedFormat(
                reason: [classification.summary, classification.format.advice]
                    .compactMap { $0 }.joined(separator: " "))
        }

        // Containers stream member-by-member too: one member is extracted to
        // scratch, drained through `onBatch`, and deleted before the next is
        // touched, so peak memory AND scratch disk stay bounded by one member.
        // Refused / non-mail / nested members are counted in the report's
        // categories (not as failed messages — they are not messages).
        if classification.format.isContainer {
            let steps = try containerSteps(fileURL, format: classification.format)
            let scratch = try containerScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            var total = 0, parsed = 0, failed = 0
            var categories: [String: Int] = [:]
            var sawMail = false
            for (index, step) in steps.enumerated() {
                try Task.checkCancellation()
                let dest = scratch.appendingPathComponent("\(index)-\(Self.safeMemberFileName(step.name))")
                defer { try? FileManager.default.removeItem(at: dest) }
                switch try containerMemberDisposition(step, extractingTo: dest) {
                case .refused: categories["container_member_refused", default: 0] += 1
                case .notMail: categories["container_member_not_mail", default: 0] += 1
                case .nestedContainer: categories["container_nested_skipped", default: 0] += 1
                case .mail:
                    sawMail = true
                    let report = try await parseStreamingCallback(
                        fileURL: dest,
                        senderEmail: senderEmail,
                        batchSize: batchSize,
                        envelopeProvider: envelopeProvider,
                        retainAttachmentBytes: retainAttachmentBytes,
                        materializeAttachments: materializeAttachments,
                        onProgress: { fraction in
                            onProgress?((Double(index) + fraction) / Double(steps.count))
                        },
                        onBatch: onBatch
                    )
                    total += report.totalMessages
                    parsed += report.successfullyParsed
                    failed += report.failed
                    for (key, count) in report.errorCategories { categories[key, default: 0] += count }
                }
            }
            guard sawMail else {
                throw ExtractionError.unsupportedFormat(
                    reason: "\(classification.summary). No mailbox files were found inside it (\(steps.count) member\(steps.count == 1 ? "" : "s") examined).")
            }
            return MBOXParser.ParseRecoveryReport(
                totalMessages: total, successfullyParsed: parsed,
                failed: failed, errorCategories: categories)
        }

        // Directory forms stream member-by-member: each file is drained
        // through `onBatch` before the next is opened, so peak memory stays
        // bounded by one member's batch rather than the whole mailbox.
        if SourceFormatClassifier.isDirectoryForm(classification.format) {
            let members = SourceFormatClassifier.expand(fileURL, format: classification.format)
            guard !members.isEmpty else {
                throw ExtractionError.unsupportedFormat(
                    reason: "\(classification.summary). No message files were found inside it.")
            }
            var total = 0, parsed = 0, failed = 0
            var categories: [String: Int] = [:]
            for (index, member) in members.enumerated() {
                let report = try await MBOXParser.parseStreamingCallback(
                    fileURL: member,
                    senderEmail: senderEmail,
                    batchSize: batchSize,
                    envelopeProvider: envelopeProvider,
                    retainAttachmentBytes: retainAttachmentBytes,
                    materializeAttachments: materializeAttachments,
                    onProgress: { fraction in
                        onProgress?((Double(index) + fraction) / Double(members.count))
                    },
                    onBatch: onBatch
                )
                total += report.totalMessages
                parsed += report.successfullyParsed
                failed += report.failed
                for (key, count) in report.errorCategories { categories[key, default: 0] += count }
            }
            return MBOXParser.ParseRecoveryReport(
                totalMessages: total, successfullyParsed: parsed,
                failed: failed, errorCategories: categories)
        }

        let ext = classification.format.parserToken
        switch ext {
        case "mbox", "eml", "":
            return try await MBOXParser.parseStreamingCallback(
                fileURL: fileURL,
                senderEmail: senderEmail,
                batchSize: batchSize,
                envelopeProvider: envelopeProvider,
                retainAttachmentBytes: retainAttachmentBytes,
                materializeAttachments: materializeAttachments,
                onProgress: onProgress,
                onBatch: onBatch
            )
        default:
            // Non-streamable format: the array parser runs (rejecting
            // unsupported extensions) and the result drains in bounded
            // chunks. These parsers throw on damage rather than recover,
            // so a successful parse reports zero failures.
            let parsed = try parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
            // P3.2 placeholder: the message bound is honoured, the byte bound
            // is not, because these parsers materialise before draining.
            let chunkLimit = await envelopeProvider?().maxMessages ?? batchSize
            for chunk in parsed.chunked(into: chunkLimit) {
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
