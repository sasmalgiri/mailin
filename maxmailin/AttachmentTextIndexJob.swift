//
//  AttachmentTextIndexJob.swift
//  maxmailin
//
//  Attachment-CONTENT search (v2.1 backlog #2, now shipped): extracts text
//  from attachments (PDF via PDFKit; plain-text families; RTF/HTML via
//  AttributedString) and indexes it into the `attachment_search` FTS table,
//  so `in:attachments` matches what's INSIDE files — not just filenames.
//
//  Bounded by construction: byte-capped work-list pages over emails with
//  attachments; one email's attachments resident at a time; per-attachment
//  extracted text capped; binary formats without a text extractor are
//  recorded as attempted (state row) so the work list converges and the UI
//  can report progress honestly. Kicked at launch and after every import.
//

import Foundation
import PDFKit
import os.log

extension Notification.Name {
    /// Posted when newly indexed attachment text is available — active
    /// `in:attachments` searches should re-run.
    static let attachmentIndexUpdated = Notification.Name("mailin.attachmentIndexUpdated")
}

@MainActor
final class AttachmentTextIndexJob {

    static let shared = AttachmentTextIndexJob()

    private static let logger = Logger(subsystem: "com.ecosanskriti.mailin", category: "AttachmentIndex")

    /// Test seam.
    static var testStoreOverride: SQLiteEmailStore?
    private var store: SQLiteEmailStore { Self.testStoreOverride ?? .shared }

    private var task: Task<Void, Never>?
    private var runGeneration = 0

    /// Extracted text cap per attachment — plenty for search, never unbounded.
    static let maxTextPerAttachment = 500_000

    struct Outcome: Sendable, Equatable {
        var indexedEmails = 0
        var extractedTexts = 0
        var failed = 0
    }

    init() {
        // New imports create new work; re-kick when one lands.
        NotificationCenter.default.addObserver(
            forName: .parsingFinished, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AttachmentTextIndexJob.shared.kickIfNeeded() }
        }
    }

    func kickIfNeeded() {
        guard task == nil else { return }
        runGeneration += 1
        let generation = runGeneration
        task = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.run()
            if self.runGeneration == generation { self.task = nil }
        }
    }

    func cancel() {
        runGeneration += 1
        task?.cancel()
        task = nil
    }

    @discardableResult
    func run(batchSize: Int = 50) async -> Outcome {
        var outcome = Outcome()
        do {
            while true {
                if Task.isCancelled { break }
                let page = try await store.attachmentTextCandidates(limit: batchSize)
                if !page.rawless.isEmpty {
                    // No raw source → nothing to extract; mark attempted.
                    for id in page.rawless { try await store.attachmentTextIndex(emailID: id, texts: []) }
                }
                if page.candidates.isEmpty {
                    if page.rawless.isEmpty { break }
                    continue
                }
                var pageProgress = page.rawless.count
                for candidate in page.candidates {
                    if Task.isCancelled { break }
                    // Whole extraction chain off the main actor — MIME decode,
                    // temp-file write, PDF/text parse.
                    let texts: [(filename: String, content: String)] = await Task.detached(priority: .utility) {
                        Self.extractTexts(fromRaw: candidate.raw)
                    }.value
                    do {
                        try await store.attachmentTextIndex(emailID: candidate.id, texts: texts)
                        outcome.indexedEmails += 1
                        outcome.extractedTexts += texts.count
                        pageProgress += 1
                    } catch {
                        outcome.failed += 1
                        Self.logger.error("attachment index failed for \(candidate.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                if pageProgress == 0 { break }
            }
            if outcome.indexedEmails > 0 {
                Self.logger.info("attachment text indexed: \(outcome.indexedEmails) email(s), \(outcome.extractedTexts) text(s)")
                NotificationCenter.default.post(name: .attachmentIndexUpdated, object: nil)
            }
        } catch {
            Self.logger.error("attachment index aborted: \(error.localizedDescription, privacy: .public)")
        }
        return outcome
    }

    // MARK: - Extraction (nonisolated, bounded)

    /// Text from every extractable attachment of one raw MIME message.
    /// Temp files created by the extractor are removed before returning.
    nonisolated static func extractTexts(fromRaw raw: String) -> [(filename: String, content: String)] {
        guard let extraction = try? EmailBodyExtractor.extractContents(from: raw) else { return [] }
        var out: [(String, String)] = []
        for attachment in extraction.attachments {
            defer {
                if let url = attachment.fileURL { try? FileManager.default.removeItem(at: url) }
            }
            guard let text = extractText(from: attachment), !text.isEmpty else { continue }
            out.append((attachment.filename, String(text.prefix(maxTextPerAttachment))))
        }
        return out
    }

    nonisolated private static func extractText(from attachment: AttachmentMetadata) -> String? {
        let data: Data?
        if let url = attachment.fileURL {
            data = try? Data(contentsOf: url)
        } else if let b64 = attachment.base64 {
            data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
        } else {
            data = nil
        }
        guard let data, !data.isEmpty else { return nil }

        let mime = attachment.mimeType.lowercased()
        let ext = (attachment.filename as NSString).pathExtension.lowercased()

        if mime.contains("pdf") || ext == "pdf" {
            return PDFDocument(data: data)?.string
        }
        if mime.contains("rtf") || ext == "rtf" {
            return (try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil))?.string
        }
        if mime.contains("html") || ext == "html" || ext == "htm" {
            // Regex strip instead of NSAttributedString(html:) — the latter
            // requires the main thread (WebKit) and this runs detached.
            let html = String(data: data, encoding: .utf8) ?? ""
            return html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        let textualExts: Set<String> = ["txt", "csv", "log", "md", "json", "xml", "ics", "vcf", "eml", "yml", "yaml"]
        if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") || textualExts.contains(ext) {
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
        // Binary formats without an extractor (docx/xlsx/images/…): recorded
        // as attempted with no text — honest, and a future extractor can
        // re-run by clearing attachment_text_state.
        return nil
    }
}
