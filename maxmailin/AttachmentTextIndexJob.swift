@testable import ArchiveCore
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

    /// Settings ▸ Modules "Running now". The job owns its own row (owner's
    /// review 2026-09-29): registered when a run starts — including re-kicks
    /// after an import — and cleared on EVERY exit. Before this the launch
    /// hook registered the row and nothing ever cleared it.
    static let jobID = "attachment.textIndex"
    static let jobLabel = "Index attachment contents"
    private weak var registry: JobRegistry?

    /// Test seam: the current run, if any.
    var currentRun: Task<Void, Never>? { task }

    /// Extracted text cap per attachment — plenty for search, never unbounded.
    nonisolated static let maxTextPerAttachment = 500_000

    struct Outcome: Sendable, Equatable {
        var indexedEmails = 0
        var extractedTexts = 0
        var failed = 0
        /// E1: emails read again for scanned text by the OCR second pass, and how many it covers.
        var ocrEmails = 0
        var ocrTotal = 0
    }

    init() {
        // New imports create new work; re-kick when one lands.
        NotificationCenter.default.addObserver(
            forName: .parsingFinished, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AttachmentTextIndexJob.shared.kickIfNeeded() }
        }
    }

    func kickIfNeeded(registry: JobRegistry? = nil) {
        guard task == nil else { return }
        guard SafeMode.shared.allowsBackgroundWork else { return }   // §3-S6
        guard BackgroundExecution.isProtectedDataAvailable else { return }   // §3-S3
        if let registry { self.registry = registry }
        runGeneration += 1
        let generation = runGeneration
        self.registry?.register(id: Self.jobID, module: .archive, label: Self.jobLabel) { [weak self] in self?.cancel() }
        task = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.run()
            if self.runGeneration == generation {
                self.task = nil
                self.registry?.finish(id: Self.jobID)
            }
        }
    }

    func cancel() {
        runGeneration += 1
        task?.cancel()
        task = nil
        registry?.finish(id: Self.jobID)
    }

    private func report(_ outcome: Outcome) {
        var parts = ["\(outcome.indexedEmails.formatted()) emails indexed"]
        if outcome.extractedTexts > 0 { parts.append("\(outcome.extractedTexts.formatted()) texts") }
        if outcome.failed > 0 { parts.append("\(outcome.failed.formatted()) failed") }
        if outcome.ocrTotal > 0 { parts.append(String(localized: "scanned text: \(outcome.ocrEmails.formatted()) of \(outcome.ocrTotal.formatted()) emails")) }
        registry?.update(id: Self.jobID, detail: parts.joined(separator: ", "))
    }

    @discardableResult
    func run(batchSize: Int = 50) async -> Outcome {
        var outcome = Outcome()
        // E1: read once per run; a switch flipped mid-run applies from the next run.
        let ocr = AttachmentOCR.isEnabled
        var ocrState: AttachmentOCRState? = nil
        if ocr {
            let stateURL = await store.attachmentOCRStateURL
            ocrState = try? AttachmentOCRState(url: stateURL)
        }
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
                        Self.extractTexts(fromRaw: candidate.raw, ocr: ocr)
                    }.value
                    do {
                        try await store.attachmentTextIndex(emailID: candidate.id, texts: texts)
                        // Read with OCR already: the second pass need not come back to it.
                        try? ocrState?.markDone([candidate.id])
                        outcome.indexedEmails += 1
                        outcome.extractedTexts += texts.count
                        pageProgress += 1
                    } catch {
                        outcome.failed += 1
                        Self.logger.error("attachment index failed for \(candidate.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                if pageProgress == 0 { break }
                report(outcome)
            }
            if let ocrState, !Task.isCancelled {
                try await ocrSecondPass(state: ocrState, batchSize: batchSize, outcome: &outcome)
            }
            if outcome.indexedEmails > 0 || outcome.ocrEmails > 0 {
                Self.logger.info("attachment text indexed: \(outcome.indexedEmails) email(s), \(outcome.extractedTexts) text(s)")
                NotificationCenter.default.post(name: .attachmentIndexUpdated, object: nil)
            }
        } catch {
            Self.logger.error("attachment index aborted: \(error.localizedDescription, privacy: .public)")
        }
        return outcome
    }

    /// E1: emails whose attachment text was extracted before OCR was on, and that hold an image
    /// or a PDF, are read again — each once (the state file remembers), resuming at its cursor.
    /// IDs are paged without loading messages; only emails not yet read are loaded, in
    /// byte-capped pages. A finished pass clears the cursor, so mail indexed while OCR was off
    /// is found on a later run.
    private func ocrSecondPass(state: AttachmentOCRState, batchSize: Int, outcome: inout Outcome) async throws {
        outcome.ocrTotal = try await store.attachmentOCRCandidateCount()
        outcome.ocrEmails = min(outcome.ocrTotal, (try? state.doneCount()) ?? 0)
        report(outcome)
        var cursor = state.cursor
        while !Task.isCancelled {
            let ids = try await store.attachmentOCRCandidateIDs(after: cursor, limit: batchSize * 10)
            guard let last = ids.last else { state.cursor = nil; break }
            let done = try state.done(among: ids)
            var pending = ids.filter { !done.contains($0) }
            while !pending.isEmpty, !Task.isCancelled {
                let page = try await store.rawCandidates(ids: Array(pending.prefix(batchSize)))
                if !page.rawless.isEmpty { try state.markDone(page.rawless) }
                for candidate in page.candidates {
                    if Task.isCancelled { break }
                    let texts: [(filename: String, content: String)] = await Task.detached(priority: .utility) {
                        Self.extractTexts(fromRaw: candidate.raw, ocr: true)
                    }.value
                    do {
                        try await store.attachmentTextIndex(emailID: candidate.id, texts: texts)
                        try state.markDone([candidate.id])
                        outcome.ocrEmails += 1
                    } catch {
                        outcome.failed += 1
                        Self.logger.error("attachment OCR failed for \(candidate.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                let handled = Set(page.rawless).union(page.candidates.map(\.id))
                if handled.isEmpty { break }
                pending.removeAll { handled.contains($0) }
                report(outcome)
            }
            if Task.isCancelled { break }
            cursor = last.uuidString
            state.cursor = cursor
        }
    }

    // MARK: - Extraction (nonisolated, bounded)

    /// Text from every extractable attachment of one raw MIME message.
    /// Temp files created by the extractor are removed before returning.
    nonisolated static func extractTexts(fromRaw raw: String, ocr: Bool = false) -> [(filename: String, content: String)] {
        guard let extraction = try? EmailBodyExtractor.extractContents(from: raw) else { return [] }
        var out: [(String, String)] = []
        for attachment in extraction.attachments {
            defer {
                if let url = attachment.fileURL { try? FileManager.default.removeItem(at: url) }
            }
            guard let text = extractText(from: attachment, ocr: ocr), !text.isEmpty else { continue }
            out.append((attachment.filename, String(text.prefix(maxTextPerAttachment))))
        }
        return out
    }

    nonisolated static func extractText(from attachment: AttachmentMetadata, ocr: Bool = false) -> String? {
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
            guard let document = PDFDocument(data: data) else { return nil }
            let layer = document.string
            // E1: a scanned PDF (no real text layer) is read by OCR, page by page.
            if ocr, AttachmentOCR.pdfNeedsOCR(text: layer, pageCount: document.pageCount),
               let scanned = AttachmentOCR.text(fromPDF: document) {
                let stamp = layer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return stamp.isEmpty ? scanned : stamp + "\n" + scanned
            }
            return layer
        }
        if ocr, AttachmentOCR.isImage(mimeType: mime, filename: attachment.filename) {
            return AttachmentOCR.text(fromImageData: data)
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
